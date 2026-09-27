# Test coverage

Run all groups with `sbcl --noinform --script scripts/test.lisp`.
The suite is connected to `asdf:test-system "mognitio"`.

| Acceptance IDs | Coverage |
|---|---|
| V01–V02 | Both literals, eight conditional combinations, nested conditions and branches |
| V03–V04 | Whitespace, EOF, and UTF-8 BOM rejection (updated for v0.9) |
| V05–V08 | Strict UTF-8 byte boundaries, invalid words/characters, source locations |
| V09–V12 | Empty input/blocks, missing delimiters/else, extra input, excluded grammar |
| V13–V14 | Full semantic traversal, malformed ASTs, checked boundary, generated form structure |
| V15–V16 | Compile flags/errors, canonical results, branch evaluation, host output isolation |
| V17–V19 | Arguments, literal paths, permissions, phase stopping, real process failure statuses |
| V20 | Other working directories, Unicode/spaced names, cold/warm compiler caches |
| V21 | Repeated executions, generated programs, grammar mutations, clean full-suite run |

The generated tests use independent test trees, a renderer, and a boolean
evaluator. They exhaust depth 0 and depth 1, then take 128 reproducible
samples with seed 9622 and maximum depth 5. Depth and sample index are
reported on a generated-case failure. This bound applies only to the tests.

Subprocesses use argument lists and separate stdout/stderr files, with a
20-second harness timeout and forced cleanup on timeout. Each suite run
owns a fresh temporary directory. Fault injection is confined to the test
system and test entry; there are no public CLI fault flags.

Valid v0.1 source cannot produce a non-boolean type. Semantic-failure
classification is therefore tested through injected compiler conditions;
malformed internal ASTs must produce internal failures instead.

The host result alone cannot show that an unselected pure branch was not
evaluated. Tests check generated CL:IF forms and observe evaluation with
test-only host effects. Production execution always calls the host compiler.

## Native compiler coverage

| Acceptance IDs | Coverage |
|---|---|
| N01–N08 | Both literals, every shallow conditional, nested/generated programs, source regression |
| N09–N11, N26–N28 | Required options, exact suffix, literal filenames and other working directories |
| N12–N14, N29 | Permissions, aliases, symlinks, safe replacement, cleanup and executable mode |
| N15–N17 | Silent build, phase stopping, native fault subprocesses, bootstrap failures |
| N21–N22 | ELF header/segment parsing, direct execution without source, clean environment |
| N23 | Actual executable under short writes, EINTR before/after a prefix, zero/error returns, broken stdout |
| N24 | Byte equality across relocated compiler/source paths and cold/warm caches |
| D01–D02 | SSA validity, dominance, edges, machine operands, fixups and integer/image bounds |
| D03, D05 | Hand-reviewed instruction goldens, branches for every if, no compile-time execution |
| D04 | Build with only launcher tools on PATH; process-launch traps during native compilation |
| D06–D08 | Publication faults, internal diagnostic positions, bootstrap and cache isolation |

The native generated suite executes both literals, all eight shallow if
combinations, and 128 fixed-seed trees. Every result is compared with both
the independent tree evaluator and the Common Lisp backend. Each source if
must have a corresponding SSA branch and machine conditional jump.
The golden fixtures include nested forward/backward branch displacements.

The runtime helper uses Python's standard library and Linux ptrace to control
write results in the actual executable. Short writes perform real kernel
writes. EINTR is injected both before output and after a partial prefix.
Zero and error returns must not report success. Missing ptrace permission
fails the test instead of silently skipping it. No fault option is exposed
by the compiler CLI.

## Integer and local-binding coverage

| Test group | Coverage |
|---|---|
| `v03-positive-kernel` | Precedence, signed comparisons, local values, assignment, scope, operand order and branch merges |
| `v03-rejection-kernel` | Token and grammar boundaries, types, names reserved during initialization, shadowing, literal range and output preservation |
| `v03-runtime-arithmetic` | Checked arithmetic, intermediate failures, unselected branches, unused results, host/runtime classification |
| `v03-integer-machine-goldens` | Independent instruction bytes, typed SSA edges, malformed operands, large entry frames |
| `v03-runtime-output-faults` | Actual executable stderr writes under short writes, interruptions, zero/error returns, retry exhaustion and broken streams |
| `v03-equal-incoming-values` | Shared incoming SSA values after branch assignments, int/bool, both conditions, nested and mixed merges, earlier operands |
| `v03-generated-oracle` | 128 fixed-seed integer trees with nested branches and mutation, compared against a separate mathematical evaluator |

The integer generator uses seed 314159265 and depth 3. The oracle operates on
test-only trees, computes truncating division from absolute magnitudes, and
checks each intermediate mathematical result. It does not call production
arithmetic or reuse the compiler's AST, symbol table, or SSA. Failures report
the seed, sample, and rendered input.

Earlier rejection fixtures were updated only where the language expanded:
ordinary words are now identifiers (unresolved names are semantic errors),
integer tokens and operators reach the parser, and grouping is accepted.
The semantic traversal test now checks the complete side table. Native
goldens reflect the entry frame, and generated-branch checks distinguish
source branches from runtime and frame-control branches. Relocation and
cold/warm-cache determinism now exercise integer values and mutation.

The production byte writer has a small write-chunk adapter for in-process
fault tests; no fault switch is exposed by the CLI. The same finite retry
budget is used by the host and native integer-failure paths.

## v0.3.0 acceptance traceability

| Acceptance IDs | Executable fixtures |
|---|---|
| V03-01, V03-20, V03-22 | Existing source/frontend, CLI and native regression groups |
| V03-02 through V03-17 | `v03-positive-kernel`, `v03-contract-boundaries`, `v03-equal-incoming-values`, existing source-format fixtures |
| V03-18, V03-21, V03-23 through V03-29, V03-38, V03-39 | `v03-rejection-kernel` |
| V03-30 through V03-37 | `v03-runtime-arithmetic`, mutable-value cases in `v03-contract-boundaries` |
| D03-01 through D03-05 | Frontend/semantic/backend groups and the positive/rejection kernels |
| D03-06 through D03-10 | SSA verifier, machine goldens, generated source branches, contract boundaries and equal-incoming-value regressions |
| D03-11 | `v03-runtime-output-faults` |
| D03-12 | Existing ELF and publication-fault groups |

The contract-boundary group also checks ordered edge arguments, duplicate SSA
definitions, typed jump rejection, adjacent overflow checks, division guards,
failure-artifact determinism, successful replacement before runtime failure,
and execution with the source removed and an empty environment.
Old word/grouping rejections changed under V03-15 and V03-21 through V03-23;
the corresponding native compatibility cases are N05 through N07.

## v0.4.0 functions and returns

| Acceptance IDs | Executable fixtures |
|---|---|
| V04-01 | All preceding boolean/integer groups, including equal incoming values |
| V04-02 through V04-07, V04-15 through V04-19 | `v04-typed-functions-and-order`, `v04-call-barriers-and-pressure`, `v04-name-type-and-flow-boundaries`, `v04-large-argument-frame-and-host-symbols` |
| V04-08 through V04-14 | `v04-return-paths`, `v04-name-type-and-flow-boundaries` |
| V04-20 through V04-29 | `v04-reserved-words-and-grammar`, `v04-static-errors-and-cycles`, `v04-name-type-and-flow-boundaries`, preceding source and integer rejection groups |
| V04-30 through V04-33 | `v04-call-runtime-order`, `v04-name-type-and-flow-boundaries`, `v04-return-paths` |
| V04-34, V04-37 | `v04-artifact-publication-and-output-faults`, preceding publication and ELF groups |
| V04-35, V04-36 | `v04-deterministic-standalone`, preceding standalone and relocation groups |
| V04-38 | `v04-generated-independent-oracle`, preceding boolean and integer oracles |
| D04-01 through D04-06 | Frontend/semantic cases and `v04-checked-and-ir-boundaries` |
| D04-07 through D04-11 | IR boundary cases, return paths, host symbol identity, runtime-order cases |
| D04-12 through D04-16 | Allocation intervals, independent map validator, symbolic parallel copies, call pressure, handwritten ABI, 600-argument frame |
| D04-17, D04-18 | Frame instruction and relocation goldens, ELF fields, all-functions IR checks |
| D04-19, D04-20 | Output/publication faults, relocation and independent generators |

The function generator uses seed 20260916, depth 3 and 128 programs, each
with four acyclic functions. Its own call frames and lexical return targets
model mutation, ordered arguments, nested calls, early exits and the first
arithmetic failure. It does not use production syntax, semantic, arithmetic
or IR data. Generated failures include seed, sample and complete source.

The native backend now uses linear scan with whole-interval call spills.
A separate pairwise checker validates allocation maps, and symbolic tuples
check parallel copies including register/memory cycles. The handwritten
machine caller/callee independently checks stack alignment, incoming offsets,
all allocatable register clobbers, and RSP/RBP restoration after two calls.
Fixed fixtures include mixed arguments, signed boundaries, 24-function chains,
600 simultaneous live values and 600 arguments. These are test bounds.

The v0.3 successful `int` identifier fixture now uses `intValue`; the exact
old `int` and `bool` names are covered by v0.4 parse rejections. All four
new keywords are tested at function, parameter, let and var name positions.
Historical validation records retain their original results.

## v0.4.1 parameter syntax

The parameter syntax correction uses `name: type` throughout fixed fixtures,
large-argument builders, and the independent generator. The
`v04-parameter-annotations` group checks both types, whitespace around colons,
parameter/token spans, and parse diagnostic locations. Old `type name`, mixed
syntax, and missing names, colons, or types are rejected by run and build,
including preservation of an existing output.

Instruction goldens use the [Intel instruction reference](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html),
including CALL rel32, REX.W/R/B, ModR/M and SIB addressing. Host lexical
function declarations follow [Common Lisp LABELS](https://www.lispworks.com/documentation/HyperSpec/Body/s_flet_.htm).

## v0.5.0 function values, void and loops

| Acceptance IDs | Executable groups |
|---|---|
| V05-01 through V05-08 | `v05-function-values-and-scope`, `v05-function-and-flow-contracts`, `v05-dispatch-call-loop-composite` |
| V05-09 through V05-13 | `v05-void-blocks-and-flow`, `v05-function-and-flow-contracts`, `v05-large-mixed-void-call` |
| V05-14 through V05-23 | `v05-unconditional-loops`, `v05-conditional-and-valued-loops`, `v05-function-and-flow-contracts` |
| V05-24 through V05-26 | `v05-function-and-flow-contracts`, `v05-unconditional-loops`, `v05-loop-completion-boundary` |
| V05-27 through V05-33 | `v05-keywords-and-source-shapes`, `v05-void-blocks-and-flow`, retained grammar and annotation groups |
| V05-34 through V05-44 | `v05-function-values-and-scope`, `v05-function-and-flow-contracts`, `v05-void-blocks-and-flow` |
| V05-45 through V05-52 | `v05-unconditional-loops`, `v05-conditional-and-valued-loops`, `v05-condition-termination-has-no-false-exit` |
| V05-53 through V05-56 | `v05-void-blocks-and-flow`, `v05-runtime-order-and-artifacts`, retained arithmetic/return groups |
| V05-57 | `v05-dispatch-call-loop-composite`, `v05-generated-control-oracle` |
| V05-58 through V05-60 | `v05-runtime-order-and-artifacts`, updated `v04-artifact-publication-and-output-faults`, retained native fault/standalone groups |
| V05-61 | All preceding boolean, integer, function, allocation and artifact groups |

| Internal IDs | Checks |
|---|---|
| D05-01, D05-02 | Keyword/token boundaries, spans, optional AST children, general callees and statement parsing |
| D05-03 through D05-07 | Source-order visibility, static aliases, signatures, early exits, loop targets and function candidates |
| D05-08 | `v05-checked-metadata-mutations` and retained checked-boundary corruption |
| D05-09, D05-10 | Typed constants/joins, call operands, loop entry/backedge/exit environments |
| D05-11 | `v05-cyclic-core-verifier`, `v05-independent-dominance`, no-exit CFG observations |
| D05-12 | `v05-core-function-candidates`, `v05-cyclic-function-candidate-fixed-point` |
| D05-13 through D05-15 | `v05-cyclic-allocation`, pressure/call composite, retained symbolic copy checks |
| D05-16, D05-17 | Host/native function dispatch, callee ordering, lexical exits, first/middle/last dispatch arms |
| D05-18 | `v05-handwritten-caller-generated-callee`, `v05-generated-caller-handwritten-callee`, `v05-handwritten-void-abi`, `v05-large-mixed-void-call`, retained call/frame tests |
| D05-19 through D05-21 | No-exit loops, branch fixups, runtime ordering, publication, relocated cold/warm builds and write faults |
| D05-22 | `v05-generated-control-oracle` plus the fixed acceptance cases above |

The two ABI cross-tests replace only one code unit after production
`lower-module` runs. A handwritten caller checks the generated callee's mixed
eight-argument positions, zero void result and RSP/RBP restoration over two
calls. A generated caller runs three loop iterations against a handwritten
callee that checks every incoming slot and alignment, then clobbers R8-R11.
Six live integer values and the loop state must survive each call.
Compacted argument-slot mutations on each generated side and a nonzero
generated void return are rejected. The handwritten-only fixture remains an
encoder/ABI check; it does not independently validate production lowering.

The new oracle uses seed 20260920 and 128 programs. Generated expressions
have maximum depth 4 inside fixed control-flow templates; loop bodies run
at most eight rounds. Separate test trees, mutable cells and explicit
normal/return/break/continue records model function selection, nested calls,
mutation and early exits. Arithmetic uses the independent mathematical
test helper, not production arithmetic. Failures report the seed, sample,
source and expected completion.

Cyclic Core tests independently check dominance by removing a proposed
dominator and testing reachability. Function candidate propagation starts
from constants and must reject unsupported cycles even with call metadata.
The allocation checker reconstructs live demands from instruction events;
a negative test truncates an interval while retaining its assigned location.
The dispatch/loop composite expects 305 and repeats with 32 and 600 live
values. Handwritten machine code checks void argument slots, zero results,
clobbers, alignment and frame preservation across repeated calls.

Nontermination observations first require a successful build, then inspect
separate host/native processes for one second, requiring no output and a
still-running process before forced cleanup. This is a bounded observation,
not a termination proof or a language timeout. No-exit CFG assertions supply
separate structural evidence. A million-round finite loop checks that
iteration does not consume a fresh call frame each round.

Compatibility fixtures now bind function expressions explicitly and place
dependencies before use. Former forward-reference success is separately
rejected. The old `void` identifier uses `Void` in positive fixtures.
Consecutive minus arithmetic uses explicit grouping; original token shapes
have parse-negative tests. Empty blocks, optional else and statements after
an exit now reach semantic checks. Function aliases and grouped calls are
positive cases; immutable reassignment and mutable function values remain
negative. Historical verification records are unchanged.

`v05-public-examples` executes every checked-in example and every README
language example through host execution, silent build and direct native
execution. The complete suite retains a single entry point.

## v0.6.0 frontend and host increment

`v06-frontend.lisp` covers literal bytes and spans, method postfix structure,
string typing, early-exit composition, static rejections in run/build, and
independent rejection of corrupted checked-operation metadata.
`v06-host.lisp` covers run semantics, mutation/evaluation order, a seeded scalar
list oracle, runtime failures, copy behavior, and collection across calls and
temporaries. The generated oracle uses seed 601 and 60 samples.

The host reclamation child uses `--dynamic-space-size 256`, 9,001 dynamic
allocations totaling 1,179,779,072 payload bytes, weak references, and full GC.
It asserts all tracked dead objects are collected and a separately held value
remains intact. The fault child distinguishes program storage failure (exit 4)
from compiler storage failure (exit 3), and checks first-failure ordering.
Instrumentation is test-only and is absent from the production ASDF system.

These host tests do not establish native text support, machine root publication,
collector reclamation, or complete v0.6.0 conformance. Existing native regression groups
continue to exercise the v0.5.0 behavior.

Three historical groups in `v04-functions.lisp` used `string` as an ordinary
name. The file remains unchanged. `v06-compatibility.lisp` explicitly replaces
those groups with copies retaining all other cases: the old local/binding name
becomes `text_name`, and the keyword token expectation becomes `:string`.
The v0.6 frontend negatives separately verify the old name is now rejected.
The replacement map is explicit and requires each historical group to exist.

## v0.6.0 Core and root plans

`v06-core.lisp` checks string SSA, deterministic literal pools, effect/type/arity
corruption, ordered lowering, and early exits. Its test interpreter uses ordinary
character sequences rather than the text runtime. Explicit expected results and
21 loop lengths exercise branch, call, continue, break, and return paths.

`v06-roots.lisp` uses handwritten SSA and exact expected sets for calls, last-use
operands, earlier arguments, receiver survival, parameter substitution, loops,
and no-exit SCCs. Negative tests corrupt the produced plans, and a test replaces
the producer with a failing stub while running the independent verifier.
All text helper calls are tested as register clobbers; only allocating helpers
and user calls are root safepoints. These tests validate root plans, not native
root publication or GC behavior.

## v0.6.0 native frame increment

`v06-native-frames.lisp` checks ABI v3 context initialization, AT_PAGESZ against
an independent OS query, mixed string/void/int/bool arguments in both handwritten
ABI directions, R15 and RAX preservation, root-head restoration, and repeated
helper calls. Test-only helper probes validate published roots and clobber
caller-saved registers without implementing text operations or GC.
Frame corruption cases cover slot clearing, homes, publication order, overlap,
stack-probe size, missing sites/unlink, return clobbers, and extraneous calls.
Static object tests inspect byte/scalar lengths, flags, alignment, NUL payloads,
padding, fixup target kinds, and deterministic encoding.

## v0.6.0 native text, collection, and integration

- `v06-native-text.lisp`: fixed text/flow expectations, independent scalar-list
  oracle, failure ordering, caller/operand/receiver/argument roots, spilled live
  values, loop/return handoff, and runtime instruction encoding.
- `v06-native-gc.lisp` and `v06-heap-check.py`: 64 KiB bounded-heap runs in normal
  and stress modes; allocation/free/reallocation records and independent heap
  parsing; no-sweep/all-mark negative controls; split, coalescing, arena growth,
  and requests larger than an arena. Observed reuse is explicitly a lower bound.
- `v06-native-faults.lisp`: independent byte/scalar overflow, successful int64
  boundary arithmetic, physical-size wrap, invalid roots, and failure priority.
- `v06-integration.lisp`: both-backend lifetime and method composition, source
  rejection/output preservation, cold/warm relocated standalone text/GC builds,
  atomic failure preservation, and native diagnostic syscall faults.

Internal options and heap records are test adapters, not public language or CLI
features. Normal artifacts retain boolean stdout and empty stderr on success.

Debug root classification tests reject a four-byte object's interior pointer
whose apparent flags contain the static bit, as well as freed interiors,
forged static headers and unmapped addresses. Known literal starts (including
empty), zero slots and duplicate dynamic roots remain valid. Validation checks
address membership before reading candidate metadata.

## v0.7.0 data, contracts, and unified branches

| Groups | Coverage |
|---|---|
| `v07-data-and-source-order` | Nominal identity, aliases, namespaces, exact fields/payloads, initializer order and exits, immutable data, comma lists |
| `v07-branch-contracts` | Condition/subject order, exhaustiveness, arm scopes, all-arm checking, function joins, return/break/continue |
| `v07-methods-and-dispatch` | Contract conformance, inherent methods, receiver identity, interface conversion/retention, same-name dispatch, conservative cycles |
| `v07-transitive-lifetime-and-reclamation` | Deep graph and extracted-child survival, finite heap, independent reclamation/reuse observer, no-sweep/all-mark/no-trace/parent-retention controls, host weak references |
| `v07-deep-shared-data` | Forty nested nominal types with shared children; bounded heap and measured fixed-point passes |
| `v07-allocation-and-operand-failures` | Both-backend first-failure order, host storage failure, native arena failure |
| `v07-checked-metadata-boundaries`, `v07-core-value-boundaries` | Independent reconstruction, aliases/slots/contracts/candidates, wrong variant and subject guards |
| `v07-root-last-use-and-child-independence` | Make operands rooted through allocation; live child without dead parent; missing/excess roots rejected |
| `v07-native-child-and-metadata-faults`, `v07-interface-table-faults` | Exact child addresses before dereference, unknown descriptors/tables, concrete/table mismatch |
| `v07-hidden-receiver-abi`, `v07-native-static-layout-and-table-order`, `v07-interface-frame-corruption` | Handwritten hidden-receiver ABI, independent byte/offset/slot expectations, frame corruption |
| `v07-keywords-migration-and-construction-ast`, `v07-artifact-identity-and-standalone` | Keywords, constructor parsing/spans, old grammar rejection, deterministic artifacts and empty-environment execution |
| `v07-interface-requirement-syntax` | Let-named requirement AST/spans, no function value/ID, body-required ordinary functions, isolated old/body/var/alias/expression rejection, dispatch |
| `v07-reused-aggregate-padding` | Dirty block collection and actual reuse by empty/one-slot struct/enum helpers, whole physical padding and split boundary |
| `v07-implementation-table-layout-order` | Concrete/interface ID layout order independent of reversed implementation declarations; registry identity preserved |

Source acceptance fixtures execute through both host and native backends, with
an additional native run collecting before every allocation. Rejections check
run/build phases and existing-output preservation. Internal corruption tests
are separate from source-language rejection cases.

The current suite migrates old `if` fixtures to `branch when` with the original
condition and arm scopes. Tests retain their prior names to preserve coverage
traceability. Unknown type names now reach semantic checks, comma lists accept
one trailing comma, and bare method references are semantic errors.
[The migration manifest](v07-migration.json) records baseline file and source
template hashes and corresponding groups. Historical release records and tags
remain the authority for the original fixtures.

See [the v0.7.0 validation record](../verification/v0.7.0.md) for observations
and the complete acceptance mapping. None of these test bounds impose a new
source-language limit.
The [follow-up review record](../verification/v0.7.0-review.md) documents the
new requirement spelling and review regressions. Current constructor rejection
fixtures bind their result before a valid bool tail to isolate the violation.

## v0.8.0 coverage

The 55 versioned acceptance IDs have 156 source fixtures. The release-time
hashes and expected outcomes are in `../verification/v0.8.0-cases.json`,
paired with `../verification/v0.8.0-results.json`. v0.8.1 keeps the annotated
sources in `v08-conformance.lisp` and their hashes in
`../verification/v0.8.1-cases.json`. Successful fixtures run on both backends,
including native GC stress. Rejected sources check phase and existing artifact
preservation. `scripts/verify-v08.py` independently records CLI and standalone
process statuses, output bytes, source hashes, and deterministic artifact hashes.

| Group files | Additional checks |
|---|---|
| v08-frontend, v08-bindings | Token-only generic commitment, spans, block panic, explicit binding categories |
| v08-types, v08-functions | Rigid type checking, identity/alias/domain, excluded features, static calls and recursion |
| v08-specialization | Canonical closure, nested free types, fresh tables, erasure, backend gates and corruption |
| v08-errors | Canonical try, exact E, lexical owners, noncompletion, message bytes, metadata corruption |
| v08-runtime, v08-core | Terminal roots, Err last-use roots, guarded payloads, frame corruption, private ABI, descriptor bytes, write faults |
| v08-lifetime | Strong child survival, dead parent reclamation, region reuse, GC mutants, host weak references |


## v0.8.1 coverage

v0.8.1 removes the v0.8.0 permission to omit a local annotation on a direct
function expression or static function alias. Regression sources now carry
concrete function types or generic binding signatures. `v08-bindings.lisp`
covers rejected omission, annotated function and branch values, alpha-equivalent
generic templates and aliases, and signature, arity, parameter, return, `var`,
and runtime-position rejections. Method declarations and pattern bindings keep
their existing forms. The v0.8.0 acceptance catalog remains the C08 suite. Migrated sources and
their hashes are in `verification/v0.8.1-cases.json`, which
`scripts/verify-v08.py` checks. `verification/v0.8.0-cases.json` and
`verification/v0.8.0-results.json` stay the release-time pair. Generic struct
fields and enum payloads reject function types.

Existing regression groups remain enabled. `v08-migration.json` records the
annotation and function-binding fixture changes without changing historical
release sources or records.

## v0.9.0 source migration

`v09-source.lisp` tests line comments, decimal and identifier boundaries,
Unicode scalar escapes, source byte ranges, and host/native execution agreement.
It checks that source failures leave an existing build artifact unchanged.
The BOM, raw string scalar, and leading-zero cases in older test groups now
follow the development branch's source rules. Older branch fixtures now use
explicit unused payload names instead of underscore patterns. Full v0.9.0 syntax and semantics
remain outside this initial increment; see [progress](../verification/v0.9.0-progress.md).
