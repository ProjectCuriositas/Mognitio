# File converter

This example reads one UTF-8 file and writes `# Converted\n` followed by its
unchanged contents. It demonstrates ordinary functions, `Result`, `try`, runtime
arguments, explicit application status, and text I/O.

From this directory, with the compiler's `bin` directory on PATH:

```sh
printf 'hello' > input.txt
mgn run mognitio.toml -- input.txt output.txt
mgn build mognitio.toml -o convert
./convert input.txt output.txt
```

Both executions print `converted` followed by LF and return 0 on success.
Missing arguments return 2. Input or output failure returns 1 and prints
`conversion failed` to stderr. Success-notification failure also returns 1.
Native executables read current data at execution time and need no source,
manifest, compiler or shared runtime library.

## Standard functions

All symbols require a grouped import such as
`use Std\Io\{IoError, readTextFile, writeTextFile};`. They are ordinary function
values and can be aliased, captured, passed as arguments, or stored in lists.

| Function | Type |
|---|---|
| readTextFile | Function(String): Result<String, IoError> |
| writeTextFile | Function(String, String): Result<Unit, IoError> |
| readStdin | Function(): Result<String, IoError> |
| writeStdout | Function(String): Result<Unit, IoError> |
| writeStderr | Function(String): Result<Unit, IoError> |

`IoError` is a product with `operation: IoOperation`, `kind: IoErrorKind`,
`subject: String`, and `phase: IoErrorPhase`. Phase is the ordinary imported Sum
`Input`, `Target`, `Body`, or `Cleanup`; standard streams use only `Body`. The operation variants are `ReadTextFile`, `WriteTextFile`,
`ReadStdin`, `WriteStdout`, `WriteStderr`, `JoinPath`, `ReadDirectory`, and
`CreateDirectory`. The kind variants are `InvalidPath`,
`InvalidEncoding`, `NotFound`, `PermissionDenied`, `UnsupportedTarget`,
`BrokenPipe`, `ResourceExhausted`, and `Other`. File subjects retain the original
path; stream subjects are `stdin`, `stdout`, and `stderr`.

UTF-8 is strict. BOM, embedded NUL in content, CRLF and a missing final LF are
preserved. Empty paths and paths containing NUL fail before file I/O, after all
call arguments have been evaluated. Paths are literal and relative to the
process's current directory. The compiler does not change that directory.

File APIs accept regular files, including their symlinks and hardlinks. Writes
create or truncate directly; partial output may remain after failure. New files
request mode 0666, constrained by the OS umask or inherited ACL. Existing modes
are not widened. Parents are not created. These APIs provide no atomic replace,
durability, directory traversal, exposed File handle, or `defer` facility.

Every file operation releases owned resources before returning. Standard
streams remain borrowed and open. Expected errors return Err without implicit
panic or a hidden exit-status change. SIGPIPE and SIGXFSZ write failures return
through the ordinary error path. Output APIs add no newline of their own.

## Language tests

Create the example's fixture directory in the shell:

```sh
mkdir -p fixtures
printf 'hello' > fixtures/input.txt
mgn test mognitio.toml
```

The two tests check conversion and an expected missing-input error. Ensure
`fixtures/missing.txt` is absent. The test runner leaves `fixtures/output.txt`
in place. Each test has fresh language state and EOF stdin, while filesystem
changes are shared. Application output is escaped and identified on runner
stderr; result lines and the summary remain on runner stdout.
