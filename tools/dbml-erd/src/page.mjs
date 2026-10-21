import { esc, hexToRgba } from "./svg.mjs";

/** Compact metadata the browser needs (no geometry — the SVG already has it). */
export function buildMeta(model, pos, extra = {}) {
  return {
    ...extra,
    name: model.name ?? "schema",
    databaseType: model.databaseType,
    metrics: {
      HEAD_H: pos.metrics.HEAD_H,
      ROW_H: pos.metrics.ROW_H,
      GROUP_PAD: pos.metrics.GROUP_PAD,
      GROUP_HEAD: pos.metrics.GROUP_HEAD,
    },
    defaultGroup: model.DEFAULT_GROUP,
    groups: pos.groups
      .filter((g) => g.isGroup)
      .map((g) => ({ key: g.key, name: g.name, color: g.color, tableCount: g.tableIds.length })),
    tables: pos.tables.map((t) => ({
      id: t.id,
      name: t.name,
      ownColor: t.headerColor,
      groupKey: t.groupKey,
      columnCount: t.columns.length,
      columns: t.columns.map((c) => c.name),
      note: t.note,
      indexCount: t.indexCount,
    })),
    notes: pos.notes.map((n) => ({ id: n.id, name: n.name, groupKey: n.groupKey, content: n.content })),
  };
}

const CSS = `
:root {
  --bg: #0d1117; --panel: #161b22; --border: #30363d; --fg: #e6edf3; --muted: #8b949e;
  --accent: #58a6ff; --tbl-bg: #161b22; --tbl-alt: #1c2128; --col-fg: #c9d1d9; --type-fg: #7d8590;
}
:root.light {
  --bg: #f6f8fa; --panel: #ffffff; --border: #d0d7de; --fg: #1f2328; --muted: #656d76;
  --accent: #0969da; --tbl-bg: #ffffff; --tbl-alt: #f6f8fa; --col-fg: #1f2328; --type-fg: #656d76;
}
* { box-sizing: border-box; }
html, body { height: 100%; margin: 0; }
body { display: flex; flex-direction: column; font: 13px/1.45 ui-sans-serif, -apple-system, "Segoe UI", sans-serif; background: var(--bg); color: var(--fg); }
.toolbar { display: flex; align-items: center; gap: 12px; padding: 8px 14px; background: var(--panel); border-bottom: 1px solid var(--border); flex-wrap: wrap; }
.toolbar .title { font-weight: 650; letter-spacing: .2px; }
.toolbar .sub { color: var(--muted); font-size: 12px; }
.toolbar input[type=search] { flex: 1; min-width: 180px; max-width: 420px; padding: 5px 10px; border-radius: 6px; border: 1px solid var(--border); background: var(--bg); color: var(--fg); }
.toolbar label { display: inline-flex; align-items: center; gap: 5px; color: var(--muted); cursor: pointer; user-select: none; }
.toolbar button { padding: 5px 11px; border-radius: 6px; border: 1px solid var(--border); background: var(--panel); color: var(--fg); cursor: pointer; font: inherit; }
.toolbar button:hover { border-color: var(--accent); color: var(--accent); }
main { flex: 1; display: flex; min-height: 0; }
#sidebar { width: 268px; flex: none; overflow: auto; background: var(--panel); border-right: 1px solid var(--border); padding: 10px 0 24px; }
#sidebar h3 { margin: 14px 14px 6px; font-size: 11px; text-transform: uppercase; letter-spacing: .7px; color: var(--muted); font-weight: 650; }
.row { display: flex; align-items: center; gap: 8px; padding: 4px 14px; cursor: pointer; }
.row:hover, .row.active { background: color-mix(in srgb, var(--accent) 12%, transparent); }
.row .swatch { width: 15px; height: 15px; border-radius: 4px; border: 1px solid var(--border); padding: 0; cursor: pointer; flex: none; background: none; }
.row .swatch::-webkit-color-swatch-wrapper { padding: 0; }
.row .swatch::-webkit-color-swatch { border: none; border-radius: 3px; }
.row .nm { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.row .ct { color: var(--muted); font-size: 11px; flex: none; }
#canvas { flex: 1; overflow: hidden; position: relative; cursor: grab; }
#canvas.grabbing { cursor: grabbing; }
#canvas svg { display: block; }
#hint { position: absolute; right: 12px; bottom: 10px; color: var(--muted); font-size: 11px; pointer-events: none; }
#detail { position: absolute; right: 12px; top: 12px; width: 300px; max-height: 60%; overflow: auto; background: var(--panel); border: 1px solid var(--border); border-radius: 8px; padding: 12px; display: none; box-shadow: 0 8px 24px rgba(0,0,0,.35); }
#detail h4 { margin: 0 0 2px; font-size: 14px; }
#detail .meta { color: var(--muted); font-size: 11px; margin-bottom: 8px; }
#detail .colrow { display: flex; gap: 6px; font-size: 12px; padding: 2px 0; border-top: 1px solid var(--border); }
#detail .colrow .n { flex: 1; } #detail .colrow .t { color: var(--type-fg); }
#detail .notebox { margin-top: 10px; padding: 8px; border-radius: 6px; background: var(--bg); border: 1px solid var(--border); font-size: 12px; white-space: pre-wrap; }
#status { padding: 4px 14px; border-top: 1px solid var(--border); background: var(--panel); color: var(--muted); font-size: 11px; }

/* diagram */
text { font-family: ui-sans-serif, -apple-system, "Segoe UI", sans-serif; }
.group-label { fill: #fff; font-size: 11.5px; font-weight: 650; }
.note-text { font-size: 12px; fill: var(--fg); }
.tbl-body { fill: var(--tbl-bg); stroke: var(--border); stroke-width: 1; }
.tbl-name { fill: #fff; font-size: 13px; font-weight: 650; }
.tbl-sep { stroke: var(--border); stroke-width: 1; }
.col-bg { fill: transparent; }
.table:nth-of-type(even) .col-bg { fill: var(--tbl-alt); }
.col-name { fill: var(--col-fg); font-size: 12px; }
.col-name.is-pk { font-weight: 650; }
.col-type { fill: var(--type-fg); font-size: 11.5px; }
.badge.pk { fill: var(--muted); font-size: 9px; font-weight: 700; }
.ref-label { fill: var(--muted); font-size: 10px; }

.table, .note, .group-chip, .group-handle, .group-label, .group-grip { cursor: move; }
.group-box { cursor: move; }
.grip circle { opacity: .55; }
.grabbing .table, .grabbing .note, .grabbing .group-box { cursor: grabbing; }
.dim { opacity: .16; }
.table.hit .tbl-body { stroke: var(--accent); stroke-width: 2; }
.ref.hit path { stroke-width: 2.6; stroke-opacity: 1; }
.ref.hit .ref-label { fill: var(--accent); font-weight: 700; }
`;

const JS = `
(function () {
  const M = window.__ERD__;
  const svg = document.getElementById('erd');
  const vp = document.getElementById('viewport');
  const canvas = document.getElementById('canvas');
  const state = { k: 1, x: 0, y: 0, overrides: {}, pinned: null };

  // ---------- pan / zoom ----------
  // The SVG fills the canvas (1 user unit = 1px before zoom) and all zoom/pan
  // lives on #viewport, so content dragged anywhere stays visible.
  svg.removeAttribute('viewBox');
  svg.setAttribute('width', '100%');
  svg.setAttribute('height', '100%');
  function apply() { vp.setAttribute('transform', 'translate(' + state.x + ',' + state.y + ') scale(' + state.k + ')'); }
  function contentBox() {
    // getBBox ignores #viewport's own transform -> diagram coordinates
    const b = vp.getBBox();
    return b.width && b.height ? b : { x: 0, y: 0, width: 1000, height: 800 };
  }
  function fit() {
    const b = contentBox();
    const r = canvas.getBoundingClientRect();
    const k = Math.min((r.width - 40) / b.width, (r.height - 40) / b.height, 1.25);
    state.k = k;
    state.x = (r.width - b.width * k) / 2 - b.x * k;
    state.y = (r.height - b.height * k) / 2 - b.y * k;
    apply();
  }
  canvas.addEventListener('wheel', (e) => {
    e.preventDefault();
    const r = canvas.getBoundingClientRect();
    const px = e.clientX - r.left, py = e.clientY - r.top;
    const factor = e.deltaY < 0 ? 1.12 : 1 / 1.12;
    const k2 = Math.min(4, Math.max(0.06, state.k * factor));
    state.x = px - (px - state.x) * (k2 / state.k);
    state.y = py - (py - state.y) * (k2 / state.k);
    state.k = k2; apply();
  }, { passive: false });
  document.getElementById('fitBtn').onclick = fit;

  // ---------- positions: drag + persist ----------
  // Every movable element keeps its rendered position in data-x/data-y.
  // We store where the user put it and apply translate(dx, dy) on top.
  const STORE = 'dbml-erd:positions:' + M.name;
  const HEAD_H = M.metrics.HEAD_H, ROW_H = M.metrics.ROW_H;
  const base = (el) => ({ x: +el.dataset.x, y: +el.dataset.y });
  const tablesById = {};
  svg.querySelectorAll('.table').forEach(el => {
    const b = base(el);
    tablesById[el.dataset.table] = { el, bx: b.x, by: b.y, x: b.x, y: b.y, w: +el.dataset.w, h: +el.dataset.h };
  });
  // A group has no position of its own: its box is always fitted around its
  // tables (same padding the auto layout uses), so moving a table resizes it.
  const GROUP_PAD = M.metrics.GROUP_PAD, GROUP_TOP = M.metrics.GROUP_HEAD + 8;
  const groupsByKey = {};
  svg.querySelectorAll('.group').forEach(el => {
    groupsByKey[el.dataset.group] = {
      el,
      box: el.querySelector('.group-box'),
      handle: el.querySelector('.group-handle'),
      grip: el.querySelector('.group-grip'),
      chip: el.querySelector('.group-chip'),
      label: el.querySelector('.group-label'),
    };
  });
  function fitGroup(key) {
    const g = groupsByKey[key]; if (!g) return;
    const members = Object.values(tablesById).filter(t => t.el.dataset.group === key);
    if (!members.length) return;
    const x = Math.min(...members.map(t => t.x)) - GROUP_PAD;
    const y = Math.min(...members.map(t => t.y)) - GROUP_TOP;
    const r = Math.max(...members.map(t => t.x + t.w)) + GROUP_PAD;
    const b = Math.max(...members.map(t => t.y + t.h)) + GROUP_PAD;
    g.box.setAttribute('x', x); g.box.setAttribute('y', y);
    g.box.setAttribute('width', r - x); g.box.setAttribute('height', b - y);
    if (g.handle) { g.handle.setAttribute('x', x + 4); g.handle.setAttribute('y', y + 4); }
    if (g.grip) g.grip.setAttribute('transform', 'translate(' + (x + 15) + ',' + (y + 12) + ')');
    if (g.chip) { g.chip.setAttribute('x', x + 10); g.chip.setAttribute('y', y - 11); }
    if (g.label) { g.label.setAttribute('x', x + 19); g.label.setAttribute('y', y + 4); }
  }
  function fitGroups(keys) { (keys ? [...keys] : Object.keys(groupsByKey)).forEach(fitGroup); }
  const notesByName = {};
  svg.querySelectorAll('.note').forEach(el => { const b = base(el); notesByName[el.dataset.name] = { el, bx: b.x, by: b.y, x: b.x, y: b.y }; });

  function place(o) { o.el.setAttribute('transform', 'translate(' + (o.x - o.bx) + ',' + (o.y - o.by) + ')'); }

  function anchor(t, row, side) { return { x: side === 'right' ? t.x + t.w : t.x, y: t.y + HEAD_H + row * ROW_H + ROW_H / 2 }; }
  function routeRef(r) {
    const a0 = tablesById[r.dataset.from], b0 = tablesById[r.dataset.to];
    if (!a0 || !b0) return;
    const fr = +r.dataset.fromRow, tr = +r.dataset.toRow;
    let d, mx, my;
    const overlapX = a0.x < b0.x + b0.w && b0.x < a0.x + a0.w;
    if (r.dataset.self === '1' || overlapX) {
      // stacked in one column: loop around the outside, on the side with no neighbour
      const y1 = Math.min(a0.y, b0.y), y2 = Math.max(a0.y + a0.h, b0.y + b0.h);
      const R = Math.max(a0.x + a0.w, b0.x + b0.w), L = Math.min(a0.x, b0.x);
      const others = Object.values(tablesById).filter(t => t !== a0 && t !== b0 && t.y < y2 && t.y + t.h > y1);
      const blockedR = others.some(t => t.x >= R - 1 && t.x < R + 70);
      const blockedL = others.some(t => t.x + t.w <= L + 1 && t.x + t.w > L - 70);
      const side = blockedR && !blockedL ? 'left' : 'right';
      const a = anchor(a0, fr, side), b = anchor(b0, tr, side), out = side === 'right' ? R + 34 : L - 34;
      d = 'M ' + a.x + ' ' + a.y + ' C ' + out + ' ' + a.y + ', ' + out + ' ' + b.y + ', ' + b.x + ' ' + b.y;
      mx = side === 'right' ? out + 6 : out - 6; my = (a.y + b.y) / 2;
    } else {
      // pick the facing edges: whichever side is closer
      const ltr = a0.x + a0.w / 2 <= b0.x + b0.w / 2;
      const a = anchor(a0, fr, ltr ? 'right' : 'left'), b = anchor(b0, tr, ltr ? 'left' : 'right');
      const dx = Math.max(40, Math.abs(b.x - a.x) * 0.45);
      const c1 = ltr ? a.x + dx : a.x - dx, c2 = ltr ? b.x - dx : b.x + dx;
      d = 'M ' + a.x + ' ' + a.y + ' C ' + c1 + ' ' + a.y + ', ' + c2 + ' ' + b.y + ', ' + b.x + ' ' + b.y;
      mx = (a.x + b.x) / 2; my = (a.y + b.y) / 2;
    }
    r.querySelector('path').setAttribute('d', d);
    const lbl = r.querySelector('text'); if (lbl) { lbl.setAttribute('x', mx); lbl.setAttribute('y', my - 4); }
  }
  function routeRefsFor(ids) {
    svg.querySelectorAll('.ref').forEach(r => { if (!ids || ids.has(r.dataset.from) || ids.has(r.dataset.to)) routeRef(r); });
  }

  // Where the layout lives:
  //   served by "npm run erd" (http)  -> the layout file next to the .dbml (source of truth)
  //   opened as a plain file (file://) -> the layout file baked in at render time,
  //                                       plus unsaved drags kept in this browser
  const SERVED = location.protocol === 'http:' || location.protocol === 'https:';
  const FILE_LAYOUT = window.__ERD_LAYOUT__ || {};
  const LAYOUT_FILE = M.layoutFile || 'layout file';
  const count = (l) => l ? Object.keys(l.tables || {}).length + Object.keys(l.notes || {}).length : 0;
  const readLocal = () => { try { return JSON.parse(localStorage.getItem(STORE) || 'null'); } catch (e) { return null; } };
  let saveState = 'idle';

  function snapshot() {
    const out = { tables: {}, notes: {} };
    for (const id in tablesById) { const t = tablesById[id]; if (t.x !== t.bx || t.y !== t.by) out.tables[t.el.dataset.name] = { x: t.x, y: t.y }; }
    for (const n in notesByName) { const o = notesByName[n]; if (o.x !== o.bx || o.y !== o.by) out.notes[n] = { x: o.x, y: o.y }; }
    return out;
  }
  function putLayout(layout) {
    saveState = 'saving'; updateLayoutStatus();
    return fetch('/layout', { method: 'PUT', headers: { 'Content-Type': 'application/json', 'X-Dbml-Erd': '1' }, body: JSON.stringify(layout) })
      .then(r => { if (!r.ok) throw new Error('HTTP ' + r.status); saveState = 'saved'; })
      .catch(e => { saveState = 'error:' + e.message; })
      .then(updateLayoutStatus);
  }
  function save() {
    const out = snapshot();
    if (SERVED) putLayout(out);
    else { try { localStorage.setItem(STORE, JSON.stringify(out)); } catch (e) {} updateLayoutStatus(); }
  }
  function applyLayout(saved) {
    let n = 0;
    for (const id in tablesById) { const t = tablesById[id], p = saved.tables && saved.tables[t.el.dataset.name]; if (p) { t.x = p.x; t.y = p.y; place(t); n++; } }
    for (const nm in notesByName) { const o = notesByName[nm], p = saved.notes && saved.notes[nm]; if (p) { o.x = p.x; o.y = p.y; place(o); n++; } }
    return n;
  }
  function restore() {
    applyLayout(FILE_LAYOUT);
    const local = readLocal();
    if (count(local)) {
      applyLayout(local); // older browser-only positions, or unsaved file:// drags
      if (SERVED) {
        // first run with the server: move what you arranged in this browser into the file
        putLayout(snapshot()).then(() => { if (saveState === 'saved') try { localStorage.removeItem(STORE); } catch (e) {} });
      }
    }
    routeRefsFor(null);
    fitGroups();
  }
  function resetLayout() {
    try { localStorage.removeItem(STORE); } catch (e) {}
    for (const o of [...Object.values(tablesById), ...Object.values(notesByName)]) { o.x = o.bx; o.y = o.by; o.el.removeAttribute('transform'); }
    routeRefsFor(null); fitGroups(); fit();
    if (SERVED) putLayout({ tables: {}, notes: {} }); else updateLayoutStatus();
  }
  function updateLayoutStatus() {
    const el = document.getElementById('status');
    if (SERVED) {
      const n = count(snapshot());
      const where = 'saved to ' + LAYOUT_FILE;
      el.textContent =
        saveState === 'saving' ? 'saving to ' + LAYOUT_FILE + '…' :
        saveState.startsWith('error') ? '⚠ could not save to ' + LAYOUT_FILE + ' (' + saveState.slice(6) + ') — is "npm run erd" still running?' :
        n ? 'custom layout: ' + n + ' item(s) moved · ' + where + ' · "Reset layout" to undo'
          : 'auto layout · drag a table, a group or a note to rearrange — positions are ' + where;
      return;
    }
    const unsaved = count(readLocal());
    el.textContent = unsaved
      ? 'opened as a file: ' + unsaved + ' drag(s) kept in this browser only — run "npm run erd" to save them to ' + LAYOUT_FILE
      : 'read-only view of ' + LAYOUT_FILE + ' · run "npm run erd" to rearrange and save';
  }

  // One mousedown handler decides: move a table, a group, a note, or pan.
  let drag = null;
  canvas.addEventListener('mousedown', (e) => {
    if (e.button !== 0) return;
    const p = { x: e.clientX, y: e.clientY };
    const tEl = e.target.closest('.table');
    const gEl = !tEl && e.target.closest('.group');
    const nEl = !tEl && !gEl && e.target.closest('.note');
    if (tEl) {
      tEl.parentNode.appendChild(tEl); // bring to front: last child paints on top
      drag = { kind: 'table', items: [tablesById[tEl.dataset.table]], start: p, moved: false };
    } else if (gEl) {
      const key = gEl.dataset.group;
      const members = Object.values(tablesById).filter(t => t.el.dataset.group === key);
      const notes = Object.values(notesByName).filter(o => o.el.dataset.group === key);
      members.forEach(t => t.el.parentNode.appendChild(t.el)); // the whole group comes to the front
      gEl.parentNode.appendChild(gEl);
      drag = { kind: 'group', items: [...members, ...notes], start: p, moved: false };
    } else if (nEl) {
      drag = { kind: 'note', items: [notesByName[nEl.dataset.name]], start: p, moved: false };
    } else {
      drag = { kind: 'pan', start: p, ox: state.x, oy: state.y, moved: false };
    }
    if (drag.items) drag.origin = drag.items.map(o => ({ x: o.x, y: o.y }));
    e.preventDefault();
  });
  window.addEventListener('mousemove', (e) => {
    if (!drag) return;
    const dx = e.clientX - drag.start.x, dy = e.clientY - drag.start.y;
    if (!drag.moved && Math.abs(dx) + Math.abs(dy) < 4) return; // still a click
    drag.moved = true;
    state.dragging = true;
    canvas.classList.add('grabbing');
    if (drag.kind === 'pan') { state.x = drag.ox + dx; state.y = drag.oy + dy; apply(); return; }
    const sx = dx / state.k, sy = dy / state.k;
    const ids = new Set(), groups = new Set();
    drag.items.forEach((o, i) => {
      o.x = Math.round(drag.origin[i].x + sx); o.y = Math.round(drag.origin[i].y + sy); place(o);
      if (o.el.classList.contains('table')) { ids.add(o.el.dataset.table); groups.add(o.el.dataset.group); }
    });
    routeRefsFor(ids);
    fitGroups(groups);
  });
  window.addEventListener('mouseup', () => {
    if (drag && drag.moved) {
      if (drag.kind !== 'pan') save();
      state.suppressClick = true; setTimeout(() => (state.suppressClick = false), 0);
    }
    drag = null; state.dragging = false; canvas.classList.remove('grabbing');
  });

  // centre the view on a table (used by the sidebar)
  function jumpTo(id) {
    const t = tablesById[id]; if (!t) return;
    const r = canvas.getBoundingClientRect();
    state.k = Math.min(1.4, Math.max(state.k, 0.95));
    state.x = r.width / 2 - (t.x + t.w / 2) * state.k;
    state.y = r.height / 2 - (t.y + t.h / 2) * state.k;
    apply();
  }
  document.getElementById('resetBtn').onclick = () => { if (confirm('Discard your custom positions and go back to the auto layout?')) resetLayout(); };

  // ---------- highlight ----------
  const tables = () => svg.querySelectorAll('.table');
  const refs = () => svg.querySelectorAll('.ref');
  function clearDim() { tables().forEach(t => t.classList.remove('dim')); refs().forEach(r => r.classList.remove('dim', 'hit')); }
  function focusTable(id) {
    clearDim();
    if (id == null) { svg.querySelectorAll('.note').forEach(n => n.classList.remove('dim')); return; }
    const related = new Set([String(id)]);
    refs().forEach(r => {
      const f = r.dataset.from, t = r.dataset.to;
      if (f === String(id) || t === String(id)) { r.classList.add('hit'); related.add(f); related.add(t); }
      else r.classList.add('dim');
    });
    tables().forEach(t => { if (!related.has(t.dataset.table)) t.classList.add('dim'); });
  }
  svg.querySelectorAll('.table').forEach(g => {
    g.addEventListener('mouseenter', () => { if (!state.pinned && !state.dragging) focusTable(g.dataset.table); });
    g.addEventListener('mouseleave', () => { if (!state.pinned && !state.dragging) clearDim(); });
    g.addEventListener('click', (e) => { e.stopPropagation(); if (state.suppressClick) return; state.pinned = state.pinned === g.dataset.table ? null : g.dataset.table; showDetail(state.pinned); focusTable(state.pinned); });
  });
  canvas.addEventListener('click', (e) => { if (state.suppressClick || e.target.closest('.table')) return; state.pinned = null; showDetail(null); clearDim(); });

  // ---------- detail ----------
  const detail = document.getElementById('detail');
  function showDetail(id) {
    if (id == null) { detail.style.display = 'none'; return; }
    const t = M.tables.find(x => String(x.id) === String(id));
    if (!t) { detail.style.display = 'none'; return; }
    const g = M.groups.find(g => g.key === t.groupKey);
    detail.innerHTML = '<h4>' + esc(t.name) + '</h4>' +
      '<div class="meta">' + t.columnCount + ' columns · ' + t.indexCount + ' indexes' + (g ? ' · <span style="color:' + (state.overrides['group:' + g.key] || g.color) + '">' + esc(g.name) + '</span>' : '') + '</div>' +
      t.columns.map(c => '<div class="colrow"><span class="n">' + (t.columns.indexOf(c) >= 0 ? '' : '') + esc(c) + '</span></div>').join('') +
      (t.note ? '<div class="notebox">' + esc(t.note) + '</div>' : '');
    detail.style.display = 'block';
  }
  function esc(s) { return String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c])); }

  // ---------- live colours ----------
  function hexRgb(hex, a) {
    const h = hex.replace('#', ''); const n = h.length === 3 ? h.split('').map(c => c + c).join('') : h; const i = parseInt(n, 16);
    return 'rgba(' + ((i >> 16) & 255) + ',' + ((i >> 8) & 255) + ',' + (i & 255) + ',' + a + ')';
  }
  function paintGroup(key, color) {
    const g = svg.querySelector('.group[data-group="' + cssEsc(key) + '"]');
    if (g) { const r = g.querySelector('.group-box'), c = g.querySelector('.group-chip'); if (r) { r.setAttribute('fill', hexRgb(color, 0.07)); r.setAttribute('stroke', hexRgb(color, 0.42)); } if (c) c.setAttribute('fill', color); }
    svg.querySelectorAll('.note[data-group="' + cssEsc(key) + '"] rect').forEach(r => { r.setAttribute('fill', hexRgb(color, 0.13)); r.setAttribute('stroke', hexRgb(color, 0.5)); });
    svg.querySelectorAll('.note[data-group="' + cssEsc(key) + '"] rect:last-of-type').forEach(r => r.setAttribute('fill', color));
    svg.querySelectorAll('.ref[data-group="' + cssEsc(key) + '"] path').forEach(p => p.setAttribute('stroke', color));
    svg.querySelectorAll('.table[data-group="' + cssEsc(key) + '"][data-from-group="1"] .tbl-head').forEach(r => r.setAttribute('fill', color));
  }
  function paintTable(id, color) {
    svg.querySelectorAll('.table[data-table="' + cssEsc(id) + '"] .tbl-head').forEach(r => r.setAttribute('fill', color));
  }
  function cssEsc(s) { return String(s).replace(/"/g, '\\\\"'); }

  // ---------- sidebar ----------
  const sb = document.getElementById('sidebar');
  sb.innerHTML =
    '<h3>Groups</h3>' +
    M.groups.map(g => '<div class="row" data-gk="' + esc(g.key) + '"><input type="color" class="swatch" data-kind="group" data-key="' + esc(g.key) + '" value="' + (g.color || '#8b949e') + '"><span class="nm">' + esc(g.name) + '</span><span class="ct">' + g.tableCount + '</span></div>').join('') +
    '<h3>Tables</h3>' +
    M.tables.map(t => '<div class="row" data-tid="' + t.id + '"><input type="color" class="swatch" data-kind="table" data-key="' + t.id + '" value="' + (t.ownColor || '#316896') + '"><span class="nm">' + esc(t.name) + '</span><span class="ct">' + t.columnCount + '</span></div>').join('');

  sb.addEventListener('input', (e) => {
    const el = e.target; if (el.dataset.kind !== 'group' && el.dataset.kind !== 'table') return;
    if (el.dataset.kind === 'group') { state.overrides['group:' + el.dataset.key] = el.value; paintGroup(el.dataset.key, el.value); }
    else { state.overrides['table:' + el.dataset.key] = el.value; paintTable(el.dataset.key, el.value); }
  });
  sb.addEventListener('mouseover', (e) => { const r = e.target.closest('.row'); if (r && r.dataset.tid && !state.pinned) focusTable(r.dataset.tid); });
  sb.addEventListener('mouseout', (e) => { if (!state.pinned) clearDim(); });
  sb.addEventListener('click', (e) => {
    if (e.target.matches('input[type=color]')) return; // picking a colour, not jumping
    const r = e.target.closest('.row'); if (!r) return;
    if (r.dataset.tid) { state.pinned = r.dataset.tid; showDetail(r.dataset.tid); focusTable(r.dataset.tid); jumpTo(r.dataset.tid); }
    else if (r.dataset.gk) {
      const ids = Object.values(tablesById).filter(t => t.el.dataset.group === r.dataset.gk);
      if (ids.length) jumpTo(ids[0].el.dataset.table);
    }
  });

  // ---------- search ----------
  const search = document.getElementById('search');
  search.addEventListener('input', () => {
    const q = search.value.trim().toLowerCase();
    if (!q) { clearDim(); return; }
    tables().forEach(t => {
      const hit = t.dataset.name.toLowerCase().includes(q);
      t.classList.toggle('dim', !hit);
    });
    refs().forEach(r => r.classList.add('dim'));
  });

  // ---------- toggles / export ----------
  document.getElementById('tglNotes').onchange = (e) => svg.querySelectorAll('.layer-notes').forEach(l => l.style.display = e.target.checked ? '' : 'none');
  document.getElementById('tglRefs').onchange = (e) => svg.querySelectorAll('.layer-refs').forEach(l => l.style.display = e.target.checked ? '' : 'none');
  document.getElementById('darkBtn').onclick = () => { document.documentElement.classList.toggle('light'); document.getElementById('darkBtn').textContent = document.documentElement.classList.contains('light') ? 'Dark' : 'Light'; };
  document.getElementById('exportBtn').onclick = () => {
    const b = contentBox(), pad = 24;
    const clone = svg.cloneNode(true);
    clone.setAttribute('xmlns', 'http://www.w3.org/2000/svg');
    clone.setAttribute('viewBox', (b.x - pad) + ' ' + (b.y - pad) + ' ' + (b.width + pad * 2) + ' ' + (b.height + pad * 2));
    clone.setAttribute('width', Math.ceil(b.width + pad * 2));
    clone.setAttribute('height', Math.ceil(b.height + pad * 2));
    clone.querySelector('#viewport').removeAttribute('transform'); // export the diagram, not the current zoom
    clone.querySelectorAll('.dim, .hit').forEach(n => n.classList.remove('dim', 'hit'));
    // CSS lives in the page, not the SVG: inline the computed colours the export needs
    const style = document.createElementNS('http://www.w3.org/2000/svg', 'style');
    style.textContent = [...document.styleSheets].flatMap(s => { try { return [...s.cssRules].map(r => r.cssText); } catch (e) { return []; } })
      .filter(t => /^(text|\\.|:root)/.test(t)).join('\\n')
      .replace(/var\\(--([a-z-]+)\\)/g, (_, v) => getComputedStyle(document.documentElement).getPropertyValue('--' + v).trim());
    clone.insertBefore(style, clone.firstChild);
    const bg = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
    bg.setAttribute('x', b.x - pad); bg.setAttribute('y', b.y - pad);
    bg.setAttribute('width', b.width + pad * 2); bg.setAttribute('height', b.height + pad * 2);
    bg.setAttribute('fill', document.documentElement.classList.contains('light') ? '#ffffff' : '#0d1117');
    clone.insertBefore(bg, clone.firstChild);
    const blob = new Blob([clone.outerHTML], { type: 'image/svg+xml' });
    const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = M.name + '.svg'; a.click();
  };
  document.getElementById('copyBtn').onclick = () => {
    const lines = ['// dbml-erd — generated colour settings'];
    for (const g of M.groups) lines.push('TableGroup ' + g.name + ' [color: ' + (state.overrides['group:' + g.key] || g.color) + ']');
    for (const t of M.tables) {
      const c = state.overrides['table:' + t.id] || t.ownColor;
      if (c) lines.push('Table ' + t.name + ' [headercolor: ' + c + ']');
    }
    navigator.clipboard.writeText(lines.join('\\n')).then(() => {
      const b = document.getElementById('copyBtn'); const o = b.textContent; b.textContent = 'Copied'; setTimeout(() => (b.textContent = o), 1200);
    });
  };

  restore();
  updateLayoutStatus();
  fit();

  // served: reload when the .dbml is re-rendered (layout is in the file, so nothing is lost)
  if (SERVED && window.EventSource) {
    const es = new EventSource('/events');
    es.addEventListener('reload', () => location.reload());
  }
  window.addEventListener('resize', fit);
})();
`;

/** JSON that is safe inside a <script> block (note text could contain "</script>"). */
const scriptJson = (v) => JSON.stringify(v ?? null).replace(/</g, "\\u003c").replace(/\u2028/g, "\\u2028").replace(/\u2029/g, "\\u2029");

export function renderPage({ model, pos, svg, meta, layout = {} }) {
  const title = `${model.name ?? "schema"} · DBML ERD`;
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(title)}</title>
<style>${CSS}</style>
</head>
<body>
  <header class="toolbar">
    <span class="title">${esc(model.name ?? "schema")}</span>
    <span class="sub">${model.databaseType ?? ""} · ${pos.tables.length} tables · ${pos.groups.filter((g) => g.isGroup).length} groups · ${pos.refs.length} refs</span>
    <input id="search" type="search" placeholder="Search tables…  (hover to trace refs, click to pin)">
    <label><input type="checkbox" id="tglNotes" checked> Notes</label>
    <label><input type="checkbox" id="tglRefs" checked> Refs</label>
    <button id="fitBtn">Fit</button>
    <button id="resetBtn" title="Forget dragged positions">Reset layout</button>
    <button id="copyBtn">Copy colours</button>
    <button id="exportBtn">Export SVG</button>
    <button id="darkBtn">Light</button>
  </header>
  <main>
    <aside id="sidebar"></aside>
    <section id="canvas">
      ${svg}
      <div id="detail"></div>
      <div id="hint">drag a table / group / note to move it · drag empty space to pan · scroll to zoom</div>
    </section>
  </main>
  <footer id="status">rendered by dbml-erd · colours are yours — no subscription, no API</footer>
<script>
window.__ERD__ = ${scriptJson(meta)};
window.__ERD_LAYOUT__ = ${scriptJson(layout)};
${JS}
</script>
</body>
</html>`;
}

export { hexToRgba };
