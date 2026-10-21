#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import http from "node:http";
import { execFile } from "node:child_process";
import { parseDbml } from "../src/model.mjs";
import { layout } from "../src/layout.mjs";
import { arrange } from "../src/arrange.mjs";
import { renderSvg } from "../src/svg.mjs";
import { renderPage, buildMeta } from "../src/page.mjs";

const OPEN_CMD =
  process.platform === "darwin" ? "open" : process.platform === "win32" ? "explorer" : "xdg-open";
const DEFAULT_PORT = 4777;
const MAX_LAYOUT_BYTES = 1024 * 1024;

function openInBrowser(target) {
  const arg = /^https?:/.test(target) ? target : path.resolve(target);
  execFile(OPEN_CMD, [arg], (err) => {
    if (err) console.error(`  (could not open a browser: ${err.message})`);
  });
}

/** Path as the user thinks of it: relative to where they ran npm (INIT_CWD), else absolute. */
function displayPath(p) {
  const rel = path.relative(process.env.INIT_CWD || process.cwd(), p);
  return !rel || rel.startsWith('..' + path.sep + '..') ? p : rel;
}

function usage() {
  console.log(`dbml-erd — ungated DBML -> ERD renderer

  dbml-erd <file.dbml> [options]

Options:
  --serve [port]     interactive editor on http://127.0.0.1:${DEFAULT_PORT}; dragged
                     positions are saved to <file>.erd.layout.json
  --watch            re-render when the .dbml changes (live-reloads with --serve)
  --open             open the result in your browser
  -o, --out <file>   output HTML (default: alongside input, .erd.html)
  --layout <file>    layout file (default: alongside input, .erd.layout.json)
  --engine <name>    auto layout: grid (default, screen-shaped) | dagre (original)
  --svg              emit a standalone .svg instead of interactive HTML
  --json             dump the parsed model as JSON (debugging)
  --no-color         quieter output
  -h, --help         this message

Colours, table groups and notes are all rendered locally from the DBML you
already own. Nothing is sent anywhere; --serve only listens on 127.0.0.1.`);
}

function parseArgs(argv) {
  const opts = { engine: 'grid', input: null, out: null, layout: null, svg: false, json: false, watch: false, serve: false, port: DEFAULT_PORT };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "-h" || a === "--help") opts.help = true;
    else if (a === "-o" || a === "--out") opts.out = argv[++i];
    else if (a === "--layout") opts.layout = argv[++i];
    else if (a === "--engine") opts.engine = argv[++i];
    else if (a === "--svg") opts.svg = true;
    else if (a === "--json") opts.json = true;
    else if (a === "--watch") opts.watch = true;
    else if (a === "--open") opts.open = true;
    else if (a === "--no-color") opts.noColor = true;
    else if (a === "--serve") {
      opts.serve = true;
      if (/^\d+$/.test(argv[i + 1] ?? "")) opts.port = Number(argv[++i]);
    } else if (!opts.input) opts.input = a;
    else throw new Error(`unexpected argument: ${a}`);
  }
  return opts;
}

// ---------------------------------------------------------------------------
// layout file

/** Keep only { tables|notes: { name: {x, y} } } with finite numbers. */
function sanitizeLayout(raw) {
  const out = { tables: {}, notes: {} };
  if (!raw || typeof raw !== "object") return out;
  for (const kind of ["tables", "notes"]) {
    const src = raw[kind];
    if (!src || typeof src !== "object") continue;
    for (const name of Object.keys(src).sort()) {
      const p = src[name];
      if (typeof name !== "string" || name.length > 200) continue;
      if (!p || !Number.isFinite(p.x) || !Number.isFinite(p.y)) continue;
      out[kind][name] = { x: Math.round(p.x), y: Math.round(p.y) };
    }
  }
  return out;
}

function readLayout(file) {
  if (!fs.existsSync(file)) return { tables: {}, notes: {} };
  try {
    return sanitizeLayout(JSON.parse(fs.readFileSync(file, "utf8")));
  } catch (e) {
    console.error(`  ! ignoring unreadable layout file ${file}: ${e.message}`);
    return { tables: {}, notes: {} };
  }
}

/** Atomic, diff-friendly write (sorted keys, one entry per line). */
function writeLayout(file, layoutData) {
  const clean = sanitizeLayout(layoutData);
  const body = {
    $comment: "dbml-erd manual positions. Edited by dragging in `npm run erd`; safe to commit.",
    version: 1,
    tables: clean.tables,
    notes: clean.notes,
  };
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(body, null, 2) + "\n");
  fs.renameSync(tmp, file);
  return Object.keys(clean.tables).length + Object.keys(clean.notes).length;
}

// ---------------------------------------------------------------------------
// render

function build(opts) {
  const text = fs.readFileSync(opts.input, "utf8");
  const model = parseDbml(text, path.basename(opts.input));
  if (model.errors.length) {
    for (const e of model.errors) console.error(`  ${e.line ? `line ${e.line}: ` : ""}${e.message}`);
    throw new Error(`${model.errors.length} parse error(s) in ${opts.input}`);
  }
  if (!model.tables.length) throw new Error(`no tables found in ${opts.input}`);
  const pos = opts.engine === "dagre" ? layout(model) : arrange(layout(model), model);
  const svg = renderSvg(pos, model);
  const meta = buildMeta(model, pos, { layoutFile: displayPath(opts.layoutFile) });
  return { model, pos, svg, meta };
}

const page = (built, opts) => renderPage({ ...built, layout: readLayout(opts.layoutFile) });

function emit(opts, built) {
  const { model, pos, svg } = built;
  if (opts.json) {
    const out = opts.out ?? opts.input.replace(/\.dbml$/i, ".model.json");
    fs.writeFileSync(out, JSON.stringify({ name: model.name, groups: model.groups, tables: model.tables.length, notes: model.notes }, null, 2));
    return out;
  }
  const out = opts.out ?? opts.input.replace(/\.dbml$/i, opts.svg ? ".erd.svg" : ".erd.html");
  fs.writeFileSync(out, opts.svg ? svg : page(built, opts));
  return out;
}

function summary(opts, built, out) {
  const { pos } = built;
  return (
    `✓ ${path.basename(opts.input)}${out ? ` → ${path.basename(out)}` : ""}` +
    `  (${pos.tables.length} tables, ${pos.groups.filter((g) => g.isGroup).length} groups, ` +
    `${pos.notes.length} notes, ${pos.refs.length} refs)`
  );
}

// ---------------------------------------------------------------------------
// server

function serve(opts, getBuilt, onClient) {
  const clients = new Set();

  const server = http.createServer((req, res) => {
    const url = new URL(req.url, "http://127.0.0.1");
    try {
      if (req.method === "GET" && (url.pathname === "/" || url.pathname === "/index.html")) {
        const built = getBuilt();
        if (!built) {
          res.writeHead(503, { "Content-Type": "text/plain; charset=utf-8" });
          return res.end("The .dbml currently has errors — see the terminal. This page will reload once it parses.");
        }
        res.writeHead(200, { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" });
        return res.end(page(built, opts));
      }

      if (req.method === "GET" && url.pathname === "/layout") {
        res.writeHead(200, { "Content-Type": "application/json", "Cache-Control": "no-store" });
        return res.end(JSON.stringify(readLayout(opts.layoutFile)));
      }

      if (req.method === "PUT" && url.pathname === "/layout") {
        // A custom header can't be sent cross-origin without a CORS preflight,
        // which we never approve -> other websites can't overwrite the file.
        if (req.headers["x-dbml-erd"] !== "1" || !String(req.headers["content-type"]).startsWith("application/json")) {
          res.writeHead(403);
          return res.end();
        }
        let size = 0;
        const chunks = [];
        req.on("data", (c) => {
          size += c.length;
          if (size > MAX_LAYOUT_BYTES) {
            res.writeHead(413);
            res.end();
            req.destroy();
          } else chunks.push(c);
        });
        req.on("end", () => {
          if (res.writableEnded) return;
          try {
            const n = writeLayout(opts.layoutFile, JSON.parse(Buffer.concat(chunks).toString("utf8")));
            console.log(`  ↳ layout saved: ${n} moved item(s) → ${displayPath(opts.layoutFile)}`);
            res.writeHead(204);
            res.end();
          } catch (e) {
            res.writeHead(400, { "Content-Type": "text/plain" });
            res.end(e.message);
          }
        });
        return;
      }

      if (req.method === "GET" && url.pathname === "/events") {
        res.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-store", Connection: "keep-alive" });
        res.write(": connected\n\n");
        clients.add(res);
        req.on("close", () => clients.delete(res));
        return;
      }

      res.writeHead(404);
      res.end();
    } catch (e) {
      res.writeHead(500, { "Content-Type": "text/plain" });
      res.end(e.message);
    }
  });

  const reload = () => {
    for (const c of clients) c.write("event: reload\ndata: 1\n\n");
  };

  return new Promise((resolve, reject) => {
    let port = opts.port;
    const tryListen = () => {
      server.once("error", (e) => {
        if (e.code === "EADDRINUSE" && port < opts.port + 20) {
          port++;
          tryListen();
        } else reject(e);
      });
      server.listen(port, "127.0.0.1", () => resolve({ url: `http://127.0.0.1:${port}/`, reload, server }));
    };
    tryListen();
  });
}

// ---------------------------------------------------------------------------

function watchInput(opts, onChange) {
  let t = null;
  // fs.watch on the directory survives editors that save by rename-and-replace
  fs.watch(path.dirname(path.resolve(opts.input)), (_, file) => {
    if (file && file !== path.basename(opts.input)) return;
    clearTimeout(t);
    t = setTimeout(onChange, 80);
  });
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.help || !opts.input) {
    usage();
    process.exit(opts.help ? 0 : 1);
  }
  if (!fs.existsSync(opts.input)) throw new Error(`not found: ${opts.input}`);
  opts.layoutFile = path.resolve(opts.layout ?? opts.input.replace(/\.dbml$/i, ".erd.layout.json"));

  if (opts.serve) {
    let built = null;
    const rebuild = () => {
      try {
        built = build(opts);
        console.log(summary(opts, built));
        return true;
      } catch (e) {
        built = null;
        console.error(`✗ ${e.message}`);
        return false;
      }
    };
    rebuild();
    const { url, reload } = await serve(opts, () => built);
    console.log(`\n  editor   ${url}`);
    console.log(`  layout   ${displayPath(opts.layoutFile)} ${fs.existsSync(opts.layoutFile) ? "" : "(created on first drag)"}`);
    if (opts.watch) console.log(`  watching ${opts.input} — the page reloads when you save it`);
    console.log(`  ctrl-c to stop\n`);
    if (opts.open) openInBrowser(url);
    if (opts.watch) watchInput(opts, () => { rebuild(); reload(); });
    return;
  }

  const run = () => {
    const built = build(opts);
    const out = emit(opts, built);
    console.log(summary(opts, built, out));
    return out;
  };
  const out = run();
  if (!opts.watch) {
    if (!opts.noColor) console.log(`\n  open  file://${path.resolve(out)}\n`);
    if (opts.open) openInBrowser(out);
    return;
  }
  console.log(`watching ${opts.input} — ctrl-c to stop`);
  if (opts.open) openInBrowser(out);
  watchInput(opts, () => {
    try {
      run();
    } catch (e) {
      console.error(`✗ ${e.message}`);
    }
  });
}

main().catch((e) => {
  console.error(`✗ ${e.message}`);
  process.exit(1);
});
