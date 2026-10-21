/**
 * Readability-first arrangement.
 *
 * The dagre pass in layout.mjs stacks every group into one tall column, which
 * gives a portrait canvas that has to be shrunk to ~30% to fit a landscape
 * screen. This pass re-places the same tables to fit a screen:
 *
 *   1. pack each group's tables into a compact block of 1–3 columns
 *   2. lay groups out in rows; search every group order x row split and keep
 *      the ones that fit the screen best (largest "Fit" zoom) and keep linked
 *      groups close
 *   3. refine table order inside each group to minimise line crossings and
 *      lines running through other tables
 *
 * It mutates `pos` in place (tables, groups, notes, width/height) so the SVG
 * renderer and the browser's group-fitting code keep working unchanged.
 */

const C = {
  SCREEN_W: 1360, // usable canvas on a laptop (sidebar + toolbar removed)
  SCREEN_H: 840,
  IN_GAP_X: 36, // between table columns inside a group
  IN_GAP_Y: 28, // between tables in a column
  GROUP_PAD: 28, // must match layout.mjs / page.mjs (box = tables ± pad)
  GROUP_TOP: 38, //   GROUP_HEAD + 8
  GAP_X: 90, // between groups in a row (room for ref lines)
  GAP_Y: 64, // between rows
  NOTE_GAP: 20, // note bottom -> group label chip
  MARGIN: 40,
  MAX_COLS: 3,
  TOP_CANDIDATES: 12,
  REFINE_PASSES: 2,
};

// ---------------------------------------------------------------------------
// small geometry helpers

function segsCross(a, b, c, d) {
  const o = (p, q, r) => Math.sign((q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x));
  const o1 = o(a, b, c), o2 = o(a, b, d), o3 = o(c, d, a), o4 = o(c, d, b);
  return o1 !== o2 && o3 !== o4 && o1 !== 0 && o2 !== 0 && o3 !== 0 && o4 !== 0;
}

function segHitsRect(a, b, r) {
  // shrink a little so a line grazing a border doesn't count
  const x1 = r.x + 4, y1 = r.y + 4, x2 = r.x + r.w - 4, y2 = r.y + r.h - 4;
  const inside = (p) => p.x > x1 && p.x < x2 && p.y > y1 && p.y < y2;
  if (inside(a) || inside(b)) return true;
  const corners = [{ x: x1, y: y1 }, { x: x2, y: y1 }, { x: x2, y: y2 }, { x: x1, y: y2 }];
  for (let i = 0; i < 4; i++) if (segsCross(a, b, corners[i], corners[(i + 1) % 4])) return true;
  return false;
}

function permutations(arr) {
  if (arr.length <= 1) return [arr.slice()];
  const out = [];
  arr.forEach((x, i) => {
    for (const rest of permutations([...arr.slice(0, i), ...arr.slice(i + 1)])) out.push([x, ...rest]);
  });
  return out;
}

/** All ways to split n items into `rows` consecutive non-empty parts of size <= max. */
function compositions(n, rows, max) {
  if (rows === 1) return n >= 1 && n <= max ? [[n]] : [];
  const out = [];
  for (let first = 1; first <= Math.min(max, n - rows + 1); first++) {
    for (const rest of compositions(n - first, rows - 1, max)) out.push([first, ...rest]);
  }
  return out;
}

// ---------------------------------------------------------------------------
// 1. inside a group

/** Shortest-column-first packing. Returns block size + per-table offsets. */
function pack(order, cols, size) {
  const colTables = Array.from({ length: cols }, () => []);
  const colH = new Array(cols).fill(0);
  for (const id of order) {
    let c = 0;
    for (let i = 1; i < cols; i++) if (colH[i] < colH[c] - 0.5) c = i;
    colTables[c].push(id);
    colH[c] += (colH[c] ? C.IN_GAP_Y : 0) + size.get(id).h;
  }
  const offsets = new Map();
  let x = 0;
  let w = 0;
  for (let c = 0; c < cols; c++) {
    if (!colTables[c].length) continue;
    const colW = Math.max(...colTables[c].map((id) => size.get(id).w));
    let y = 0;
    for (const id of colTables[c]) {
      offsets.set(id, { x, y });
      y += size.get(id).h + C.IN_GAP_Y;
    }
    w = x + colW;
    x += colW + C.IN_GAP_X;
  }
  return { w, h: Math.max(...colH), offsets };
}

function chooseCols(order, size) {
  let best = null;
  for (let cols = 1; cols <= Math.min(C.MAX_COLS, order.length); cols++) {
    const p = pack(order, cols, size);
    // aim for slightly-wider-than-tall blocks; mild preference for fewer columns
    const score = Math.abs(Math.log(p.w / p.h / 1.15)) + 0.15 * (cols - 1);
    if (!best || score < best.score) best = { cols, score };
  }
  return best.cols;
}

// ---------------------------------------------------------------------------
// 2 + 3. whole diagram

export function arrange(pos, model) {
  const groupsReal = pos.groups.filter((g) => g.isGroup);
  if (!groupsReal.length) return pos; // nothing to organise; keep dagre

  const size = new Map(pos.tables.map((t) => [t.id, { w: t.w, h: t.h }]));
  const tableById = new Map(pos.tables.map((t) => [t.id, t]));
  const noteOf = new Map(pos.notes.filter((n) => n.groupKey != null).map((n) => [n.groupKey, n]));

  // "units" to place: real groups, plus each ungrouped table on its own
  const units = [];
  for (const g of pos.groups) {
    if (g.isGroup) units.push({ key: g.key, box: true, tableIds: [...g.tableIds], note: noteOf.get(g.key) ?? null });
    else for (const id of g.tableIds) units.push({ key: `t:${id}`, box: false, tableIds: [id], note: null });
  }
  const unitOfTable = new Map();
  units.forEach((u, i) => u.tableIds.forEach((id) => unitOfTable.set(id, i)));

  // links between units (for keeping related groups close)
  const links = new Map();
  for (const r of pos.refs) {
    const a = unitOfTable.get(r.from.tableId), b = unitOfTable.get(r.to.tableId);
    if (a == null || b == null || a === b) continue;
    const k = a < b ? `${a}|${b}` : `${b}|${a}`;
    links.set(k, (links.get(k) ?? 0) + 1);
  }
  const linkList = [...links].map(([k, w]) => { const [a, b] = k.split("|").map(Number); return { a, b, w }; });

  // initial in-group order: tallest first balances columns; column count fixed per unit
  for (const u of units) {
    u.order = [...u.tableIds].sort((x, y) => size.get(y).h - size.get(x).h || x - y);
    u.cols = chooseCols(u.order, size);
  }

  const unitRect = (u) => {
    const p = pack(u.order, u.cols, size);
    const pad = u.box ? C.GROUP_PAD : 0;
    const top = u.box ? C.GROUP_TOP : 0;
    const noteBand = u.note ? u.note.h + C.NOTE_GAP + 11 : u.box ? 14 : 0; // 11 = chip overhang
    return { p, w: p.w + pad * 2, h: p.h + top + pad + noteBand, pad, top, noteBand };
  };

  /** Place units row by row; returns geometry for everything. */
  function place(order, split) {
    const rects = units.map(unitRect);
    const rows = [];
    let i = 0;
    for (const n of split) { rows.push(order.slice(i, i + n)); i += n; }
    const rowW = rows.map((r) => r.reduce((s, u) => s + rects[u].w, 0) + C.GAP_X * (r.length - 1));
    const maxW = Math.max(...rowW);
    const at = new Array(units.length);
    let y = C.MARGIN;
    rows.forEach((r, ri) => {
      let x = C.MARGIN + (maxW - rowW[ri]) / 2; // centre each row
      const rowH = Math.max(...r.map((u) => rects[u].h));
      for (const u of r) {
        at[u] = { x, y, ...rects[u] };
        x += rects[u].w + C.GAP_X;
      }
      y += rowH + C.GAP_Y;
    });
    const W = maxW + C.MARGIN * 2;
    const H = y - C.GAP_Y + C.MARGIN;
    return { at, W, H, zoom: Math.min(C.SCREEN_W / W, C.SCREEN_H / H) };
  }

  function linkCost(geo) {
    let s = 0;
    for (const { a, b, w } of linkList) {
      const A = geo.at[a], B = geo.at[b];
      s += w * Math.hypot(A.x + A.w / 2 - (B.x + B.w / 2), A.y + A.h / 2 - (B.y + B.h / 2));
    }
    return s;
  }

  /** Absolute table rects for a placement. */
  function tableRects(geo) {
    const out = new Map();
    units.forEach((u, i) => {
      const g = geo.at[i];
      for (const [id, o] of g.p.offsets) {
        out.set(id, { x: g.x + g.pad + o.x, y: g.y + g.noteBand + g.top + o.y, w: size.get(id).w, h: size.get(id).h });
      }
    });
    return out;
  }

  /** Line quality: crossings, lines through tables, length. Lower is better. */
  function lineCost(geo) {
    const R = tableRects(geo);
    const rects = [...R.values()];
    const rowY = (T, row) => T.y + pos.metrics.HEAD_H + row * pos.metrics.ROW_H + pos.metrics.ROW_H / 2;
    // each ref as a polyline sampled from the same cubic svg.mjs routeRef() draws
    const cubic = (p0, p1, p2, p3, n = 8) => {
      const pts = [];
      for (let i = 0; i <= n; i++) {
        const t = i / n, u = 1 - t;
        pts.push({
          x: u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x,
          y: u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y,
        });
      }
      return pts;
    };
    const lines = [];
    for (const r of pos.refs) {
      if (r.self) continue;
      const A = R.get(r.from.tableId), B = R.get(r.to.tableId);
      if (!A || !B) continue;
      const ay = rowY(A, r.from.row), by = rowY(B, r.to.row);
      let pts;
      if (A.x < B.x + B.w && B.x < A.x + A.w) {
        const y1 = Math.min(A.y, B.y), y2 = Math.max(A.y + A.h, B.y + B.h);
        const Rx = Math.max(A.x + A.w, B.x + B.w), Lx = Math.min(A.x, B.x);
        const others = rects.filter((t) => t !== A && t !== B && t.y < y2 && t.y + t.h > y1);
        const blockedR = others.some((t) => t.x >= Rx - 1 && t.x < Rx + 70);
        const blockedL = others.some((t) => t.x + t.w <= Lx + 1 && t.x + t.w > Lx - 70);
        const right = !(blockedR && !blockedL);
        const out = right ? Rx + 34 : Lx - 34;
        const ax = right ? A.x + A.w : A.x, bx = right ? B.x + B.w : B.x;
        pts = cubic({ x: ax, y: ay }, { x: out, y: ay }, { x: out, y: by }, { x: bx, y: by }, 6);
      } else {
        const ltr = A.x + A.w / 2 <= B.x + B.w / 2;
        const a = { x: ltr ? A.x + A.w : A.x, y: ay }, b = { x: ltr ? B.x : B.x + B.w, y: by };
        const dx = Math.max(40, Math.abs(b.x - a.x) * 0.45);
        pts = cubic(a, { x: ltr ? a.x + dx : a.x - dx, y: a.y }, { x: ltr ? b.x - dx : b.x + dx, y: b.y }, b, 8);
      }
      const xs = pts.map((p) => p.x), ys = pts.map((p) => p.y);
      lines.push({
        pts, t1: r.from.tableId, t2: r.to.tableId,
        box: { x: Math.min(...xs), y: Math.min(...ys), r: Math.max(...xs), b: Math.max(...ys) },
        segs: pts.slice(1).map((p, i) => [pts[i], p]),
      });
    }
    const boxesMeet = (a, b) => a.x <= b.r && b.x <= a.r && a.y <= b.b && b.y <= a.b;
    let crossings = 0;
    for (let i = 0; i < lines.length; i++) {
      for (let j = i + 1; j < lines.length; j++) {
        if (!boxesMeet(lines[i].box, lines[j].box)) continue;
        if (lines[i].segs.some(([a, b]) => lines[j].segs.some(([c, d]) => segsCross(a, b, c, d)))) crossings++;
      }
    }
    let through = 0;
    let len = 0;
    for (const l of lines) {
      for (const [a, b] of l.segs) len += Math.hypot(a.x - b.x, a.y - b.y);
      for (const [id, rect] of R) {
        if (id === l.t1 || id === l.t2) continue;
        if (!boxesMeet(l.box, { x: rect.x, y: rect.y, r: rect.x + rect.w, b: rect.y + rect.h })) continue;
        if (l.segs.some(([a, b]) => segHitsRect(a, b, rect))) through++;
      }
    }
    return { crossings, through, len, score: crossings * 8 + through * 25 + len / 300 };
  }

  // ---- search group order x row split ------------------------------------
  const n = units.length;
  const splits = [];
  const maxPerRow = Math.max(2, Math.ceil(n / 2) + 1);
  for (let rows = 1; rows <= Math.min(4, n); rows++) splits.push(...compositions(n, rows, maxPerRow));
  const orders = n <= 8 ? permutations([...Array(n).keys()]) : [[...Array(n).keys()]];

  const cands = [];
  for (const split of splits) {
    for (const order of orders) {
      const geo = place(order, split);
      cands.push({ order, split, zoom: geo.zoom, link: linkCost(geo) });
    }
  }
  let bestZoom = 0; // (a loop: spreading ~200k candidates into Math.max blows the stack)
  for (const c of cands) if (c.zoom > bestZoom) bestZoom = c.zoom;
  const startOrders = units.map((u) => u.order.slice());
  const shortlist = cands
    .filter((c) => c.zoom >= bestZoom * 0.93) // within 7% of the most readable fit
    .sort((a, b) => a.link - b.link)
    .slice(0, 300);
  // re-rank the shortlist by what the lines will actually look like
  for (const c of shortlist) c.lines = lineCost(place(c.order, c.split)).score;
  const top = shortlist.sort((a, b) => a.lines - b.lines).slice(0, C.TOP_CANDIDATES);

  // ---- refine each candidate's in-group order, keep the best ---------------
  let best = null;
  for (const cand of top) {
    units.forEach((u, i) => (u.order = startOrders[i].slice()));
    let geo = place(cand.order, cand.split);
    let cost = lineCost(geo);
    for (let pass = 0; pass < C.REFINE_PASSES; pass++) {
      for (const u of units) {
        if (u.order.length < 2 || u.order.length > 6) continue;
        let bestLocal = { order: u.order, cost, geo };
        for (const perm of permutations(u.order)) {
          u.order = perm;
          const g = place(cand.order, cand.split);
          if (g.zoom < bestZoom * 0.9) continue; // don't trade readability for tidiness
          const c = lineCost(g);
          if (c.score < bestLocal.cost.score) bestLocal = { order: perm, cost: c, geo: g };
        }
        u.order = bestLocal.order;
        cost = bestLocal.cost;
        geo = bestLocal.geo;
      }
    }
    const total = cost.score - geo.zoom * 200; // readability still matters most
    if (!best || total < best.total) best = { total, geo, cost, orders: units.map((u) => u.order.slice()), cand };
  }

  // ---- apply ---------------------------------------------------------------
  units.forEach((u, i) => (u.order = best.orders[i]));
  const geo = place(best.cand.order, best.cand.split);
  const R = tableRects(geo);
  for (const [id, r] of R) {
    const t = tableById.get(id);
    t.x = r.x;
    t.y = r.y;
  }
  for (const g of pos.groups) {
    if (!g.isGroup) continue;
    const ts = g.tableIds.map((id) => tableById.get(id));
    const x = Math.min(...ts.map((t) => t.x)) - C.GROUP_PAD;
    const y = Math.min(...ts.map((t) => t.y)) - C.GROUP_TOP;
    g.x = x;
    g.y = y;
    g.w = Math.max(...ts.map((t) => t.x + t.w)) + C.GROUP_PAD - x;
    g.h = Math.max(...ts.map((t) => t.y + t.h)) + C.GROUP_PAD - y;
  }
  const groupByKey = new Map(pos.groups.map((g) => [g.key, g]));
  let looseY = C.MARGIN;
  const right = Math.max(...pos.groups.filter((g) => g.isGroup).map((g) => g.x + g.w), ...pos.tables.map((t) => t.x + t.w));
  for (const note of pos.notes) {
    const g = note.groupKey != null ? groupByKey.get(note.groupKey) : null;
    if (g && g.isGroup) {
      note.x = g.x;
      note.y = g.y - 11 - C.NOTE_GAP - note.h; // sits in the band reserved above the label chip
    } else {
      note.x = right + C.GAP_X; // notes that belong to no group: a column on the right
      note.y = looseY;
      looseY += note.h + 20;
    }
  }

  const allRight = [...pos.groups.filter((g) => g.isGroup).map((g) => g.x + g.w), ...pos.tables.map((t) => t.x + t.w), ...pos.notes.map((n) => n.x + n.w)];
  const allBottom = [...pos.groups.filter((g) => g.isGroup).map((g) => g.y + g.h), ...pos.tables.map((t) => t.y + t.h), ...pos.notes.map((n) => n.y + n.h)];
  pos.width = Math.max(...allRight) + C.MARGIN;
  pos.height = Math.max(...allBottom) + C.MARGIN;
  pos.arrangement = {
    engine: "grid",
    rows: best.cand.split,
    fitZoom: Math.min(C.SCREEN_W / pos.width, C.SCREEN_H / pos.height),
    crossings: best.cost.crossings,
    linesThroughTables: best.cost.through,
  };
  return pos;
}
