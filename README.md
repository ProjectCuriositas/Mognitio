# Mognitio

Mognitio is a typed language with immutable data, persistent lists, explicit
contracts and generic templates, and first-class functions with snapshot captures.
Version 0.15.0 adds a shared static analyzer, a stdio language server, build-time
toolchain identities, and Linux APT/offline packaging.
The compiler targets Linux amd64. Package tooling in this branch does not imply
that an official binary release or public APT repository has been published.

## Start here

- [Examples](examples/): executable projects, including [multiple modules](examples/modules/).
- [Test coverage](tests/README.md): current project cases and internal regression oracles.
- [Release validation](verification/v0.14.0-release.md): pinned release checks.
- [Language tests](examples/testing/README.md): `@test`, `assert`, and `mgn test`.
- [File converter](examples/file-converter/README.md): arguments and text I/O.
- [Directory converter](examples/directory-converter/README.md): explicit tree traversal.
- [Implementation verification](verification/v0.14.0.md): evidence and limits.
- [Verification commands](verification/README.md): reproduce the checks.
- [Toolchain distribution](packaging/README.md): pinned builds, APT staging, and offline installation.
- [Contributing](CONTRIBUTING.md): public contribution conventions.

## Requirements and commands

The compiler host is Linux amd64 with glibc 2.34+, SBCL, ASDF, UIOP, and SB-POSIX.
No Quicklisp, external compiler, assembler, or linker is required.

Add the compiler checkout's real `bin` directory to PATH. From the compiler
repository root, this configures the current shell:

```sh
export PATH="$PWD/bin:$PATH"
```

For persistent setup, add that absolute `bin` path to your shell configuration.
Keep the compiler checkout intact: copying or symlinking only the launcher into
another directory is not a supported installation method.

From your Mognitio project's directory, use the `mgn` command:

```sh
mgn run mognitio.toml
mgn test mognitio.toml
mgn build mognitio.toml -o app
./app
```

Compiler contributors can invoke the launcher directly from its checkout:

```sh
./bin/mgn run examples/modules/mognitio.toml
./bin/mgn build examples/modules/mognitio.toml -o example
./example
```

Normal execution returns the main function's status without printing its result.
Build succeeds silently. Application I/O is explicit.
Test execution prints per-test results and a summary; see the [test guide](examples/testing/README.md).
The generated Linux amd64 ELF needs no compiler, source, libc, dynamic loader,
or cache at runtime. Build checks all sources without executing initializers.

The commands are `run <mognitio.toml> [-- arguments...]`, `test <mognitio.toml>`,
and `build <mognitio.toml> -o <artifact>`.
Relative paths use the caller's directory. The output parent must exist.
All inputs and future `.mgn` sources are protected against output replacement,
including aliases through hardlinks and symlinks. Publication uses a temporary
image and atomic replacement. Precommit failures preserve the old artifact;
an uncertain rename outcome is reported explicitly.

## A project

`mognitio.toml` uses TOML 1.0.0 and requires exactly these two string settings:

```toml
[project]
name = "app"
root_namespace = "App"
```

The entry is `src/app.mgn`. Every source is one module, with a namespace matching
the root namespace plus its directories. Multiple files can share a namespace.
All modules contain declarations only. The entry declares its own immutable
`main` binding of type `Function(List<String>): Int`:

```mgn
namespace App;
use App\Domain\{Page, Printable, PagePrintable, makePage};

let main: Function(List<String>): Int = function(args: List<String>): Int {
    let page: Page = makePage("Multiple modules");
    let printable: Printable = Printable(page);
    branch when {
        printable->text() == "Multiple modules" => 0,
        else => panic { "Unexpected page text" }
    }
};
```

The [domain module](examples/modules/src/Domain/page.mgn) declares the imported
symbols. Every import requires braces, including a single symbol; `as` introduces
an alias. Other files require explicit imports even within the same namespace.
Wildcards and re-exporting with `public use` are not supported.

Declarations are private to the file unless marked `public`. Types, aliases,
contracts, templates, immutable bindings, and named witnesses can be public.
A witness such as `public witness PagePrintable = Page implements Printable`
binds compile-time evidence; importing a type alone does not import its witnesses.
An imported binding retains its original identity and is initialized once.
Dependencies initialize first, with ready modules ordered by relative UTF-8 path.
Unused modules are checked but not initialized.

Bindings and parameters declare their types. Functions capture value snapshots.
`product` and `sum` create nominal types; `alias` preserves identity. Templates
require explicit type arguments. See [collections](examples/collections/),
[contracts](examples/data-contract/), and [results](examples/results/).
All value members use `->`. The identifier `_` is an ordinary name; use
`discard expression;` to discard a non-Unit result.

`List<T>` is persistent. Length is constant time, append performs constant
structural work, indexing is linear, and a complete traversal prepares one
forward buffer in linear time. Allocator, GC, and loop body costs are separate.
Invalid indexing and String slicing return `Result` values.

`String->scalars()` returns a `List<String>` in Unicode scalar order; each
element has length one. It preserves NUL, BOM, combining marks and line endings.
`List<String>->join(separator: String)` returns one String with separators only
between elements. Both use linear structural work; allocator and collector costs
are separate. Aliases preserve these methods, but unconstrained `List<T>` has no
`join`, even if a template is only instantiated with `String`.

## Arguments and I/O

The main function receives arguments after `--` for `run`, or after the executable
name for native programs. Empty strings and a second `--` remain literal data.
Every argument must be valid UTF-8 before any user initializer executes. The
returned Int must be 0 through 255; another value is a runtime failure.

Import ordinary functions explicitly from `Std\Io`: `readTextFile`,
`writeTextFile`, `readStdin`, `writeStdout`, and `writeStderr`. They return
`Result<String, IoError>` for reads or `Result<Unit, IoError>` for writes.
Expected I/O errors are values; discarding an Err does not change exit status.

`IoError` now requires `phase: IoErrorPhase` in addition to operation, kind and
subject. Import `IoErrorPhase` explicitly from `Std\Io`; its variants are `Input`,
`Target`, `Body` and `Cleanup`. Standard stream errors use `Body`, including
private scratch-release failures; borrowed descriptors are never closed.
A missing directory is a creation candidate only for a `ReadDirectory` error
with `Target`, `NotFound`, and the requested subject. `Body` or `Cleanup`
failures must not be treated as an absent or empty directory.
See the [converter guide](examples/file-converter/README.md) for signatures,
error fields, resource behavior, and runnable examples.

The directory functions are ordinary imported Function values too:

| Function | Result |
|---|---|
| `joinPath(base: String, relative: String)` | `Result<String, IoError>` |
| `readDirectory(path: String)` | `Result<List<DirectoryEntry>, IoError>` |
| `createDirectory(path: String)` | `Result<Unit, IoError>` |

`DirectoryEntry` has `name: String` and `kind: DirectoryEntryKind`. The kind is
`File`, `Directory`, `Symlink` or `Other`. Enumeration returns direct children in
Unicode scalar order, with no partial list on failure. Root links are resolved
normally; child links are classified without following them. Creation accepts an
existing directory and creates one missing level, subject to the OS umask/ACL.

`joinPath` is lexical: it preserves dot components, slash spelling and Unicode.
It does not access the filesystem or establish a containment boundary. Directory
operations append `JoinPath`, `ReadDirectory` and `CreateDirectory` to
`IoOperation`; an exhaustive match must include all eight variants.
See the [directory example](examples/directory-converter/README.md) for traversal,
output assumptions and failure behavior.

## Results and failures

| Exit | Meaning |
|---|---|
| 0 | Successful build or test suite (including zero tests) |
| 1 | Source, lexical, parse, name, or type error |
| 2 | Compiler/runner I/O, invocation, manifest, or argument startup error |
| 3 | Internal compiler, execution, or bootstrap failure |
| 4 | Detected runtime failure or panic |
| 5 | Assertion failure |
| 6 | Abnormal termination of a started test |

The table describes compiler/runner and language failure classifications. A
normal application may explicitly return any status from 0 through 255.
Application stdout/stderr emitted before a failure remains visible. Test execution writes
results and summary to stdout; see the [test guide](examples/testing/README.md)
for failure precedence and command interruption. Panic writes `panic: ` followed by the
message bytes and a newline. Other detected failures use `runtime error: ` and
a fixed description. Static diagnostics include source location and UTF-8 byte
ranges. Paths are escaped to distinguish invalid bytes, newlines, and backslashes.
Source paths must be valid UTF-8. Symlinks and duplicate physical inputs are
rejected. Directories are traversed regardless of their suffix. Other `.mgn`
entries must be regular files; FIFOs, sockets, and devices are rejected before
reading. An empty directory named `ignored.mgn` is not a source input. If it
contains a source, its directory name must satisfy the namespace identifier rules.

Before v1.0.0, backwards compatibility is not guaranteed. The old Unit main, single-source
CLI, and `bin/mognitio` command are removed. Package registries, external
dependencies, and separate compilation are outside this version's scope.

## Test

```sh
sbcl --noinform --script scripts/test.lisp
git diff --check
sha256sum -c verification/SHA256SUMS
```

The full suite requires a non-root Linux amd64 host, Python 3, `strace`, the
`getfacl`/`setfacl` utilities, and permission to trace its own child processes. Test allocation and collection controls are
internal bindings, with no public CLI or environment-variable switches.
