# Elixir-enhanced build — install guide

This branch (`feat/elixir-enhancements`) carries Elixir support well beyond
upstream. These are the install instructions.

## What you get

| Capability | Upstream | This branch |
|---|---|---|
| Qualified names | `proj.lib.conn.get_req_header` | `proj.lib.conn.Plug.Conn.get_req_header` (module-qualified) |
| `def foo(x) when ...` | dropped entirely | extracted |
| `def*` family | `def`, `defp`, `defmacro` | + `defmacrop`, `defguard(p)`, `defdelegate`, `defprotocol`, `defimpl` |
| Multi-clause functions | one node per clause | one node, span covers all clauses, `arities` property |
| `alias` / `import` / `require` / `use` | root-level only (recorded the `defmodule` itself) | real edges, nested in modules, `Foo.{Bar, Baz}`, `as:` |
| `@module_attributes` | invisible | `Variable` nodes, reads tracked as usages |
| `@behaviour` / `@callback` | invisible | `Interface` nodes + `IMPLEMENTS` edges |
| `first_string_arg` on calls | always NULL | populated |
| Phoenix routes | none | `Route` nodes + `HANDLES` edges |
| Phoenix PubSub / Channels | none (dead code) | `Channel` nodes, `EMITS` / `LISTENS_ON` |
| Complexity / fingerprints | always 0 / absent | real values, `SIMILAR_TO` works |
| `.heex` / `.eex` templates | not indexed | indexed, function components linked |

Measured on an 829-file Phoenix application: 180 Routes, 153 HANDLES, 14
IMPLEMENTS, 837 attribute Variables, 2,522 functions with a nonzero complexity,
414 SIMILAR_TO edges, 7 `.heex` files.

## Prerequisites

A C compiler, `make`, `zlib`, and Git. Node.js 22+ only if you want the graph UI.

- macOS: `xcode-select --install`
- Debian/Ubuntu: `sudo apt install build-essential zlib1g-dev`
- Fedora: `sudo dnf install gcc zlib-devel`

## Install

```bash
git clone https://github.com/henry-hz/codebase-memory-mcp.git
cd codebase-memory-mcp
git checkout feat/elixir-enhancements

make -f Makefile.cbm install-local ARGS=--dry-run   # inspect first
make -f Makefile.cbm install-local
```

`install-local` builds, backs up whatever is currently installed with a
timestamp, then installs to `~/.local/bin/codebase-memory-mcp` and registers the
MCP server with the editors it finds (Claude Code, VS Code, Codex, OpenCode).

Options:

```bash
make -f Makefile.cbm install-local ARGS="--dir ~/bin"   # different location
make -f Makefile.cbm install-local ARGS=--no-build      # install an existing build
scripts/install-local.sh --help
```

### Restart your editor afterwards

Replacing the file does not affect processes already running — they hold the old
build until they exit. `install-local` prints how many are live. **Restart your
editor / MCP client**, or the tools keep answering from the previous binary.

This is worth taking seriously: during development, an index taken through a
stale installed binary reported zero Interfaces and zero IMPLEMENTS on a codebase
with 14 `@behaviour` declarations. It looks exactly like a catastrophic
regression and is nothing of the kind.

## Verify

Index a real Elixir project, then check the Elixir-specific surface:

```bash
CBM=~/.local/bin/codebase-memory-mcp

$CBM cli index_repository --repo-path /path/to/your/app --name myapp --mode full

$CBM cli query_graph --project myapp --query \
  'MATCH (f:Function) WHERE f.complexity > 0 RETURN count(f) AS with_complexity'
$CBM cli query_graph --project myapp --query \
  'MATCH (n:Route) RETURN count(n) AS routes'
$CBM cli query_graph --project myapp --query \
  'MATCH (impl)-[:IMPLEMENTS]->(b:Interface) RETURN b.name AS behaviour, impl.name AS impl LIMIT 5'
$CBM cli query_graph --project myapp --query \
  'MATCH (v:Variable) WHERE v.name STARTS WITH "@" RETURN count(v) AS module_attrs'
```

On a Phoenix app all four should be non-zero. If `with_complexity` is 0 or
`routes` is 0, you are still running the old binary — see the restart note.

`get_architecture` is the quickest overall sanity check:

```bash
$CBM cli get_architecture --project myapp --aspects structure
```

## Using it

Once installed, drive it conversationally through your editor — "who calls
`get_role!`", "what implements `Bank.Connectors.KYC`", "where is the KYC
verification logic". Or by CLI:

```bash
$CBM cli search_graph --project myapp --query "verify kyc subject"
$CBM cli trace_path  --project myapp --function-name tokenize --mode calls
$CBM cli get_code_snippet --project myapp --qualified-name <qn from search>
```

Queries that earn their keep on a large Elixir codebase:

```cypher
-- worst LiveView event dispatchers
MATCH (f:Function) WHERE f.complexity > 30
RETURN f.name, f.file_path, f.complexity, f.cognitive

-- god modules, split candidates
MATCH (m)-[:DEFINES]->(f:Function) WHERE m.file_path ENDS WITH ".ex"
RETURN m.name, count(f) AS fns ORDER BY fns DESC

-- every adapter of a behaviour, before changing a callback
MATCH (impl)-[:IMPLEMENTS]->(b:Interface) RETURN b.name, impl.name

-- endpoint to controller map
MATCH (h)-[:HANDLES]->(r:Route) RETURN r.method, r.name, h.name

-- copy-paste across LiveViews
MATCH (a:Function)-[r:SIMILAR_TO]->(b:Function)
RETURN a.name, b.name, r.jaccard ORDER BY r.jaccard DESC
```

## Re-index after changing extraction

The graph is a snapshot. After pulling or editing extraction code:

```bash
$CBM cli delete_project --project myapp
$CBM cli index_repository --repo-path /path/to/your/app --name myapp --mode full
```

Modes: `full` (everything, plus similarity and semantic edges), `moderate`
(filtered files, keeps similarity), `fast` (filtered, no similarity).

## Rollback

`install-local` leaves a timestamped copy next to the binary:

```bash
ls ~/.local/bin/codebase-memory-mcp.backup-*
cp -p ~/.local/bin/codebase-memory-mcp.backup-<timestamp> ~/.local/bin/codebase-memory-mcp
```

## Building from source directly

```bash
scripts/build.sh                      # release build -> build/c/codebase-memory-mcp
make -f Makefile.cbm cbm              # plain build
```

### If `cc` cannot find `zlib.h`

On a machine where `cc` resolves to a Nix-provided GCC, the system zlib headers
are not on its search path:

```bash
export CPATH=<zlib-dev>/include
export LIBRARY_PATH=<zlib>/lib
make -f Makefile.cbm cbm
```

Do not pass `CC=/usr/bin/clang` to the `cbm` target on such a host — the cached
`prod_*.o` objects are GCC/libstdc++ and will fail to link against libc++. Run
`make -f Makefile.cbm clean-c` first if you need to switch compilers.

## Running the tests

```bash
make -f Makefile.cbm test-focused TEST_SUITES="extraction registry"
make -f Makefile.cbm test-par                   # full gate
```

Elixir coverage lives in `tests/test_extraction.c` (18 `TEST(elixir_*)` cases plus
`heex_component_calls`) and `tests/test_registry.c` (3 cases).

On a host where AddressSanitizer does not work — Apple Silicon/Intel macOS with a
Nix toolchain is one — the default sanitized test build dies with `SIGILL`. Use:

```bash
make -f Makefile.cbm test-par \
  CC=/usr/bin/clang CXX=/usr/bin/clang++ \
  SANITIZE="-fsanitize=undefined -fno-omit-frame-pointer"
```

`.build-config` does not track `SANITIZE`, so delete the cached objects by hand
when switching:

```bash
rm -f build/c/grammar_*.o build/c/ts_runtime.o build/c/lsp_all.o \
      build/c/preprocessor.o build/c/mimalloc.o build/c/sqlite3.o \
      build/c/test_*.o build/c/test-runner
```

## Known limitations

- **`Application.get_env` reads are not detected.** Config-surface extraction
  finds nothing for Elixir, so `CONFIGURES` edges are missing. Unfixed.
- **Scattered clauses inflate spans.** All clauses of a name merge into one node
  spanning first-clause-start to last-clause-end. When clauses sit far apart —
  one real case had them at lines 887 and 1750 — `get_code_snippet` returns the
  whole range. Affects ~3.6% of functions in a large app (150 of 4,118), 25 of
  them spanning more than 200 lines.
- **Dotted-module import resolution is untested.** The
  `cbm_pipeline_find_dotted_module` / `module_like_label` path in
  `pass_pkgmap.c` has no test coverage and touches candidate ordering shared with
  Lua and R. Treat it as unproven if you modify imports.
- **`.heex` extraction covers component references only.** Interpolated
  expressions (`{...}`, `<%= %>`), `:let`/slot bindings and `phx-*` event names
  are not extracted.
- **No Elixir LSP resolver**, so call resolution is the generic registry chain.
  Upstream has an in-flight workstream for this — see
  [DeusData#1239](https://github.com/DeusData/codebase-memory-mcp/issues/1239).

## Upstream status

Four fixes from this branch are proposed upstream individually, with context in
[DeusData#1729](https://github.com/DeusData/codebase-memory-mcp/issues/1729):

| PR | Fix |
|---|---|
| [#1721](https://github.com/DeusData/codebase-memory-mcp/pull/1721) | `first_string_arg` never populated |
| [#1730](https://github.com/DeusData/codebase-memory-mcp/pull/1730) | channel extraction unreachable |
| [#1731](https://github.com/DeusData/codebase-memory-mcp/pull/1731) | no complexity, fingerprint or line count |
| queued | Phoenix bare router macros (depends on #1721) |

The broader grammar-layer rewrite on this branch is deliberately **not** proposed
upstream: it overlaps an active workstream there. See #1729 for the details.
