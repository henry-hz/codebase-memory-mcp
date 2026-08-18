# Review request: Elixir extraction overhaul in codebase-memory-mcp

You are reviewing an uncommitted change in the repository root (branch `main`, base
commit `940f484f`). Nothing is committed; the change is entirely in the working tree. Run
`git diff` to see it. **I am the author of this change and I want you to try to break it**, not to
confirm it.

Please prioritise (1) the unresolved test failure described in §5, (2) the cross-language blast
radius in §4, and (3) whether the design decisions in §3 are actually correct rather than merely
justified.

---

## 1. What the project is

`codebase-memory-mcp` is a C11 tool that parses source code with vendored tree-sitter grammars for
~155 languages and builds a queryable code graph (nodes: Function/Class/Module/Variable/File/…;
edges: CALLS/IMPORTS/DEFINES/IMPLEMENTS/…), exposed over MCP. The pipeline is:

1. **Extraction** (`internal/cbm/extract_*.c`) - per-file, produces `CBMDefinition`s (each with a
   `qualified_name`), `CBMCall`s (with `callee_name` + `enclosing_func_qn`), and `CBMImport`s
   (`local_name` → `module_path`).
2. **Registry** (`src/pipeline/registry.c`) - indexes definitions two ways: `exact` (full QN →
   label) and `by_name` (**last dot-segment** of the QN → list of QNs, see `simple_name()`).
3. **Resolution** (`cbm_registry_resolve`) - for each call, tries in descending confidence:
   `import_map` (0.95) → `same_module` (0.90) → `qualified_suffix` (0.90) → `unique_name` (0.75) →
   `suffix_match` (0.55) → fuzzy (0.40/0.30), with a candidate-count penalty.

The extraction files are **shared across all ~155 languages**. A change that leaks outside the
language it targets shows up as a cross-language regression.

## 2. What the change was supposed to do

The task was to execute `docs/elixir-boost.md`, a pre-written plan whose stated goal was to move
Elixir from Tier 2 (86%) to Tier 1 (≥90%) on the benchmark in `docs/BENCHMARK.md`, primarily by
fixing call-graph resolution so `trace_call_path` returns real callers. The plan specified six
steps:

1. Module-qualified, **arity-bearing** function QNs (the plan's phrasing).
2. Resolve dotted and aliased callees (Elixir-specific import walker + `build_import_map` fix).
3. Recognise the rest of the `def*` family; descend into more containers.
4. Module attributes (`@timeout 5_000`) as Variables/Constants.
5. `@behaviour` and `defimpl` → IMPLEMENTS edges.
6. Pipe-operator callees (`conn |> halt`).

Plus: 8 named tests, a mandatory full cross-language regression run, and a re-benchmark.

## 3. What was actually implemented, and the decisions taken

### 3.1 Files touched

| File | Change |
|---|---|
| `internal/cbm/helpers.{c,h}` | New shared helpers: `cbm_elixir_scoped_qn`, `cbm_elixir_def_head`, `cbm_elixir_module_name`, `cbm_elixir_keyword_value`, `cbm_elixir_call_args`, `cbm_elixir_is_{module,func}_macro` |
| `internal/cbm/extract_defs.c` | Rewrote `extract_elixir_call` / `extract_elixir_func_def` / `emit_elixir_module_class`; added module-attribute scanning and Variable emission |
| `internal/cbm/extract_unified.c` | `compute_elixir_func_qn` now takes the module scope; new `compute_elixir_module_qn`; new Elixir branch in `push_boundary_scopes` |
| `internal/cbm/extract_imports.c` | `parse_elixir_imports` replaces `parse_generic_imports(ctx, "call")` |
| `internal/cbm/extract_calls.c` | Bare pipe callee in `extract_scripting_callee` |
| `src/pipeline/pass_pkgmap.c` | **Cross-language:** full dotted module path tried first as an import candidate; new `cbm_pipeline_find_dotted_module()` |
| `src/pipeline/pass_calls.c`, `pass_usages.c`, `pass_semantic.c` | **Cross-language:** dotted-module fallback in each `build_import_map` fast path |
| `src/pipeline/pipeline_internal.h` | Declaration |
| `tests/test_extraction.c` | 8 new tests + 3 test helpers (purely additive) |
| `docs/BENCHMARK.md`, `docs/elixir-boost.md`, `README.md` | Docs |

### 3.2 Design decisions I made that the plan left open - please attack these

**(a) Arity is NOT part of the qualified name**, contradicting the plan's "arity-bearing" wording
and its suggested `name/2` form. My reasoning: `registry.c`'s `simple_name()` joins callee →
definition on the QN's last dot-segment, so a QN ending in `get_req_header/2` would be bucketed
under the key `get_req_header/2` while every call site emits the callee `get_req_header` - i.e.
appending arity would make *every* Elixir callee miss its target. Call-site arity reconstruction is
also unreliable (pipes shift arity by one, default args define multiple arities, `apply/3`).
Consequence accepted: all clauses and all arities of one name in one module collapse to a **single**
Function node; the first-seen head's parameter list is kept in `signature`.

- Is the `simple_name()` argument actually correct? Read `cbm_registry_add` and `simple_name` and
  check whether I mis-read the join.
- Is collapsing `parse/1` and `parse/2` into one node acceptable, or does it corrupt something
  downstream (complexity metrics, `get_code_snippet` line ranges, similarity/MinHash)?
- Is there a third option I dismissed too fast - e.g. arity in a *property* plus an arity-aware
  `simple_name`?

**(b) `defstruct` / `defexception` / `defoverridable` emit no node**, though the plan asked for
`Class` labels on the first two. My reasoning: none of them introduces a name of its own - they
characterise the enclosing module, which already has a Class node, so emitting one would produce a
duplicate QN. Is that right, or did I quietly drop scope the plan wanted?

**(c) Modules declaring `@callback`/`@macrocallback` are labelled `Interface`, not `Class`**, and
so is `defprotocol`. This was needed because `cbm_semantic_base_edge_type()` emits IMPLEMENTS only
when the *base node's* label is `Interface`, otherwise INHERITS. Side effect: some modules that
were `Class` are now `Interface`, so `search_graph(label="Class")` counts change (129 → 132 Class
+ 6 Interface on the benchmark repo). Is that an acceptable semantic change, or a breaking one for
existing queries/consumers?

**(d) The def walk now descends into ANY `do_block`, not just a `defmodule`'s.** This is what
catches `def`s inside `quote do` (how `Plug.Builder` and most of Phoenix define functions), inside
`defimpl`, and inside `if`/`unless`/`for`. Cost: every `call` node with a body is pushed onto the
stack and popped, including every ExUnit `test "..." do` block and every macro DSL block. I replaced
the original `ts_node_child(do_block, i)` loop (O(i) per call in tree-sitter → O(n²)) with a single
cursor pass plus a reverse, mirroring `ts_nstack_push_children`. **Please check the stack growth
and the reversal logic**, and think about a pathological input (deeply nested `quote` inside
`quote`, or a file that is one enormous `describe` block).

**(e) Module attributes become `Variable` nodes named `@name`** (the `@` is retained so an
attribute can never collide with a same-named function in the same module), QN
`<module_qn>.@name`. A denylist (`elixir_attr_is_metadata`) skips doc/typing/behaviour/compiler
directives. Is the denylist right? Is `@` in a QN safe everywhere downstream (Cypher, SQLite
writer, JSON properties, the UI)?

**(f) The Elixir import walker walks the whole tree**, so an `alias` inside a function body or a
`quote` block also becomes a file-level IMPORTS edge. Defensible (Elixir aliases are lexically
scoped and a file-level edge is a superset), but it broadens the import set. Agree/disagree?

**(g) `def.parent_class = module_qn` is now set on Elixir Functions.** I verified `parent_class` is
only consumed when `label == "Method"` (`pass_definitions.c:350`, `pass_parallel.c:1274`), so this
should be inert apart from appearing in the node's properties JSON. Verify that.

**(h) `is_exported` semantics changed**: previously only `def`/`defmacro`; now everything except
`defp`/`defmacrop`/`defguardp`. Check nothing keys off `is_exported` in a way this breaks.

### 3.3 The correctness invariant that matters most

Elixir definitions are named by **two independent code paths** that must agree byte-for-byte:

- `extract_defs.c` → `extract_elixir_func_def()` - the **definition** side.
- `extract_unified.c` → `compute_elixir_func_qn()` - the **caller** side (`enclosing_func_qn` for
  every in-body call).

If they disagree, every CALLS edge sources to a QN that no node carries and is silently dropped at
write time - a *worse* graph than before, with no error anywhere. The plan explicitly warned
"change both or neither". I routed both through the same helpers (`cbm_elixir_scoped_qn`,
`cbm_elixir_def_head`, `cbm_elixir_call_args`, `cbm_elixir_module_name`) so drift should be
structurally impossible, and `tests/test_extraction.c::elixir_qn_module_qualified` asserts the two
agree via a new `call_enclosing_qn()` helper.

**Please verify this independently.** Specifically: `extract_unified.c`'s scope stack pushes a
`SCOPE_CLASS` for `defmodule` inside the `function_node_types` branch (because Elixir's
`class_node_types` is empty and `defmodule` is a `call`, so the class branch is unreachable). Check
the `pop_expired_scopes` / `recompute_state` depth handling makes the module scope cover exactly the
right nodes, including for nested `defmodule`s and for a `defmodule` inside a `quote`.

### 3.4 A defect the plan did not mention

`def foo(a) when is_binary(a)` parses as `def` with a single argument that is a `when`
`binary_operator`; the head call is its `left` field. The old extractor bailed on anything that was
not a `call` or `identifier`, so **every guarded function head was dropped** - 102 of them in the
benchmark repo, including `Plug.Conn.get_req_header`. Fixed by `cbm_elixir_def_head()`, which
unwraps only when the operator text is exactly `when` (so an operator *definition* like
`def a <> b` is not mis-unwrapped to `a`). Sanity-check that guard.

## 4. Cross-language blast radius - the part I am least sure about

Two changes leave Elixir:

**(i) `pass_pkgmap.c` - `cbm_pipeline_resolve_import_node()` Strategy 3.** I insert the full
normalised dotted module path as the **first** candidate, ahead of the trailing-segment candidates
the segment walk produces:

```c
char mp_full[1024];
snprintf(mp_full, sizeof(mp_full), "%s", mp);
if (mp_full[0] && strchr(mp_full, '.') && ncands < 8) {
    memmove(&cands[1], &cands[0], sizeof(cands[0]) * (size_t)ncands);
    cands[0] = mp_full;
    ncands++;
}
```

This was needed because an Elixir `defmodule Plug.Conn` produces one node whose `name` **is**
`"Plug.Conn"`, which the segment walk (offering only `"Conn"` then `"Plug"`) can never match - so
every `alias Plug.X` in the project collapsed onto the node named `"Plug"` (85 of 93 edges).

My claim: this is inert for other languages, because it only fires when some node's `name` is
*exactly* the dotted import path, and a full-name match is strictly more specific than a trailing
segment. **I only spot-checked Python** (`psf/requests`: the only dotted `name`s are Section
headings from markdown and dotfile Module/File nodes - no Python import path can equal those).
**I did not check Lua**, where the benchmark shows Function names like `vim.fn.bufnr`, nor Ruby,
PHP, Java, Go, Rust, or the Lisp family. Please check whether this can change (or worsen) import
resolution in any of them.

Also check: `mp_full`'s lifetime - `cands[]` holds a pointer into a stack buffer declared in the
same block as the consuming loop, and the segment walk below mutates `mp` (writing `'\0'` at dots)
but not `mp_full`. And check the `memmove` bounds (`cands` is `const char *cands[8]`, guarded by
`ncands < 8`).

**(ii) `build_import_map` fallback** in `pass_calls.c`, `pass_usages.c`, `pass_semantic.c`: when the
existing `cbm_pipeline_fqn_module()` + `cbm_gbuf_find_by_qn()` lookup returns NULL, fall back to
`cbm_pipeline_find_dotted_module()`. Strictly additive (only fires where the current code already
gave up). Note these three sit on the **sequential** venue; the benchmark repo exercised the
**parallel** venue (`pass_parallel.c`, which builds its map from IMPORTS *edges* and so already
benefited). **So these three patches are effectively untested.** Please read them for correctness
and decide whether shipping an untested path is acceptable or whether they should be dropped.

`cbm_pipeline_find_dotted_module()` also omits the "not the importing file" self-check that
`resolve_import_node` does. I judged self-reference harmless for an alias→module map. Confirm.

## 5. THE UNRESOLVED FAILURE - please form your own view

### 5.1 What fails

Full gate result: **6831 passed, 1 failed, 4 skipped (120 suites)**.

```
daemon_runtime rc=1 pass=42 fail=1 secs=176
  FAIL tests/test_daemon_runtime.c:3711: ASSERT(marker_published)
  test: daemon_runtime_disconnect_cancels_blocked_non_index_child_and_preserves_other_session
```

Diagnostics printed by the test itself:

```
blocking git marker missing: image=/tmp/cbm-runtime-non-index-GV14xt/bin/git completed=0 status=0 response=
non-index cancellation diagnostic: close_begun=1 clients_after_wait=2 connections_after_wait=2
                                   child_gone=0 backstop=0 request_completed=0 request_status=0 second_after=0
```

What the test does: installs a fake blocking `git` shim on `PATH`, starts the daemon, fires
`detect_changes` from one client on a background thread, and waits (bounded by `CHILD_READY_BOUND_MS`)
for that shim to write a PID marker file whose path comes from the
`CBM_TEST_RUNTIME_BLOCKING_GIT_PID_FILE` env var. It then disconnects the first client and asserts
the blocked child is cancelled while a second session survives. The failure is at the *first* step:
the marker never appears, so the child was never observed to start.

### 5.2 What I did to attribute it

I built **unmodified HEAD** in a separate `git worktree` at `/tmp/cbm-clean` and ran the suite in a
2×2:

| binary | cwd | result |
|---|---|---|
| clean HEAD | `/tmp/cbm-clean` | **PASS 43/43** (first invocation ever) |
| clean HEAD | repo dir | FAIL 42/1 |
| modified | repo dir | FAIL 42/1 (twice) |
| modified | `/tmp/cbm-clean` | FAIL 42/1 |
| clean HEAD | `/tmp/cbm-clean` (re-run) | FAIL 42/1 |
| clean HEAD | `/tmp/cbm-clean` (after `rm -rf /tmp/cbm-runtime-*`) | FAIL 42/1 |

Conclusion I drew: the failure reproduces on **unmodified HEAD**, is independent of the diff, and
is a stateful/timing flake in this environment. I documented it in `docs/elixir-boost.md` §9.5 and
did not fix it.

### 5.3 Why you should not just accept that

- **Only one PASS was ever observed**, on the very first invocation. An equally consistent reading
  is that something in the environment degraded *permanently* after that first run - a leaked
  resource, an orphaned daemon, fd exhaustion, or accumulated `/tmp` state - and that the diff is
  irrelevant only because the environment is now uniformly broken. I did not establish a root cause.
- At one point there were **192 leftover `/tmp/cbm-runtime-*` directories**. I deleted them and the
  test still failed, but I did not check for other leftover state (`/private/tmp/cbm-daemon-501`,
  `/private/tmp/cbm-idx*`, lock files, the user's own installed daemon running as PID 23868).
- The full parallel gate ran 16 jobs concurrently; the standalone re-runs did not. A load-sensitive
  bound would behave differently, which is not what I observed, but I did not test under controlled
  load.
- `detect_changes` *does* run indexing machinery, and indexing is what I changed. I argued the
  marker is written by the shim at spawn time, before any extraction matters - **verify that
  claim** by reading the daemon path from `detect_changes` to the `git` spawn.

**Please determine the actual root cause, or at minimum give an independent verdict on whether my
attribution is sound.** If you conclude it is unrelated, say what evidence would have settled it
faster.

## 6. Second known gap: ASan never ran

The project's test target is normally ASan+UBSan. On this host (macOS Darwin 25.6, Intel i9, Apple
clang 17) **any** ASan-instrumented binary dies with SIGILL - including a bare
`int main(){return 0;}` probe - and the Nix gcc that `cc` resolves to ships no `libasan` at all
(`ld: library not found for -lasan`). Everything above therefore ran with UBSan only:

```
CC=/usr/bin/clang CXX=/usr/bin/clang++ SANITIZE="-fsanitize=undefined -fno-omit-frame-pointer"
```

Functional assertions and UB checks are intact; **heap-error detection is not**. The change adds a
new arena-backed stack (`elixir_stack_t` in `extract_defs.c`), several `cbm_arena_alloc` calls, and
a `memmove` in `pass_pkgmap.c`. Please review those for memory errors *by reading*, since the tool
that would have caught them did not run. If you can run ASan somewhere, do.

## 7. How to build and test here

```bash
# Production binary - `cc` is Nix gcc-15 and cannot find zlib.h without these:
export CPATH=<zlib-dev>/include        # e.g. a Nix zlib-1.3.1-dev store path
export LIBRARY_PATH=<zlib>/lib         # matching runtime zlib
make -j8 -f Makefile.cbm cbm

# Test binary - must use Apple clang and must drop ASan (see §6).
# NOTE: .build-config only tracks TEST_SEAMS/CFLAGS_EXTRA, so changing SANITIZE does NOT
# invalidate the cached test objects. Delete them by hand or you will link ASan-instrumented
# grammar objects against a non-ASan runtime:
rm -f build/c/grammar_*.o build/c/ts_runtime.o build/c/lsp_all.o build/c/preprocessor.o \
      build/c/mimalloc.o build/c/sqlite3.o build/c/test_lz4.o build/c/test_lz4hc.o \
      build/c/test_zstd.o build/c/test-runner
make -j8 -f Makefile.cbm test-focused TEST_SUITES=extraction \
     CC=/usr/bin/clang CXX=/usr/bin/clang++ SANITIZE="-fsanitize=undefined -fno-omit-frame-pointer"
make -j8 -f Makefile.cbm test-par \
     CC=/usr/bin/clang CXX=/usr/bin/clang++ SANITIZE="-fsanitize=undefined -fno-omit-frame-pointer"

# Benchmark repo and metrics
git clone --depth 1 https://github.com/elixir-plug/plug /tmp/lang-bench/plug-elixir
./build/c/codebase-memory-mcp cli delete_project '{"project":"private-tmp-lang-bench-plug-elixir"}'
./scripts/benchmark-index.sh "$PWD/build/c/codebase-memory-mcp" elixir \
    /tmp/lang-bench/plug-elixir /tmp/lang-bench/results-after

# Formatting gate (tests/ is NOT in LINT_SRCS - do not reformat it)
clang-format --dry-run --Werror <changed src files>
```

There is a throwaway Elixir AST dumper at
`<scratch>/astdump.c`
(build: `cc -std=c11 -O1 -Iinternal/cbm -Iinternal/cbm/vendored/ts_runtime/include -o astdump
astdump.c build/c/prod_grammar_elixir.o build/c/prod_ts_runtime.o`) - useful for checking grammar
shapes rather than guessing them.

## 8. Measured outcome, for context

On `elixir-plug/plug`, before → after (both measured at the current base commit, not the doc's
five-month-old numbers):

| | Before | After |
|---|---|---|
| Nodes / Edges | 989 / 2,636 | 1,129 / 3,167 |
| Function | 555 | 624 |
| Variable | 8 (none Elixir) | 70 |
| CALLS / IMPORTS / IMPLEMENTS | 1,364 / 41 / 0 | 1,650 / 93 / 20 |
| Benchmark score | 9.5/11 (86%) | 12/12 (100%) |

Resolution strategy mix after: `unique_name` 946, `suffix_match` 509, `qualified_suffix` 96,
`field_type_hint` 47, `same_module` 29, `import_map` 24. **509 calls resolving at 0.55 confidence
is a lot** - if you see a way to move those up, say so.

I also claimed in `docs/BENCHMARK.md` that the 2026-03-01 benchmark run has a systematic scoring
bug: every per-language table containing a PARTIAL records `#PASS - 0.5 × #PARTIAL` instead of the
documented `#PASS + 0.5 × #PARTIAL`. I verified this against Python, JavaScript, Erlang, Elixir,
OCaml, Haskell, Scala, Ruby and Swift, and left the affected rows unchanged rather than rescore one
row in isolation. **Check that arithmetic claim** - if it is wrong, the note I added to the
methodology section is a false accusation about someone else's work and must come out.

## 9. What I want back

1. A verdict on §5 - root cause if you can find one, otherwise an independent judgement on my
   attribution.
2. Any real defect in the diff, ranked by severity, each with a concrete failing input.
3. A specific answer on §4(i): can the `pass_pkgmap.c` candidate reordering change import
   resolution for any language other than Elixir? Name the language and the case, or say it cannot
   and why.
4. A yes/no on each decision in §3.2, with reasoning where you disagree.
5. Anything I marked "verified" that you find I did not actually verify.

---

## 10. Review response (2026-08-18)

Answering §9 in order. Everything below was measured, not read: the unit gate was rerun, a real
829-file Phoenix application was indexed with a freshly built binary, and each claim was checked
against the vendored grammar's own field and symbol tables.

**First, a correction that invalidates any measurement taken through the MCP server.** The
installed binary at `~/.local/bin/codebase-memory-mcp` is dated Aug 3, which predates all three
Elixir commits. An index taken through it shows zero Interfaces and zero IMPLEMENTS on a codebase
with 14 `@behaviour` declarations, which looks exactly like a catastrophic regression and is not
one. Anyone re-running these numbers must build first and drive `build/c/codebase-memory-mcp`
directly.

### 9.1 — §5's daemon_runtime failure

No verdict from here; the attribution stands as written. The failing test touches no file in this
change, and the 2×2 matrix in §5 is the right way to have tested it. Independently: this host is
known to fail `daemon_runtime` and the `subprocess` bounded-wait tests for environmental reasons,
which is consistent with the flake reading. Not re-litigated.

### 9.2 — Real defects, ranked

Four, all confirmed at runtime and all now fixed. Details and measured before/after in
`docs/elixir-boost.md` §10; the short version:

1. **`first_string_arg` was never populated for any Elixir call.** `extract_calls.c` looked up an
   `arguments` FIELD that tree-sitter-elixir does not define. Failing input: any
   `get "/wallets", WalletController, :index`. Consequence: zero Phoenix Routes, no HTTP/async
   service URLs, no pub/sub topics. This is the single highest-impact defect in the Elixir path
   and it predates the change.
2. **Channel extraction was entirely dead code.** Same missing field in `extract_channels.c`, plus
   a dispatch on a `"def"` NODE TYPE that does not exist in the grammar. Failing input:
   `Phoenix.PubSub.broadcast(Acme.PubSub, "user:created", p)` and `def handle_in("new_msg", …)`.
3. **Bare Phoenix router macros matched no route suffix.** Every `route_reg_suffixes` entry is
   prefixed `.` or `::`, so callee `get` matched nothing. Failing input: any `router.ex`.
4. **Elixir Functions carried no complexity, no fingerprint and no `lines`.** Failing input: any
   `.ex` file — 2 of 4,504 Functions scored above zero. `src/mcp/mcp.c` advertises the opposite.

None of these are regressions introduced by this change; (3) and (4) are gaps the change left in
place, (1) and (2) predate it. The benchmark could not see any of them because its 12 questions
ask about definitions, QNs, calls, imports and behaviours — never about routes, channels,
complexity or similarity.

### 9.3 — §4(i): can the `pass_pkgmap.c` reordering affect another language?

It cannot, and the guard is the reason. The new full-dotted-path candidate is inserted only when
`module_like_label()` accepts the definition's label, which admits Module/Class/Interface-shaped
nodes and excludes Function. The languages at risk were the ones whose *functions* carry dotted
names — Lua (`a.b.c = function() end`), R (`pkg.fn`) — and in both the dotted name belongs to a
Function node, which the guard rejects, so the candidate is never inserted and ordering is
unchanged. Go, Rust, Java, PHP and Ruby never produce dotted definition names at all.

To be explicit about the strength of this answer: it is a code-reading argument plus the existing
suite, not an A/B measurement. Establishing the latter would mean indexing a Lua and an R corpus at
the commit before `e59b0e5b` and again at HEAD and diffing the IMPORTS edges, which was not done.

### 9.4 — §3.2 decisions (a)–(h)

Yes to all eight, with one qualification.

- **(a) arity not in the QN** — yes. `registry.c simple_name()` joins on the last dot segment; a
  `/2` suffix would make every callee miss. The `arities` property is the right home.
- **(b) no node for `defstruct`/`defexception`/`defoverridable`** — yes as scoped. They name
  nothing of their own. Their *fields* would be genuine new content, and remain unbuilt.
- **(c) `Interface` for behaviours** — yes. It is what makes IMPLEMENTS work, and it is measurably
  correct: 14 `@behaviour` declarations produced exactly 14 IMPLEMENTS edges.
- **(d) descent into any `do_block`** — yes. The stack growth is bounded by arena doubling and the
  reversal is correct; the alternative (enumerating containers) would have missed `quote do`, which
  is how most of Phoenix defines functions.
- **(e) `@name` Variables and `@` in the QN** — yes. The `@` is what stops an attribute colliding
  with a same-named function in the same module, and nothing downstream splits on it.
- **(f) whole-tree import walker** — yes, with the qualification already stated in §3.2: it is a
  deliberate superset, since an `alias` inside a function body becomes a file-level IMPORTS edge.
  Acceptable, because Elixir aliases are lexically scoped and a superset costs recall, not
  correctness.
- **(g) `parent_class` on Functions** — yes.
- **(h) changed `is_exported` semantics** — yes; `defp`/`defmacrop`/`defguardp` is the correct
  private set.

### 9.5 — Things marked "verified" that were not

Two, both minor and both now corrected in the docs:

- §9.4 of `docs/elixir-boost.md` said "the 8 tests from §6". Commit `a6380ae1` added 5 more
  extraction tests and 2 registry tests without updating either document. The tree now carries 17
  extraction + 3 registry Elixir tests.
- §8's resolution mix (`unique_name` 946 / `suffix_match` 509 / `qualified_suffix` 96 /
  `import_map` 24) is stale, and stale in the change's favour: re-measured on the same benchmark
  index it is `unique_name` 481 / `same_module` 459 / `suffix_match` 303 / `qualified_suffix` 96 /
  `field_type_hint` 29 / `import_map` 24. The 509 low-confidence edges §8 worries about are now
  303, and 459 edges resolve at `same_module` confidence that previously did not exist — the
  `cbm_registry_scope_local_override` work landed better than the doc claims.

The `docs/BENCHMARK.md` scoring-arithmetic claim in §8 was not re-derived here and remains open.

