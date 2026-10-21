import dagre from "@dagrejs/dagre";

const M = {
  FONT: 12,
  CHAR_W: 6.85,
  PAD: 12,
  PK_W: 16,
  NAME_GAP: 10,
  ROW_H: 21,
  HEAD_H: 32,
  MIN_TABLE_W: 190,
  TABLE_GAP: 34,
  GROUP_PAD: 28,
  GROUP_HEAD: 30,
  GROUP_GAP: 70,
  NOTE_W: 260,
  NOTE_CHAR: 38,
  NOTE_PAD: 12,
};

const est = (s, size = M.FONT) => String(s ?? "").length * size * (M.CHAR_W / 12) * 1.0;

function measureTable(t) {
  let nameW = est(t.name, 13);
  let typeW = 0;
  for (const c of t.columns) {
    nameW = Math.max(nameW, est(c.name));
    typeW = Math.max(typeW, est(c.type));
  }
  const w = Math.max(M.MIN_TABLE_W, M.PAD * 2 + M.PK_W + nameW + M.NAME_GAP + typeW);
  const h = M.HEAD_H + t.columns.length * M.ROW_H + 8;
  return { w, h };
}

function wrapNote(text, maxChars = M.NOTE_CHAR) {
  const lines = [];
  for (const para of String(text).split("\n")) {
    if (!para.trim()) {
      lines.push("");
      continue;
    }
    let cur = "";
    for (const word of para.split(/\s+/)) {
      const next = cur ? `${cur} ${word}` : word;
      if (next.length > maxChars && cur) {
        lines.push(cur);
        cur = word;
      } else {
        cur = next;
      }
    }
    if (cur) lines.push(cur);
  }
  return lines;
}

function measureNote(n) {
  const lines = wrapNote(n.content);
  const longest = lines.reduce((m, l) => Math.max(m, l.length), 0);
  const w = Math.max(160, Math.min(M.NOTE_W, M.NOTE_PAD * 2 + longest * M.CHAR_W));
  const h = M.NOTE_PAD * 2 + lines.length * (M.FONT + 4) + 16;
  return { w, h, lines };
}

/** Order tables inside one group so sources sit above sinks. */
function orderWithinGroup(tableIds, refs) {
  if (tableIds.length <= 1) return [...tableIds];
  const ids = new Set(tableIds);
  const g = new dagre.graphlib.Graph();
  g.setGraph({ rankdir: "TB", nodesep: 20, ranksep: 40 });
  g.setDefaultEdgeLabel(() => ({}));
  for (const id of tableIds) g.setNode(String(id), { width: 1, height: 1 });
  for (const r of refs) {
    const a = r.from?.tableId;
    const b = r.to?.tableId;
    if (a != null && b != null && a !== b && ids.has(a) && ids.has(b)) g.setEdge(String(a), String(b));
  }
  try {
    dagre.layout(g);
    return [...tableIds].sort((x, y) => {
      const dy = (g.node(String(y))?.y ?? 0) - (g.node(String(x))?.y ?? 0);
      return dy !== 0 ? dy : x - y;
    });
  } catch {
    return [...tableIds];
  }
}

/**
 * Lay out the whole diagram.
 *
 * Two passes of dagre:
 *   1. inside each group  (TB) -> vertical stack order
 *   2. across groups      (LR) -> which column each group lands in
 * Group boxes are then sized around their tables and shifted into place.
 */
export function layout(model) {
  const byId = new Map(model.tables.map((t) => [t.id, t]));
  const measure = new Map(model.tables.map((t) => [t.id, measureTable(t)]));

  const buckets = new Map();
  for (const t of model.tables) {
    const key = t.groupId ?? model.DEFAULT_GROUP;
    if (!buckets.has(key)) buckets.set(key, []);
    buckets.get(key).push(t.id);
  }
  const groupById = new Map(model.groups.map((g) => [g.id, g]));

  // ---- pass 1: inside each group ------------------------------------------
  const inner = new Map(); // groupKey -> { ordered, w, h, offsets: Map(tableId -> {dx,dy}) }
  for (const [key, ids] of buckets) {
    const ordered = orderWithinGroup(ids, model.refs);
    let y = M.GROUP_HEAD + 8;
    let maxW = 0;
    const offsets = new Map();
    for (const id of ordered) {
      const { w, h } = measure.get(id);
      offsets.set(id, { dx: 0, dy: y, w, h });
      y += h + M.TABLE_GAP;
      maxW = Math.max(maxW, w);
    }
    inner.set(key, {
      ordered,
      offsets,
      w: maxW + M.GROUP_PAD * 2,
      h: y - M.TABLE_GAP + M.GROUP_PAD,
      name: key === model.DEFAULT_GROUP ? null : groupById.get(key)?.name ?? null,
      color: key === model.DEFAULT_GROUP ? null : groupById.get(key)?.color ?? null,
      isGroup: key !== model.DEFAULT_GROUP,
    });
  }

  // ---- pass 2: across groups ----------------------------------------------
  const groupOfTable = new Map();
  for (const [key, ids] of buckets) for (const id of ids) groupOfTable.set(id, key);

  const crossWeights = new Map();
  for (const r of model.refs) {
    const a = groupOfTable.get(r.from.tableId);
    const b = groupOfTable.get(r.to.tableId);
    if (a == null || b == null || a === b) continue;
    const k = a < b ? `${a}|${b}` : `${b}|${a}`;
    crossWeights.set(k, (crossWeights.get(k) ?? 0) + 1);
  }

  const gg = new dagre.graphlib.Graph();
  gg.setGraph({ rankdir: "LR", nodesep: M.GROUP_GAP, ranksep: M.GROUP_GAP, edgesep: 30 });
  gg.setDefaultEdgeLabel(() => ({}));
  for (const [key, info] of inner) gg.setNode(key, { width: info.w, height: info.h });
  for (const [k, weight] of crossWeights) {
    const [a, b] = k.split("|");
    gg.setEdge(a, b, { weight });
  }
  try {
    dagre.layout(gg);
  } catch {
    /* fall through: dagre failure leaves nodes at origin */
  }

  const minDx = Math.min(...[...inner.keys()].map((k) => (gg.node(k)?.x ?? 0) - inner.get(k).w / 2));
  const minDy = Math.min(...[...inner.keys()].map((k) => (gg.node(k)?.y ?? 0) - inner.get(k).h / 2));

  const groups = [];
  const tables = [];
  for (const [key, info] of inner) {
    const node = gg.node(key);
    const gx = (node?.x ?? info.w / 2) - info.w / 2 - minDx + M.PAD;
    const gy = (node?.y ?? info.h / 2) - info.h / 2 - minDy + M.PAD;
    groups.push({
      key,
      id: key === model.DEFAULT_GROUP ? null : key,
      name: info.name,
      color: info.color,
      x: gx,
      y: gy,
      w: info.w,
      h: info.h,
      isGroup: info.isGroup,
      tableIds: info.ordered,
    });
    for (const id of info.ordered) {
      const t = byId.get(id);
      const { w, h } = measure.get(id);
      const o = info.offsets.get(id);
      tables.push({
        ...t,
        x: gx + M.GROUP_PAD + o.dx,
        y: gy + o.dy,
        w,
        h,
        groupKey: key,
        rowOf: new Map(t.columns.map((c, i) => [c.id, i])),
      });
    }
  }

  const tableById = new Map(tables.map((t) => [t.id, t]));

  // ---- refs ---------------------------------------------------------------
  const refs = model.refs
    .map((r) => {
      const a = tableById.get(r.from.tableId);
      const b = tableById.get(r.to.tableId);
      if (!a || !b) return null;
      const aRow = a.rowOf.get(r.from.fieldIds[0]) ?? 0;
      const bRow = b.rowOf.get(r.to.fieldIds[0]) ?? 0;
      return {
        id: r.id,
        self: a.id === b.id,
        from: { tableId: a.id, tableName: a.name, row: aRow, relation: r.from.relation, label: r.from.label },
        to: { tableId: b.id, tableName: b.name, row: bRow, relation: r.to.relation, label: r.to.label },
        ax: a.x + a.w,
        ay: a.y + M.HEAD_H + aRow * M.ROW_H + M.ROW_H / 2,
        bx: b.x,
        by: b.y + M.HEAD_H + bRow * M.ROW_H + M.ROW_H / 2,
      };
    })
    .filter(Boolean);

  // ---- notes --------------------------------------------------------------
  const notes = model.notes.map((n) => {
    const { w, h, lines } = measureNote(n);
    const match = groups.find(
      (g) => g.isGroup && (n.name === `label_${g.name}` || n.name.endsWith(`_${g.name}`) || n.name === g.name)
    );
    let x;
    let y;
    if (match) {
      x = match.x + match.w / 2 - w / 2;
      y = match.y - h - 16;
    } else {
      x = M.PAD;
      y = M.PAD;
    }
    return { ...n, x, y, w, h, lines, groupKey: match?.key ?? null };
  });

  // A note parked above its group can collide with whatever sits above it;
  // walk it upward until it clears every group box and every other note.
  const hits = (a, b) => a.x < b.x + b.w && a.x + a.w > b.x && a.y < b.y + b.h && a.y + a.h > b.y;
  for (const n of notes) {
    let guard = 0;
    while (
      guard++ < 600 &&
      (groups.some((g) => hits(n, g)) || notes.some((o) => o !== n && hits(n, o)))
    ) {
      n.y -= 10;
    }
  }

  // notes above groups can go negative; shift everything down
  const minY = Math.min(M.PAD, ...notes.map((n) => n.y), ...groups.map((g) => g.y));
  const shiftY = minY < M.PAD ? M.PAD - minY : 0;
  for (const g of groups) g.y += shiftY;
  for (const t of tables) t.y += shiftY;
  for (const r of refs) {
    r.ay += shiftY;
    r.by += shiftY;
  }
  for (const n of notes) n.y += shiftY;

  const width =
    Math.max(M.PAD, ...groups.map((g) => g.x + g.w), ...notes.map((n) => n.x + n.w)) + M.PAD;
  const height =
    Math.max(M.PAD, ...groups.map((g) => g.y + g.h), ...notes.map((n) => n.y + n.h)) + M.PAD;

  return { width, height, groups, tables, refs, notes, metrics: M, tableById };
}

export { M as METRICS };
