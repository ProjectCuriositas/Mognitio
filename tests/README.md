# Test coverage

The ASDF `mognitio/tests` system is the current v0.14.0 suite.
Run it with `sbcl --noinform --script scripts/test.lisp`.
A failed assertion or unavailable required facility fails the command.
The Lisp summary counts test groups, assertions, and processes invoked through
the general harness. Runner-owned native children and Python-suite processes
are additional; see the [current record](../verification/v0.14.0.md).

The retained [test acceptance ledger](../verification/v0.11.0-testing.md) maps all 72
cases to executable fixtures. Host/process audit details are recorded
[separately](../verification/v0.11.0-process.md).

## Current coverage

| Files | Independent observations |
|---|---|
| v013-directory.py, v013-integration.py | Same host/native lexical paths, names/kinds/order, raw invalid UTF-8, links, permission failures, Function storage, try, static rejection, initialization and shared filesystem |
| v013-inheritance.py | Separate-process umask, default ACL, setgid and a distinct supplementary parent GID, unchanged metadata and syscall policy |
| v013-reference.py | Explicit breadth-first traversal, exact bytes, rerun, all later failure phases, language assertions and source-absent native execution |
| v013-host.lisp, v013-native.lisp | Host resource/error paths, native growth/sorting with forced collection and kept values |
| v013-failures.lisp, v013-records.lisp | Phase-specific faults, malformed raw records, first-observation ties, close/map failure priority, ownership corruption, each value/subject allocation and old/new map cleanup |
| v013-runner.lisp, v013-proofs.lisp | Actual directory internal faults, private status/version adversaries, parent ledger/cleanup, nominal/Core/frame/root/terminal and encoded-header mutations |
| v013-review.lisp | Actual mmap ENOMEM/EINVAL across all scratch acquisitions and growth, cleanup-before-diagnostic trace oracle, initializer/body runner outcomes, independent latch control-flow mutations in both profiles |
| v012-review.py, v012-review.lisp | Repeated stdin after invalid UTF-8, broken startup diagnostics, test source errors plus signal restoration failure, and ordinary nonzero status |
| v012-entry.py | Raw argument bytes, order, empty/literal values, strict UTF-8, entry types and application status |
| v012-io.py, v012-files.py | CL/native exact I/O bytes, invalid paths, file modes/ACLs, symlinks/hardlinks, chunk boundaries, real SIGXFSZ and broken pipes |
| v012-execution.py | Ordinary function values and evaluation order, initialization dependencies, repeated test instances, large escaped output and private diagnostics |
| v012-reference.py | Distributed converter success/failure cases, language tests, changed data and source-absent native execution |
| v012-proofs.lisp | Catalog/Core/machine/context mutations, resource cleanup paths, encoded ABI metadata and incremental UTF-8 state |
| v012-host.lisp | Complete signal-action restoration, guard/close/storage failures, partial transfers, allocation cleanup, protocol framing and all five pipe acquisitions |
| v012-native.lisp | Real syscall faults and traces, close precedence, cleanup before allocation failure, small-heap GC, real child/runner file limits and signal bootstrap failures |
| v011-testing.py | Public test CLI, attributes, assertion semantics and positions, discovery, entry independence, input preservation, large raw payloads, actual closed output pipes |
| v011-proofs.lisp | Checked metadata and TestPlan mutations, wrapper proof, R8-R11 stage pressure with native execution, nested generic identity and small-heap capture |
| v011-runner.lisp | Command interruption accounting, preparation ownership, reap/fd safety, shared initialization, actual signal termination and output failures |
| v011-transport.lisp | Independent binary records, actual broken event channel, pre-exec action failures, deferred start-commit interruption and EINTR/EPIPE controls |
| v011-review.lisp | Host storage-condition recovery and cleanup, all-opcode destination preservation, committed failure context and assertion-site recovery without duplicate reporting |
| v09-source | Strict UTF-8, comments, decimals, identifiers, scalar escapes, byte spans |
| v09-fixtures, v09-boundaries, v09-frontend | Positive and rejection matrices, type identity, scopes, completion, captures, templates, methods, lists, control |
| v09-revision | Value-loop joins and exits, arrow field/call resolution, witness evidence, ordinary underscore, host allocation boundary, body-only generic type proof mutations |
| v09-runtime | Host/native outcomes, exact diagnostic bytes, allocation failure at each stage, publication failures |
| v09-proofs | Symbolic and concrete proof mutations, builtin records, Core bounds/type graph, root plans, encoded metadata, host reclamation |
| v09-abi | Handwritten caller/generated callee and reverse, hidden context, arguments, return handoff, machine mutations |
| v09-lifetime, v09-heap-check.py | Small-heap reclamation/reuse, transitive references, extracted children, growing live data, independent object/descriptor/table/buffer reader, collector costs |
| v09-memory-boundaries | Invalid root pointers, forged static bits, maximum-length helpers, physical allocation overflow, corrupt buffer count |
| v09-oracles | Seeded independent sequence/String expectations and executable preservation before publication |
| v09-inherited | Retained SSA dominance, GC edge liveness, frame transitions, encodings, and mutations |
| generated, native-generated | Independent Boolean-tree evaluator, deterministic cold/warm and relocated builds |
| native-ir, native-process | Internal kernel SSA/encoder/ELF checks, kernel invocation, path handling, phase stopping, faults, output isolation, standalone execution |
| v04-allocation, v05-core | Parallel copies, spills, large frames, loop phi/backedge liveness, alternative block orders |
| v09-examples | Silent examples through public run/native; the converter uses v012-reference.py |
| v010-projects.lisp | Current argument/status entry migration of the language matrix, cross-module GC stress, independent project proof mutations, reader and publication faults, symbolic signature proof rejection |
| v010-projects.py | Public project CLI grammar, manifests, imports, visibility, identities, initialization, path boundaries, deterministic relocated images, symbolic generic visibility, directory classification, PATH invocation and standalone execution |

The short frontend command is `sbcl --noinform --script scripts/test-v09-frontend.lisp`.
It is a development aid, not a substitute for the full gate.

Native fixtures run with both ordinary collection and collection before each
allocation. Fault ordinals are enumerated separately per backend; layouts and
allocation counts need not match. The Python heap reader consumes emitted
bytes and an internal observation record, without calling compiler helpers.
It distinguishes object scans, full arena passes, and block-header visits.

## Intentional migration from earlier versions

The current suite does not silently reinterpret old accepted syntax.
Earlier version files not listed by ASDF remain historical fixtures; run them
from their matching historical checkout, not as current-language tests.
Historical validation records preserve their original counts and results.

| Earlier expectation | Current test replacement |
|---|---|
| Lowercase builtin types and lowercase function type | Explicit Int/Bool/String/Unit/Function, reserved-name and user-alias tests |
| `struct` / `enum` / `interface`, implicit packaging, `this` | Product/sum/contract, explicit evidence, typed Self receiver |
| Binding-only generic signatures | Top-level templates and first-class explicit specialization |
| Noncapturing finite function IDs | Snapshot closures, higher-order storage, indirect ABI, runtime dispatch recursion |
| Unit named void, bare return | Unit/unit, return value, while/over with plain break; unconditional loop with explicit break value |
| Dot projection, implement/against evidence spelling, forbidden standalone underscore | Arrow member selection, witness/implements, ordinary underscore names |
| Optional when else, on wildcard/else, untyped payload binding | Required final else for when, exhaustive named on cases, optional typed binder |
| Slice bounds trap | Result<String,SliceError> with requested bounds and length |
| Single-source CLI and Boolean output | Manifest project CLI with declaration-only modules and explicit argument/status main |
| At-sign always rejected by lexer | At-sign introduces attributes; dollar-sign fixtures retain lexical-rejection coverage |
| ABI v4 / non-reference Function | ABI v6 context, closure roots and code pointers, typed List/buffer tracing |

Retained low-level tests were migrated only where source spelling or an explicit
oracle changed. `v09-inherited.lisp` preserves original test names for
traceability. Current acceptance is established by current tests, not by adding
historical test counts to the new summary.

## Limits

Generated samples are bounded and seeded; they do not prove every possible
program. GC probes use controlled layouts and internal faults, not hardware
faults. RSS is not used as the reclamation oracle. Reverse-chain full-heap
marking remains quadratic in header visits; the tests make that cost visible.
External termination, uncatchable resource exhaustion, concurrent filesystem
replacement, and power-loss durability are not certified by these fixtures.

## Project and kernel boundaries

`v010-projects.py` runs automatically after the Lisp suite. Its process checks
are reported separately from the Lisp test/assertion/process counts.
The current positive language matrix and all distributed examples execute through
project loading, module checking, the current Int entry, and both backends. The converter
uses a separate fixture with explicit argument, cwd and file expectations.

`kernel-driver.lisp`, `kernel-entry.lisp`, and `kernel-cli` are test-only adapters.
They preserve independent Boolean-tree, writer-syscall, ABI, and fault oracles
without exposing a second installed CLI mode. Historical kernel checks do not
establish project CLI conformance. The production launcher loads none of these
adapters and accepts only `mognitio.toml` projects.

## v0.14 increment

`v014-text.lisp`, `v014-io.lisp`, and `v014-proofs.lisp` cover the two text
methods, generic rejection, I/O phases, consumer absence guards, transient roots,
cleanup latch mutations, and structural operation counters. `v014-integration.py`
checks public commands, copied standalone artifacts, evaluation noncompletion,
nominal phase values, built-in tests, and old/new escaping equivalence.
Run `sbcl --noinform --script tests/v014-measure.lisp` separately for bounded
normal/small-heap allocation, collection, retained-byte and elapsed observations.
Those observations do not establish a whole-program complexity or speedup claim.
