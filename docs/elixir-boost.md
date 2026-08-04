# Elixir Extraction Boost — Execution Plan

**Goal:** move Elixir from Tier 2 (86%, `docs/BENCHMARK.md:64`) to Tier 1 (≥90%), primarily by
fixing call-graph resolution so `trace_call_path` returns real callers.

**Status: EXECUTED (2026-08-04).** Elixir now scores **12/12 (100%)** on `elixir-plug/plug` —
Tier 1. All six steps landed. Results, and the four places where the diagnosis below turned out to
be wrong, are in [§9 Execution report](#9-execution-report). Read §9 before trusting §1–§5: they
are preserved as written so the reasoning can be audited, but the baseline they quote was already
stale when this was executed.

---

## 1. Baseline

From `docs/BENCHMARK.md:510-530` (Elixir on `elixir-plug/plug`):

| Metric | Elixir / plug | Erlang / cowboy (comparable BEAM lang) |
|---|---|---|
| Nodes | 870 | 3,270 |
| Edges | 865 | 9,815 |
| **Edges per node** | **1.0** | **3.0** |
| Score | 9.5/11 (86%) | 9.5/11 (86%) |

Failing/weak questions:

- **Q8 Inbound Trace — PARTIAL**, "0 callers (entry point function)".
- **Q10 Properties — PASS but hollow**, only 6 Variables in the entire Plug codebase.
- **Q11 Inheritance — N/A**, excluded from the denominator.

An edge-per-node ratio of 1.0 means the graph is essentially nodes plus containment, with almost no
`CALLS` edges. That single number is the headline problem; Q8 is its symptom.

### Bookkeeping discrepancy — resolve before trusting the baseline

`docs/BENCHMARK.md:517-528` lists 10 PASS + 1 PARTIAL + 1 N/A. That arithmetic gives **10.5/11
(95%)**, but line 530 and the summary row at line 64 both say **9.5/11 (86%)**. One of the two is
wrong. Re-run the Elixir question set (or find the run log) and correct whichever is stale before
using 86% as the "before" number — otherwise the improvement claimed at the end will be off by a
full point.

---

## 2. Reproduce the baseline first (Phase 0)

Do this before changing any code. Every later step is judged against these numbers.

```bash
# 1. Build the CLI
make -f Makefile.cbm cbm            # produces $(BUILD_DIR)/codebase-memory-mcp

# 2. Get the benchmark repo. NOTE: scripts/clone-bench-repos.sh:56 clones
#    plausible/analytics for elixir, but BENCHMARK.md scored elixir-plug/plug.
#    Use plug to compare against the documented baseline; consider fixing the
#    script (or the doc) so the two agree.
git clone --depth 1 https://github.com/elixir-plug/plug /tmp/lang-bench/plug-elixir

# 3. Index and capture metrics
scripts/benchmark-index.sh <build_dir>/codebase-memory-mcp elixir \
    /tmp/lang-bench/plug-elixir /tmp/lang-bench/results-before

# Or drive the CLI directly, same call shape benchmark-index.sh uses:
<build_dir>/codebase-memory-mcp cli index_repository \
    '{"repo_path":"/tmp/lang-bench/plug-elixir","mode":"full"}'
```

**Record:** node count, edge count, edges/node, Function count, Class count, Variable count, and
`CALLS` edge count. Re-measure after every step. Edges/node is the primary signal.

---

## 3. Verify the hypotheses before coding

Three findings below are read from source and are certain. Two are strong inferences that must be
confirmed against a real parse first, because acting on a wrong one wastes a whole step.

| # | Claim | Confidence | How to confirm |
|---|---|---|---|
| A | Function QNs carry no module and no arity | **Certain** (`extract_defs.c:4676`) | Index plug, dump Function QNs, look for `Plug.Conn.get_req_header` — it will not exist |
| B | Only `def`/`defp`/`defmacro`/`defmodule` are recognized | **Certain** (`extract_defs.c:4738`) | grep the macro list |
| C | Module attributes are never Variables | **Certain** (`lang_specs.c:513`) | 6 Variables across all of Plug |
| D | **Elixir imports are almost entirely missed** — `parse_generic_imports` (`extract_imports.c:943-960`) walks only *direct children of the root node*, and in Elixir every `alias`/`import`/`use`/`require` lives inside a `defmodule … do` block, never at the root | **Inferred — verify** | Index a file with `alias Foo.Bar` inside a defmodule; check whether an `IMPORTS` edge exists |
| E | `build_import_map` (`pass_calls.c:118-143`) cannot resolve Elixir aliases even when imports exist, because it maps `imp->module_path` through `cbm_pipeline_fqn_module()`, which expects a *file path* — Elixir gives it a dotted module name (`Plug.Conn`) whose file is `lib/plug/conn.ex` | **Inferred — verify** | Instrument or log `build_import_map` count for an `.ex` file |

If D is true it is a bigger lever than it looks: with no imports, the `import_map` resolution
strategy (confidence 0.95, `registry.c:58`) never fires for Elixir, leaving only the weak
`unique_name` / `suffix_match` strategies (0.75 / 0.55, `registry.c:63-65`) — which get penalized
further by candidate count. Combined with the duplicate-QN problem from A, that explains a
near-empty call graph.

---

## 4. How resolution actually works (needed to judge each step)

Reading order for anyone unfamiliar with the pipeline:

1. **Extraction** (`internal/cbm/extract_defs.c`, `extract_calls.c`, `extract_imports.c`) produces
   defs (with `qualified_name`), calls (with `callee_name` + `enclosing_func_qn`), and imports
   (`local_name` → `module_path`).
2. **Registry** (`src/pipeline/registry.c`) indexes defs two ways: `exact` (full QN → label) and
   `by_name` (simple name → list of QNs). `simple_name()` at `registry.c:96-109` takes the segment
   after the last `.`, so a dotted callee like `Plug.Conn.get_req_header` *does* reach the by-name
   index as `get_req_header`.
3. **Call resolution** (`pass_calls.c:512`, `cbm_registry_resolve`) tries, in descending confidence:
   `import_map` (0.95) → `same_module` (0.90) → `unique_name` (0.75) → `suffix_match` (0.55) →
   fuzzy (0.40/0.30), with a candidate-count penalty (`registry.c:70`).

**Consequence:** the by-name index is not the bottleneck — the *candidate set* is. Every clause of
a multi-clause Elixir function currently produces a separate node with an **identical** QN, and
every same-named function in every other module collides in the same by-name bucket. `unique_name`
can never fire, `suffix_match` gets penalized, and the call is dropped or resolved wrongly. Fixing
the QN shape (Step 1) is what makes every other strategy work.

---

## 5. The steps

Ordered by leverage. Steps 1 and 2 are the ones that move the tier; 3–6 harden the rest.

Every file touched here is **shared across ~155 languages**. Gate every change on
`ctx->language == CBM_LANG_ELIXIR` (or on the Elixir-only helper it lives in). A change that leaks
into another language will show up as a regression in `tests/test_extraction.c` and
`tests/test_lang_contract.c`.

---

### Step 1 — Module-qualified, arity-bearing function QNs

**Why this is first:** it is the direct cause of Q8 returning 0 callers and of the 1.0 edge ratio.
Nothing else in the list matters as much, and Step 2 depends on it.

**Current behaviour** — `internal/cbm/extract_defs.c:4676`:

```c
def.qualified_name = cbm_fqn_compute(a, ctx->project, ctx->rel_path, name);
```

`name` is the bare function name. So `Plug.Conn.get_req_header/2` becomes
`proj.lib.plug.conn.get_req_header` — no module, no arity. Two consequences:

1. Multi-clause definitions (idiomatic Elixir: `def call(conn, %{a: 1})`, `def call(conn, _)`)
   produce N distinct nodes sharing one QN.
2. Different-arity functions of the same name (`parse/1`, `parse/2`) merge.

**Change:**

- In `extract_elixir_call()` (`extract_defs.c:4716-4754`), thread the enclosing `defmodule` name
  through the iterative stack walk. The walk is already a `TSNodeStack`; extend the pushed item to
  carry the module name (or push a small struct) so nested modules produce `Outer.Inner`.
- Build the QN as `cbm_fqn_compute(a, project, rel_path, "<Module>.<name>")`, mirroring what
  `compute_class_qn()` (`extract_defs.c:6473-6503`) does for class-scoped languages and what
  `cbm_enclosing_func_qn()` (`helpers.c:1085-1104`) does with its class chain.
- Append arity. Count the parameters of the function-head `call` node's argument list in
  `extract_elixir_func_def()` (`extract_defs.c:4657-4668`). Suggested form: `name/2` appended to the
  QN only — keep `def.name` as the bare name so `search_graph(name_pattern=…)` (Q4) still matches
  naturally.
- **Decide and document one arity policy.** Default arity (`def foo(a, b \\ nil)`) defines two
  arities in real Elixir. Handling that fully is out of scope; collapsing to the maximum arity is
  acceptable if written down. Do not silently pick one.

**Must change in lockstep** — `internal/cbm/extract_unified.c:166-197`,
`compute_elixir_func_qn()`. This computes the *caller* side QN (`enclosing_func_qn`) for calls found
inside a function body, and its comment at line 164-165 explicitly says it mirrors
`extract_elixir_func_def()`. If the two drift, every in-body call sources to the file node instead
of its function node and `CALLS` edges lose their origin — a worse graph than today. **Change both
or neither.** Consider extracting one shared helper so drift is impossible.

**Verify:** index plug; confirm Function QNs read `…conn.Plug.Conn.get_req_header/2`; confirm
`trace_call_path(inbound)` on a widely-used function returns callers; expect edges/node to rise
sharply.

---

### Step 2 — Resolve dotted and aliased callees

**Why:** Step 1 creates correct targets; this step makes callers find them.

**Current behaviour** — `internal/cbm/extract_calls.c:435-442` returns the raw text of the `dot`
node, e.g. `Plug.Conn.get_req_header`. After Step 1 the target QN ends in
`…lib.plug.conn.Plug.Conn.get_req_header/2`. The registry's `simple_name()` reduces the callee to
`get_req_header`, which reaches the right by-name bucket but with no module information to
disambiguate among candidates.

**Change:**

- Make the Elixir alias/import map real. This depends on hypothesis **D** and **E** from §3:
  - If **D** holds, replace `parse_generic_imports(ctx, "call")` at `extract_imports.c:2792-2794`
    with an Elixir-specific walker that descends into `defmodule` do-blocks and recognizes `alias`,
    `import`, `require`, and `use`. Handle the multi-alias sugar `alias Foo.{Bar, Baz}`, which is
    common and expands to two aliases.
  - Emit `local_name` = the alias (`Conn`, or the `:as` target), `module_path` = the dotted module.
  - If **E** holds, `build_import_map` (`pass_calls.c:118-143`) needs an Elixir path that looks the
    target up by **module QN suffix** rather than by treating `module_path` as a file path. The
    defmodule Class node QN already ends in the dotted module name
    (`proj.lib.plug.conn.Plug.Conn`), so a suffix lookup against the registry is the natural join.
- With the alias map populated, `import_map` (confidence 0.95) fires and the ambiguity collapses.

**Verify:** a call to `Conn.get_req_header(conn, "x")` in a file that does `alias Plug.Conn` should
produce a `CALLS` edge whose props show `"strategy":"import_map"` (see the props built at
`pass_calls.c:429-433`).

---

### Step 3 — Recognize the rest of the `def*` family, and descend into more containers

**Why:** raw coverage. Every missed macro is missing nodes; every missed container is a whole
subtree of missing nodes. Affects Q2/Q3 depth and, indirectly, edge count.

**Current** — `extract_defs.c:4738-4741` matches only `def`, `defp`, `defmacro`, and (line 4741)
`defmodule`.

**Add:** `defmacrop`, `defguard`, `defguardp`, `defdelegate`, `defstruct`, `defexception`,
`defimpl`, `defprotocol`, `defoverridable`. Consider ExUnit's `test` / `describe` / `setup` — they
define real callable units and `pass_tests.c` may benefit, but they are also the highest-noise
addition; make it a deliberate call, not an accident.

Suggested labels: `defprotocol`/`defimpl` → `Class` (they are the protocol/impl containers);
`defstruct`/`defexception` → `Class`; the `defguard`/`defdelegate`/`defmacro*` family → `Function`.

**Current descent** — `extract_defs.c:4744-4750` pushes only *direct* `call` children of a
`defmodule`'s `do_block`. Anything one level deeper is invisible:

- `def`s inside `defimpl … do` (protocol implementations)
- `def`s inside `quote do` (metaprogramming — this is how `Plug.Builder` and most of Phoenix define
  functions; missing it is why a framework repo under-reports badly)
- `def`s inside `if`/`unless`/`for` blocks
- nested `defmodule`s not directly under the parent's do-block

**Change:** generalize the descent to push `call` children of any nested `do_block`, not just the
defmodule's immediate one, while keeping the iterative stack (the existing comment at
`extract_defs.c:4714-4715` notes recursion was deliberately avoided — preserve that; deep
metaprogramming nests, and `tests/test_stack_overflow.c` exists for a reason).

**Verify:** node count on plug rises; `search_graph(label="Class")` shows protocol impls.

---

### Step 4 — Module attributes as Variables/Constants

**Why:** Q10 currently passes on 6 Variables across an entire framework. It is technically a PASS
but will not survive a stricter grader, and module attributes are Elixir's constants — the graph is
genuinely missing them.

**Current** — `internal/cbm/lang_specs.c:513`:

```c
static const char *elixir_var_types[] = {"binary_operator", NULL};
```

used for both the `variable_node_types` and `assignment_node_types` slots (`lang_specs.c:1753`;
field order is in `internal/cbm/lang_specs.h:20-42`). Module attributes (`@timeout 5_000`,
`@behaviour Plug`) parse as `unary_operator` and are never scanned.

**Change:** add `unary_operator` to the Elixir variable types, then filter in the extractor to only
accept `@`-prefixed unary operators that have a value (skip `@moduledoc`, `@doc`, `@spec`, `@type`,
`@behaviour` — those are documentation/typing/behaviour markers, and `@behaviour` is claimed by
Step 5). Emit as `Constant` if the label vocabulary supports it, otherwise `Variable`.

**Watch:** `unary_operator` is a broad node type; without the `@` filter this will flood the graph
with junk nodes and *hurt* precision. Verify the Variable count lands in the hundreds, not
thousands.

---

### Step 5 — `@behaviour` and `defimpl` → IMPLEMENTS edges

**Why:** Q11 is currently N/A, i.e. excluded from the denominator. Elixir genuinely has an
interface mechanism; modeling it converts a non-answer into a scoreable PASS.

**Note the scoring arithmetic:** turning Q11 from N/A into PASS raises both numerator and
denominator. At the corrected baseline it is neutral-to-positive, but it only helps the percentage
if Q8 (Step 1) also lands. Do Step 1 first.

**Change:** the plumbing already exists. `CBMDefinition.base_classes` (`internal/cbm/cbm.h:195`) is
consumed by `pass_semantic.c:446-448`, which resolves each entry and emits `IMPLEMENTS` or
`INHERITS` (`pass_semantic.c:591-592`). So:

- In `emit_elixir_module_class()` (`extract_defs.c:4686-4712`), scan the module's `do_block` for
  `@behaviour X` attributes and populate `def.base_classes` with each `X`.
- For `defimpl Protocol, for: Type`, emit the impl as a Class with `base_classes = {Protocol}`.
- Optionally treat `use SomeModule` the same way — but `use` is macro injection, not an interface
  contract, so it is arguably `INHERITS`-ish at best. Recommend leaving `use` out of `base_classes`
  and letting it be an import (Step 2) instead; document the choice.

**Verify:** `query_graph` for `IMPLEMENTS` on plug returns the `Plug` behaviour implementors.

---

### Step 6 — Pipe-operator callees

**Why:** smallest of the six, but pipes are everywhere in Elixir and each miss is a lost edge.

**Current:** `elixir_call_types` (`lang_specs.c:510`) includes `binary_operator`, but
`extract_scripting_callee()` (`extract_calls.c:435-442`) returns `NULL` for any node kind other than
`call`. So `binary_operator` nodes are visited and discarded.

`conn |> put_resp_header("a", "b")` is fine — the RHS is itself a `call` node and gets picked up
independently. The miss is the **parenthesis-less** form: `conn |> halt` and `conn |> IO.inspect`,
where the RHS is a bare `identifier` or `dot`.

**Change:** in `extract_scripting_callee`, for `CBM_LANG_ELIXIR` with `nk == "binary_operator"`,
check that the operator is `|>` and, if the right operand is an `identifier` or `dot`, return its
text as the callee.

**Verify:** a fixture with `conn |> halt` produces a `CALLS` edge to `halt`.

---

## 6. Tests

Current Elixir coverage is one function test — `tests/test_extraction.c:947-958` — plus one grammar
fixture (`tests/test_grammar_regression.c:148`) and one call-contract row
(`tests/test_lang_contract.c:656-659`). That is far too thin to protect six behavioural changes.

Add to `tests/test_extraction.c` (follow the existing `TEST(elixir_function)` shape: build source
inline, call `extract(...)`, assert with `has_def`, `cbm_free_result`, `PASS()`; register the new
test in the `RUN_TEST(...)` block near line 5143):

| Test | Guards |
|---|---|
| `elixir_qn_module_qualified` | Step 1 — QN contains module and arity |
| `elixir_multi_clause_single_node` | Step 1 — two clauses of `def call/2` do not collide badly |
| `elixir_alias_resolves_call` | Step 2 — `alias Plug.Conn` + `Conn.foo()` yields an import + call |
| `elixir_defimpl_defprotocol` | Steps 3 & 5 |
| `elixir_def_inside_quote` | Step 3 — the metaprogramming case |
| `elixir_module_attribute_variable` | Step 4 — `@timeout 5_000` becomes a node, `@moduledoc` does not |
| `elixir_behaviour_implements` | Step 5 |
| `elixir_pipe_bare_callee` | Step 6 — `conn \|> halt` |

Run:

```bash
make -f Makefile.cbm test-focused TEST_SUITES=extraction   # fast loop
make -f Makefile.cbm test                                   # full gate before commit
make -f Makefile.cbm test-par                               # parallel variant, same coverage
```

**Cross-language regression check is mandatory.** `extract_calls.c`, `extract_defs.c`,
`extract_imports.c`, `helpers.c`, and `lang_specs.c` are shared by every supported language. A green
`extraction` suite is not sufficient — run the full `test` target and confirm
`tests/test_lang_contract.c` and `tests/test_grammar_regression.c` still pass.

---

## 7. Finish

1. Re-run §2 against `/tmp/lang-bench/results-after`; put before/after nodes, edges, edges/node in
   the commit message.
2. Re-run the 12 benchmark questions for Elixir and update `docs/BENCHMARK.md:510-530` (per-language
   table), line 64 (summary row), and lines 79-81 (tier classification) if the tier changes.
3. Fix the arithmetic discrepancy identified in §1 as part of the same change.
4. Consider reconciling `scripts/clone-bench-repos.sh:56` (plausible/analytics) with the repo
   actually scored in the doc (elixir-plug/plug).

---

## 8. Expected outcome and honest caveats

| Step | Expected effect |
|---|---|
| 1 + 2 | Q8 PARTIAL → PASS; edges/node from ~1.0 toward Erlang's ~3.0. This is the tier move. |
| 3 | More nodes; Q2/Q3 deeper. Largest effect on metaprogramming-heavy repos (Phoenix), smaller on plug. |
| 4 | Q10 becomes substantive. |
| 5 | Q11 N/A → PASS. |
| 6 | Incremental edges. |

**Caveats to keep in mind:**

- The 3.0 edges/node target is borrowed from Erlang/cowboy, a different repo with different code
  density. It is a directional target, not a guarantee.
- Steps 1 and 2 are coupled. Landing Step 1 alone changes QNs without teaching the resolver the new
  shape, and could *reduce* resolution quality in the interim. Land them together, or verify
  edges/node after each.
- Hypotheses D and E (§3) are unconfirmed. If both are false, Step 2 is much smaller than described
  and the gain from Step 1 alone will be correspondingly smaller.
- Q11 changes the denominator; it is not free points.
- Percentage movement also depends on resolving the 86%-vs-95% bookkeeping question. Settle that
  before claiming a delta.

---

## 9. Execution report

Executed 2026-08-04 on `elixir-plug/plug` (shallow clone, 106 files, 22,483 LOC).

### 9.1 Result

| | Before (2026-03-01, `docs/BENCHMARK.md`) | Before (measured, HEAD 940f484f) | After |
|---|---|---|---|
| Nodes | 870 | 989 | **1,129** |
| Edges | 865 | 2,636 | **3,167** |
| Edges/node | 1.0 | 2.67 | **2.80** |
| Function | 554 | 555 | **624** |
| Class | 129 | 129 | **132** + 6 Interface |
| Variable | 6 | 8 (none of them Elixir) | **70** |
| CALLS | — | 1,364 | **1,650** |
| IMPORTS | — | 41 (28 point at the importing file's own module) | **93** |
| IMPLEMENTS | — | 0 | **20** |
| Score | 9.5/11 (86%), Tier 2 | — | **12/12 (100%), Tier 1** |

Q8 Inbound Trace PARTIAL → PASS (0 callers → 24 across 2 hops). Q10 6 non-Elixir Variables → 70
Elixir module attributes. Q11 N/A → PASS (20 IMPLEMENTS). No question regressed.

### 9.2 Where the diagnosis above was wrong

Four corrections. Each was checked against a real parse before any code changed.

1. **The baseline was five months stale.** §1 leads with "edges per node 1.0 … the graph is
   essentially nodes plus containment, with almost no `CALLS` edges". At HEAD the same index
   produced **2.67 edges/node and 1,364 CALLS edges**. Unrelated work had already closed most of
   that gap. The headline framing was wrong; the specific defects it named were all real.

2. **The 86%-vs-95% "arithmetic discrepancy" is not Elixir-specific and is not stale.** §1 says
   one of the two numbers must be wrong and to correct whichever it is. In fact *every* row in
   `docs/BENCHMARK.md` that contains a PARTIAL is short by exactly 0.5 per PARTIAL — the recorded
   numerator is `#PASS − 0.5 × #PARTIAL`, verified across Python, JavaScript, Erlang, Elixir,
   OCaml, Haskell, Scala, Ruby and Swift. Rescoring Elixir alone would have made it incomparable
   with the other 34 rows. The finding is now documented in `docs/BENCHMARK.md`'s methodology
   section instead, and the affected rows are left as recorded. Moot for the delta claimed here:
   the new Elixir row has no PARTIAL, so 12/12 is the same under either reading.

3. **Hypothesis D understated the damage.** §3 predicted `alias`/`import` inside a `defmodule`
   were *missed*. They were — but `parse_generic_imports(ctx, "call")` also matched the top-level
   `defmodule Foo do … end` call itself and recorded it as an import. That was plug's entire
   Elixir import graph: 41 IMPORTS edges, 28 of them pointing at the module the importing file
   itself declares.

4. **Hypothesis E was true but nearly irrelevant, for a reason §4 missed.** `build_import_map`
   indeed cannot map a dotted module name through `cbm_pipeline_fqn_module()`. But an Elixir alias
   is by construction a *suffix* of the module it aliases (`alias Plug.Conn` → you write
   `Conn.foo`), and `registry.c`'s `qualified_suffix_match` (0.90) already resolves exactly that
   shape — once Step 1 makes the target QN end in `.Plug.Conn.foo`. So Step 1 alone resolves
   aliased calls; the import-map work is a confidence and correctness improvement, not the recall
   unlock §3 predicted.

**One defect the plan missed entirely, and it was the largest single source of missing nodes:**
`def foo(a) when is_binary(a)` wraps the head in a `when` `binary_operator`, and
`extract_elixir_func_def()` bailed on anything that was not a `call` or `identifier`. **Every
guarded function head was dropped** — 102 of them in plug, including `Plug.Conn.get_req_header`,
the function §5's own verification step proposed to trace. Fixed by `cbm_elixir_def_head()`.

### 9.3 Decisions the plan left open

**Arity is NOT part of the qualified name** (§5 Step 1 asked for one policy, documented). An Elixir
function is `name/arity`, but a call site writes `foo(a, b)`, never `foo/2`, and pipes, default
arguments and `apply` make call-site arity reconstruction unreliable. More decisively:
`registry.c`'s `simple_name()` joins callee → definition on the QN's last dot-segment, so a
trailing `/2` would make **every** callee miss its target — a `foo/2` suffix breaks the resolver
outright. All clauses and all arities of one name in one module therefore collapse to a single
Function node; the first-seen head's parameter list is kept in `signature`. The rationale is
restated at the declaration of `cbm_elixir_scoped_qn()` in `internal/cbm/helpers.h`.

**`defstruct` / `defexception` emit no node** (§5 Step 3 suggested labelling them `Class`). Neither
introduces a name of its own — they characterise the enclosing module, which is already a Class
node, so a `Class` for them would be a duplicate QN. `defoverridable` is likewise skipped: it marks
existing functions rather than defining any. Their *fields* would be genuine new content, but that
is a separate change.

**Behaviour modules are labelled `Interface`.** `pass_semantic.c` keys IMPLEMENTS-vs-INHERITS off
the base node's label, so a module declaring `@callback` is labelled `Interface` (as is
`defprotocol`). This is what turns `@behaviour Plug` into an IMPLEMENTS edge rather than INHERITS.

### 9.4 What landed where

| Area | File | Change |
|---|---|---|
| Shared naming | `internal/cbm/helpers.{c,h}` | `cbm_elixir_scoped_qn`, `cbm_elixir_def_head`, `cbm_elixir_module_name`, `cbm_elixir_keyword_value`, `cbm_elixir_call_args`, `cbm_elixir_is_{module,func}_macro` — the def side and the call-scope side now share one implementation, so §5's "change both or neither" drift is structurally impossible |
| Steps 1/3/4/5 | `internal/cbm/extract_defs.c` | module-qualified QNs threaded through a frame stack; guard unwrapping; full `def*` family; descent into *any* `do_block`; module attributes as Variables; `@behaviour`/`defimpl` → `base_classes` |
| Step 1 (caller side) | `internal/cbm/extract_unified.c` | `compute_elixir_func_qn` takes the module scope; new Elixir branch in `push_boundary_scopes` pushes a SCOPE_CLASS for `defmodule` (unreachable via `class_node_types`, which is empty for Elixir) |
| Step 2 | `internal/cbm/extract_imports.c` | `parse_elixir_imports` replaces `parse_generic_imports(ctx, "call")`; handles `alias`/`import`/`require`/`use`, `Foo.{Bar, Baz}`, and `as:` |
| Step 2 (resolution) | `src/pipeline/pass_pkgmap.c` | full dotted path tried first as an import candidate; new `cbm_pipeline_find_dotted_module()` |
| Step 2 (resolution) | `pass_calls.c`, `pass_usages.c`, `pass_semantic.c` | dotted-module fallback in each `build_import_map` fast path |
| Step 6 | `internal/cbm/extract_calls.c` | bare pipe callee (`conn \|> halt`) |
| Tests | `tests/test_extraction.c` | the 8 tests from §6, plus `call_enclosing_qn()` asserting the def-side and call-scope QNs agree |

### 9.5 Verification

§6 requires the full gate, not just the extraction suite, because five of the touched files are
shared by every language. Both were run:

```
make -f Makefile.cbm test-focused TEST_SUITES=extraction   # 279 passed, 0 failed
make -f Makefile.cbm test-par                              # 6831 passed, 1 failed, 4 skipped
                                                           # (120 suites) — see below
```

`lang_contract` (37) and `grammar_regression` — the two §6 calls out by name — pass, as do
`extraction_imports` (22), `extraction_inheritance` (9), `grammar_labels`, `grammar_imports`, the
seven `grammar_probe_*` suites, `pipeline` (237), `edge_imports` (60) and `node_creation_probe`
(80). The 8 new tests from §6 are all present and passing.

**The one failure is pre-existing and unrelated.**
`daemon_runtime_disconnect_cancels_blocked_non_index_child_and_preserves_other_session`
(`tests/test_daemon_runtime.c:3711`, `ASSERT_TRUE(marker_published)`) asserts that a fake `git`
shim placed on PATH writes a PID marker file within a bound before the daemon cancels the child.
It touches no file in this change. Verified rather than assumed: a HEAD-only build in a separate
`git worktree` fails the same test — it passed exactly once, on its very first invocation, and has
failed every run since, in its own directory and in the repo directory, before and after clearing
the leftover `/tmp/cbm-runtime-*` state. The modified binary behaves identically in both
directories. It is a stateful/timing flake in this environment, not a regression.

**One environment caveat.** The default test build is ASan+UBSan, and on this host
(macOS Darwin 25.6, Intel, Apple clang 17) *any* ASan-instrumented binary — including a
`int main(){return 0;}` probe — dies with SIGILL, and the Nix gcc that `cc` resolves to ships no
`libasan` at all. The suites above therefore ran with `SANITIZE="-fsanitize=undefined"` under
`/usr/bin/clang`. UBSan coverage and every functional assertion are intact; ASan's heap-error
detection is not, and needs a re-run on a host where it works before the change is treated as
memory-checked. Nothing about this is specific to the change — it reproduces on an unmodified tree.

Cross-language spot checks beyond the suites: `psf/requests` (Python, 1,425 nodes / 6,159 edges)
and `ninenines/cowboy` (Erlang, 4,015 / 16,196) both index cleanly. The only cross-language code
path touched is import-target resolution, and it only fires when a definition's `name` is a dotted
path; no Python node in `requests` carries one, so the new candidate is inert there.

Not done: reconciling `scripts/clone-bench-repos.sh:56` (clones `plausible/analytics` for elixir
while the benchmark scores `elixir-plug/plug`). §7 item 4 reads this as an Elixir-specific
mismatch; it is not. The script and `docs/BENCHMARK.md` name different repos for **at least six**
languages — ruby (`rails/rails` vs `sinatra/sinatra`), bash (`ohmyzsh` vs `bats-core`), zig
(`tigerbeetle` vs `zls`), haskell (`pandoc` vs `postgrest`), erlang (`emqx` vs `cowboy`) and elixir.
The script is a deliberately larger stress corpus, not a stale copy of the scored one. Changing it
silently changes what a future benchmark run measures across every one of those languages, which
belongs to whoever owns the benchmark corpus, not to this work.
