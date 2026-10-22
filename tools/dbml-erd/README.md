# dbml-erd

A local, ungated DBML → ERD renderer.

## Install

```bash
cd tools/dbml-erd
npm install
```

## Use

From the **repo root**:

```bash
npm run erd:install  # once
npm run erd          # the editor: opens http://127.0.0.1:4777, ctrl-c to stop
npm run erd:build    # one-shot docs/schema.erd.html, no server
```

`npm run erd` serves the diagram, reloads it whenever you save
`docs/schema.dbml`, and writes every drag to **`docs/schema.erd.layout.json`**.
That file is git-ignored: each machine keeps its own arrangement. The server only listens
on `127.0.0.1` and only accepts layout writes from its own page.

Opening `docs/schema.erd.html` directly (from `erd:build`) shows the saved
layout read-only; to rearrange, use `npm run erd`.

Or directly, if you want the flags:

```bash
cd tools/dbml-erd

# interactive page next to the input file
node bin/dbml-erd.mjs ../../docs/schema.dbml

# re-render while you edit
node bin/dbml-erd.mjs ../../docs/schema.dbml --watch

# standalone image
node bin/dbml-erd.mjs ../../docs/schema.dbml --svg

# dump the parsed model (debugging)
node bin/dbml-erd.mjs ../../docs/schema.dbml --json
```

Output defaults to `<input>.erd.html` / `.erd.svg`. `-o <file>` overrides it.
`--open` launches a browser; the root scripts add it for you.

## Arranging the diagram

The auto layout is a starting point. Rearrange it by hand:

| drag… | moves |
|---|---|
| a **table** | that table; its ref lines follow and its group box grows/shrinks to keep wrapping it |
| a **group** (its label chip or empty area inside the box) | all its tables and its note — the box comes with them |
| a **note** | that note |
| **empty canvas** | pans the view |

Positions are saved to `docs/schema.erd.layout.json` (keyed by table/note
name; group boxes are always re-fitted around their tables), so they survive
re-renders and browser restarts (not other machines: the file is git-ignored). **Reset layout** returns to the
auto layout and empties the file. Clicking a table in the sidebar zooms the view
to it.

A renamed table loses its saved position (it's a new name); new tables appear
at their auto-layout spot.

## What you get

- **Table groups** as tinted, labelled containers (colour from `TableGroup [color: …]`).
- **Header colours** from each column of `Table X [headercolor: #…]`.
- **Notes** — both table notes (in the detail panel) and standalone `Note x { … }`
  blocks, floated just above the group whose name they match.
- **25 refs** drawn as bezier curves with crow's-foot / one markers.
- **Live colour pickers** in the sidebar: change a group and its box, chip and
  refs update instantly; change a table and only its header does.
- Pan / zoom, hover to trace a table's refs, click to pin, search, notes/refs
  toggles, `Copy colours` (emits `TableGroup … [color: …]` / `Table … [headercolor: …]`
  lines to paste back into the DBML), and `Export SVG`.

## How it works

```
docs/schema.dbml
   │
   ├─ src/model.mjs   @dbml/parse Compiler  ->  @dbml/core Parser.parseJSONToDatabase().normalize()
   │                  (same pipeline the VS Code extension uses — the one that
   │                   actually exposes tableGroups / notes / headerColor)
   │
   ├─ src/layout.mjs  dagre, two passes:
   │                    1. inside each group (TB) — stack sources above sinks
   │                    2. across groups (LR)     — pack group boxes into columns
   │                  then size each group box around its tables and route refs
   │
   ├─ src/svg.mjs     groups -> refs -> notes -> tables, all as plain SVG
   └─ src/page.mjs    CSS + vanilla-JS shell (pan/zoom, pickers, export)
```

No framework, no build step, no runtime CDN. The generated page is a single
self-contained file you can open with `file://`.

## Dependencies

All open source — that is the whole point of the exercise:

| package | version | licence |
|---|---|---|
| `@dbml/core` | ^10.3.1 | Apache-2.0 |
| `@dbml/parse` | ^10.3.1 | Apache-2.0 |
| `@dagrejs/dagre` | ^3.1.1 | MIT |

Note that `dbdiagram-vscode` itself is © Holistics Software Pte Ltd and
all-rights-reserved; this tool shares no code with it, only the on-disk DBML
format, which is an open specification.

## Input expectations

The renderer uses the *new* `@dbml/parse` compiler, so it handles the full
current DBML subset including multi-line `Note: '''…'''`, `TableGroup`,
`headercolor`, indexes and expression defaults. The legacy
`Parser.parse(text, 'dbml')` shortcut does **not** — it rejects top-level
`Note` blocks. That is why the pipeline above is longer than it looks like it
needs to be.
