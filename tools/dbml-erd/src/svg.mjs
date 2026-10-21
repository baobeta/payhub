const esc = (s) =>
  String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");

const hexToRgba = (hex, a) => {
  if (!hex) return `rgba(127,127,127,${a})`;
  const h = hex.replace("#", "");
  const n = h.length === 3 ? h.split("").map((c) => c + c).join("") : h;
  const int = parseInt(n, 16);
  return `rgba(${(int >> 16) & 255},${(int >> 8) & 255},${int & 255},${a})`;
};

const relMark = (relation) => (relation === "*" ? "*" : "1");

const num = (n) => Math.round(n * 100) / 100;

/** Drag handle: grip dots that sit on a group or table header. */
function gripDots(cx, cy, color = "#fff") {
  const dots = [];
  for (let r = 0; r < 2; r++) {
    for (let c = -1; c <= 1; c++) {
      dots.push(`<circle cx="${cx + c * 5}" cy="${cy + r * 5}" r="1.4" fill="${color}"/>`);
    }
  }
  return dots.join("");
}

/** Anchor on the table's right edge for a given column row. */
function edgeAnchor(t, row, side, M) {
  const y = t.y + M.HEAD_H + row * M.ROW_H + M.ROW_H / 2;
  return { x: side === "right" ? t.x + t.w : t.x, y };
}

/**
 * Route a ref. Tables that overlap horizontally (stacked in one column) get a
 * loop around the outside of the column instead of a line drawn back through
 * them; the loop goes to whichever side has no neighbouring table in the way.
 * Mirrors routeRef() in page.mjs, which re-routes while dragging.
 */
export function routeRef(src, dst, fromRow, toRow, tables, M) {
  const overlapX = src.x < dst.x + dst.w && dst.x < src.x + src.w;
  if (src === dst || overlapX) {
    const y1 = Math.min(src.y, dst.y), y2 = Math.max(src.y + src.h, dst.y + dst.h);
    const R = Math.max(src.x + src.w, dst.x + dst.w), L = Math.min(src.x, dst.x);
    const near = (t, test) => t !== src && t !== dst && t.y < y2 && t.y + t.h > y1 && test(t);
    const blockedR = tables.some((t) => near(t, (t) => t.x >= R - 1 && t.x < R + 70));
    const blockedL = tables.some((t) => near(t, (t) => t.x + t.w <= L + 1 && t.x + t.w > L - 70));
    const side = blockedR && !blockedL ? "left" : "right";
    const a = edgeAnchor(src, fromRow, side, M), b = edgeAnchor(dst, toRow, side, M);
    const out = side === "right" ? R + 34 : L - 34;
    return {
      d: `M ${a.x} ${a.y} C ${out} ${a.y}, ${out} ${b.y}, ${b.x} ${b.y}`,
      mx: side === "right" ? out + 6 : out - 6,
      my: (a.y + b.y) / 2,
    };
  }
  const ltr = src.x + src.w / 2 <= dst.x + dst.w / 2;
  const a = edgeAnchor(src, fromRow, ltr ? "right" : "left", M);
  const b = edgeAnchor(dst, toRow, ltr ? "left" : "right", M);
  const dx = Math.max(40, Math.abs(b.x - a.x) * 0.45);
  const c1 = ltr ? a.x + dx : a.x - dx, c2 = ltr ? b.x - dx : b.x + dx;
  return { d: `M ${a.x} ${a.y} C ${c1} ${a.y}, ${c2} ${b.y}, ${b.x} ${b.y}`, mx: (a.x + b.x) / 2, my: (a.y + b.y) / 2 };
}

export function renderSvg(pos, model, overrides = {}) {
  const M = pos.metrics;
  const parts = [];

  parts.push(
    `<defs>`,
    `<filter id="tblShadow" x="-20%" y="-20%" width="140%" height="140%">
       <feDropShadow dx="0" dy="1" stdDeviation="1.6" flood-color="#000" flood-opacity="0.18"/>
     </filter>`,
    `<marker id="cap1" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
       <circle cx="5" cy="5" r="3.2" fill="none" stroke="context-stroke" stroke-width="1.6"/>
     </marker>`,
    `<marker id="capN" viewBox="0 0 12 10" refX="10" refY="5" markerWidth="10" markerHeight="9" orient="auto-start-reverse">
       <path d="M10,5 L1,1 M10,5 L1,5 M10,5 L1,9" fill="none" stroke="context-stroke" stroke-width="1.5" stroke-linecap="round"/>
     </marker>`,
    `</defs>`
  );

  // ---- group containers (behind everything) ------------------------------
  parts.push(`<g class="layer-groups">`);
  for (const g of pos.groups) {
    if (!g.isGroup) continue;
    const color = overrides[`group:${g.key}`] ?? g.color ?? "#8b949e";
    parts.push(
      `<g class="group" data-group="${esc(g.key)}" data-kind="group" data-x="${num(g.x)}" data-y="${num(g.y)}" data-w="${num(g.w)}" data-h="${num(g.h)}">
         <rect class="group-box" x="${g.x}" y="${g.y}" width="${g.w}" height="${g.h}" rx="10"
               fill="${hexToRgba(color, 0.07)}" stroke="${hexToRgba(color, 0.42)}"
               stroke-width="1.4" stroke-dasharray="1 0"/>
         <rect class="group-handle" x="${g.x + 4}" y="${g.y + 4}" width="22" height="22" rx="6" fill="transparent"/>
         <g class="grip group-grip" transform="translate(${g.x + 15},${g.y + 12})">${gripDots(0, 0)}</g>
         <rect x="${g.x + 10}" y="${g.y - 11}" width="${g.name.length * 7.4 + 18}" height="22" rx="11"
               class="group-chip" fill="${color}"/>
         <text x="${g.x + 19}" y="${g.y + 4}" class="group-label">${esc(g.name)}</text>
       </g>`
    );
  }
  parts.push(`</g>`);

  // ---- refs (behind tables so endpoints tuck under) ----------------------
  parts.push(`<g class="layer-refs">`);
  for (const r of pos.refs) {
    const src = pos.tableById.get(r.from.tableId);
    const dst = pos.tableById.get(r.to.tableId);
    const color = overrides[`group:${src.groupKey}`] ?? src.headerColor ?? "#8b949e";
    const { d, mx, my } = routeRef(src, dst, r.from.row, r.to.row, pos.tables, M);
    const m1 = relMark(r.from.relation);
    const m2 = relMark(r.to.relation);
    parts.push(
      `<g class="ref" data-ref="${r.id}" data-from="${r.from.tableId}" data-to="${r.to.tableId}" data-group="${esc(src.groupKey ?? "")}"
         data-from-row="${r.from.row}" data-to-row="${r.to.row}" data-self="${r.self ? "1" : "0"}">
         <path d="${d}" fill="none" stroke="${color}" stroke-width="1.5" stroke-opacity="0.85"
               marker-start="url(#cap${m1 === "*" ? "N" : "1"})" marker-end="url(#cap${m2 === "*" ? "N" : "1"})"/>
         <text x="${mx}" y="${my - 4}" class="ref-label" text-anchor="middle">${m1}–${m2}</text>
       </g>`
    );
  }
  parts.push(`</g>`);

  // ---- notes --------------------------------------------------------------
  parts.push(`<g class="layer-notes">`);
  for (const n of pos.notes) {
    const color = n.groupKey ? (overrides[`group:${n.groupKey}`] ?? pos.groups.find((g) => g.key === n.groupKey)?.color) : "#d4a72c";
    const lines = n.lines
      .map((l, i) => `<text x="${n.x + M.NOTE_PAD}" y="${n.y + M.NOTE_PAD + 16 + i * (M.FONT + 4)}" class="note-text">${esc(l)}</text>`)
      .join("");
    parts.push(
      `<g class="note" data-note="${esc(n.id)}" data-name="${esc(n.name)}" data-group="${esc(n.groupKey ?? "")}"
         data-x="${num(n.x)}" data-y="${num(n.y)}">
         <rect x="${n.x}" y="${n.y}" width="${n.w}" height="${n.h}" rx="6"
               fill="${hexToRgba(color ?? "#d4a72c", 0.13)}" stroke="${hexToRgba(color ?? "#d4a72c", 0.5)}" stroke-width="1.2"/>
         <rect x="${n.x}" y="${n.y}" width="3" height="${n.h}" rx="1.5" fill="${color ?? "#d4a72c"}"/>
         ${lines}
       </g>`
    );
  }
  parts.push(`</g>`);

  // ---- tables -------------------------------------------------------------
  parts.push(`<g class="layer-tables">`);
  for (const t of pos.tables) {
    const groupColor = t.groupKey && t.groupKey !== model.DEFAULT_GROUP
      ? (overrides[`group:${t.groupKey}`] ?? pos.groups.find((g) => g.key === t.groupKey)?.color)
      : null;
    const head = overrides[`table:${t.id}`] ?? t.headerColor ?? groupColor ?? "#316896";
    const rows = t.columns
      .map((c, i) => {
        const y = t.y + M.HEAD_H + i * M.ROW_H;
        const cy = y + M.ROW_H / 2 + 4;
        return `<g class="col" data-col="${c.id}">
          <rect x="${t.x + 1}" y="${y}" width="${t.w - 2}" height="${M.ROW_H}" class="col-bg"/>
          ${c.pk ? `<text x="${t.x + M.PAD}" y="${cy}" class="badge pk">PK</text>` : ""}
          <text x="${t.x + M.PAD + (c.pk ? M.PK_W : 0)}" y="${cy}" class="col-name${c.pk ? " is-pk" : ""}">${esc(c.name)}</text>
          <text x="${t.x + t.w - M.PAD}" y="${cy}" class="col-type" text-anchor="end">${esc(c.type)}</text>
        </g>`;
      })
      .join("");
    parts.push(
      `<g class="table" data-table="${t.id}" data-name="${esc(t.name)}" data-group="${esc(t.groupKey)}"
         data-own-color="${esc(t.headerColor ?? "")}" data-from-group="${!t.headerColor && groupColor ? "1" : "0"}"
         data-x="${num(t.x)}" data-y="${num(t.y)}" data-w="${num(t.w)}" data-h="${num(t.h)}">
         <rect x="${t.x}" y="${t.y}" width="${t.w}" height="${t.h}" rx="7" class="tbl-body" filter="url(#tblShadow)"/>
         <path d="M ${t.x} ${t.y + M.HEAD_H} H ${t.x + t.w}" class="tbl-sep"/>
         <rect x="${t.x + 1}" y="${t.y + 1}" width="${t.w - 2}" height="${M.HEAD_H - 1}" rx="6" class="tbl-head" fill="${head}"/>
         <rect x="${t.x + 1}" y="${t.y + M.HEAD_H - 6}" width="${t.w - 2}" height="6" class="tbl-head" fill="${head}"/>
         <text x="${t.x + t.w / 2}" y="${t.y + M.HEAD_H / 2 + 4.5}" class="tbl-name" text-anchor="middle">${esc(t.name)}</text>
         ${rows}
       </g>`
    );
  }
  parts.push(`</g>`);

  return `<svg id="erd" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${pos.width} ${pos.height}" width="${pos.width}" height="${pos.height}">
  <g id="viewport">
  ${parts.join("\n  ")}
  </g>
</svg>`;
}

export { esc, hexToRgba };
