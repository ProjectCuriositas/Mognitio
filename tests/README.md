# Test coverage

The ASDF `mognitio/tests` system is the current v0.9.0 suite.
Run it with `sbcl --noinform --script scripts/test.lisp`.
A failed assertion or unavailable required facility fails the command.
The summary counts test groups, assertions, and actual child processes.

## Current coverage

| Files | Independent observations |
|---|---|
| v09-source | Strict UTF-8, comments, decimals, identifiers, scalar escapes, byte spans |
| v09-fixtures, v09-boundaries, v09-frontend | Positive and rejection matrices, type identity, scopes, completion, captures, templates, methods, lists, control |
| v09-runtime | Host/native outcomes, exact diagnostic bytes, allocation failure at each stage, publication failures |
| v09-proofs | Symbolic and concrete proof mutations, builtin records, Core bounds/type graph, root plans, encoded metadata, host reclamation |
| v09-abi | Handwritten caller/generated callee and reverse, hidden context, arguments, return handoff, machine mutations |
| v09-lifetime, v09-heap-check.py | Small-heap reclamation/reuse, transitive references, extracted children, growing live data, independent object/descriptor/table/buffer reader, collector costs |
| v09-memory-boundaries | Invalid root pointers, forged static bits, maximum-length helpers, physical allocation overflow, corrupt buffer count |
| v09-oracles | Seeded independent sequence/String expectations and executable preservation before publication |
| v09-inherited | Retained SSA dominance, GC edge liveness, frame transitions, encodings, and mutations |
| generated, native-generated | Independent Boolean-tree evaluator, deterministic cold/warm and relocated builds |
| native-ir, native-process | SSA/encoder/ELF checks, canonical CLI, path handling, phase stopping, faults, output isolation, standalone execution |
| v04-allocation, v05-core | Parallel copies, spills, large frames, loop phi/backedge liveness, alternative block orders |
| v09-examples | Every distributed example through host and native paths |

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
| Unit named void, bare return, value-producing unconditional loop | Unit/unit, return value, while/over with plain control statements |
| Optional when else, on wildcard/else, untyped payload binding | Required final else for when, exhaustive named on cases, optional typed binder |
| Slice bounds trap | Result<String,SliceError> with requested bounds and length |
| Old build flags and required source suffix | Canonical run/build arguments and unrestricted suffix |
| ABI v4 / non-reference Function | ABI v5, closure roots and code pointers, typed List/buffer tracing |

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
