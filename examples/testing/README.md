# Language tests

From the compiler checkout:

```sh
./bin/mgn test examples/testing/mognitio.toml
```

Both `@test` declarations pass, with exit 0. Each test uses a fresh native
process and initializes its module and dependencies before calling its body.
`run` and `build` use the ordinary `main` and do not automatically call tests.
Removing `main` still permits `test`, while normal entry validation rejects
`run` and `build`.

Tests are discovered from `@test` on module-level immutable `let` declarations.
The required type is `Function(): Unit`, including aliases of that type.
The initializer may produce a function through an ordinary factory call.
Function names and file names do not identify tests. Private and public tests
are both collected; normal visibility and lexical scope still apply.

`@test` precedes `public`, if present. Unknown, duplicate, or misplaced
attributes are errors. Attribute arguments and user-defined attributes are
not supported. Attributes are declaration metadata, not executable macros.

Use `assert <Bool expression>;` in test bodies or ordinary helpers. The operand
is evaluated once; false stops the current execution as an assertion failure.
Panic and other runtime failures keep their own classification. Normal run and
standalone native artifacts also retain assertions and report their source
location. Release or optimization settings do not disable assertions.

All `.mgn` sources under the project's `src` are checked before discovery and
execution. Sources outside `src` are excluded. All test images are prepared
before any test begins. Tests execute in source-path and declaration order.
An empty, statically valid suite succeeds without running initializers.

Every test sees stdin at EOF. Application stdout/stderr is captured separately
and reported to runner stderr with test identity, stream name and escaped bytes.
NUL, newlines and partial UTF-8 bytes cannot impersonate a result or summary.
Runtime diagnostics use a separate private channel. Large application output is
drained while the child runs; no application-output size limit is imposed.

Filesystem changes remain visible to later tests even though language state is
fresh. The runner supplies no per-test filesystem sandbox or rollback.

Results and summary counts go to stdout; failure details go to stderr.
Diagnostics identify the test, initialization/body stage when known, failure
kind, and the assertion location where applicable. A test failure permits the
next test to run; command failures stop further attempts.

| Exit | Meaning |
|---|---|
| 0 | All tests passed, including a valid empty suite |
| 1 | Static source error |
| 2 | Command, input, process preparation, or reporting I/O failure |
| 3 | Compiler or runner internal failure |
| 4 | Panic or another language runtime failure |
| 5 | Assertion failure |
| 6 | Abnormal termination of a started test |

For a completed suite, abnormal termination takes precedence over runtime
failure, then assertion failure. Command failure takes precedence over the
suite result. A started test interrupted before its result is known is
`aborted`; tests never started are `not_run`. Known results are retained.
The summary counts satisfy:

```text
total = passed + failed + errors + aborted + not_run
```

Before the first test starts, a command failure emits no summary. Broken
output streams cannot guarantee a complete report. Infinite tests have no
built-in timeout, and external termination of the runner cannot guarantee
cleanup. Parallel execution, filtering, fixtures, setup/teardown, parameterized
tests, mocking, coverage, benchmarks, and macros are outside this increment.
