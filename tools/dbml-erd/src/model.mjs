import { Compiler, MemoryProjectLayout, Filepath } from "@dbml/parse";
import { Parser } from "@dbml/core";

const DEFAULT_GROUP = "__ungrouped";

/**
 * Parse DBML text into a render-ready view model.
 *
 * Uses the same pipeline as the dbdiagram VS Code extension:
 *   @dbml/parse Compiler (new parser) -> @dbml/core Parser.parseJSONToDatabase -> normalize()
 * which is what exposes tableGroups, notes and headerColor.
 */
export function parseDbml(text, filename = "/schema.dbml") {
  // @dbml/parse's Filepath insists on a POSIX-absolute path; we only ever have
  // one in-memory file, so the basename is enough.
  const abs = filename.startsWith("/") ? filename : `/${filename.replace(/^.*[\\/]/, "")}`;
  const filepath = new Filepath(abs);
  const layout = new MemoryProjectLayout();
  layout.setSource(filepath, text);

  const compiler = new Compiler(layout);
  const report = compiler.interpretFile(filepath);

  const errors = (report.getErrors?.() ?? []).map((e) => ({
    message: e.diagnostic,
    line: e.nodeOrToken?.startPos?.line != null ? e.nodeOrToken.startPos.line + 1 : null,
  }));

  const raw = report.getValue();
  if (!raw) {
    return { name: null, databaseType: null, projectNote: null, tables: [], refs: [], groups: [], notes: [], errors };
  }

  const db = Parser.parseJSONToDatabase(raw).normalize();

  const groups = Object.values(db.tableGroups ?? {}).map((g) => ({
    id: g.id,
    name: g.name,
    color: g.color ?? null,
    tableIds: g.tableIds ?? [],
  }));

  const tables = Object.values(db.tables ?? {}).map((t) => ({
    id: t.id,
    name: t.name,
    headerColor: t.headerColor ?? null,
    note: t.note?.trim() || null,
    groupId: t.groupId ?? null,
    schemaId: t.schemaId,
    columns: (t.fieldIds ?? [])
      .map((fid) => db.fields[fid])
      .filter(Boolean)
      .map((f) => ({
        id: f.id,
        name: f.name,
        type: formatType(f.type),
        pk: !!f.pk,
        unique: !!f.unique,
        note: f.note?.trim() || null,
        def: f.dbdefault?.value ?? null,
      })),
    indexCount: (t.indexIds ?? []).length,
  }));

  const refs = Object.values(db.refs ?? {}).map((r) => {
    const [a, b] = (r.endpointIds ?? []).map((id) => db.endpoints[id]).filter(Boolean);
    return {
      id: r.id,
      from: a
        ? { tableId: tableIdOf(db, a), fieldIds: a.fieldIds ?? [], relation: a.relation, label: a.fieldNames?.join(", ") }
        : null,
      to: b
        ? { tableId: tableIdOf(db, b), fieldIds: b.fieldIds ?? [], relation: b.relation, label: b.fieldNames?.join(", ") }
        : null,
    };
  }).filter((r) => r.from && r.to);

  const notes = Object.values(db.notes ?? {}).map((n) => ({
    id: n.id,
    name: n.name,
    content: (n.content ?? "").trim(),
  }));

  const project = db.database ?? raw.project ?? null;

  return {
    name: project?.name ?? null,
    databaseType: project?.databaseType ?? project?.dbms ?? null,
    projectNote: typeof project?.note === "string" ? project.note.trim() : null,
    tables,
    refs,
    groups,
    notes,
    errors,
    DEFAULT_GROUP,
  };
}

function tableIdOf(db, endpoint) {
  const fieldId = endpoint.fieldIds?.[0];
  if (fieldId != null && db.fields[fieldId]) return db.fields[fieldId].tableId;
  const t = Object.values(db.tables ?? {}).find((x) => x.name === endpoint.tableName);
  return t?.id ?? null;
}

function formatType(type) {
  if (!type) return "";
  const name = type.type_name ?? type.name ?? "";
  return type.args ? `${name}(${type.args})` : name;
}

export { DEFAULT_GROUP };
