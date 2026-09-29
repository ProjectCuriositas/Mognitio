# Mognitio

Mognitio is a typed language with immutable data, persistent lists, explicit
contracts and generic templates, and first-class functions with snapshot captures.
The v0.10.0 version branch adds multiple modules within one project.

## Start here

- [Examples](examples/): executable projects, including [multiple modules](examples/modules/).
- [Test coverage](tests/README.md): current project cases and internal regression oracles.
- [Implementation verification](verification/v0.10.0.md): evidence and limits.
- [Verification commands](verification/README.md): reproduce the checks.
- [Contributing](CONTRIBUTING.md): public contribution conventions.

## Requirements and commands

The compiler host is Linux with SBCL, ASDF, UIOP, and SB-POSIX.
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
mgn build mognitio.toml -o app
./app
```

Compiler contributors can invoke the launcher directly from its checkout:

```sh
./bin/mgn run examples/modules/mognitio.toml
./bin/mgn build examples/modules/mognitio.toml -o example
./example
```

Normal execution returns silently with exit 0. Build also succeeds silently.
The generated Linux amd64 ELF needs no compiler, source, libc, dynamic loader,
or cache at runtime. Build checks all sources without executing initializers.

The arguments are `run <mognitio.toml>` and `build <mognitio.toml> -o <artifact>`.
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
`main` binding of type `Function(): Unit`:

```mgn
namespace App;
use App\Domain\{Page, Printable, PagePrintable, makePage};

let main: Function(): Unit = function(): Unit {
    let page: Page = makePage("Multiple modules");
    let printable: Printable = Printable(page);
    branch when {
        printable->text() == "Multiple modules" => unit,
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

## Results and failures

| Exit | Meaning |
|---|---|
| 0 | Successful run or build |
| 1 | Source, lexical, parse, name, or type error |
| 2 | Invocation, manifest, input path, or file I/O error |
| 3 | Internal compiler, execution, or bootstrap failure |
| 4 | Detected runtime failure or panic |

Runtime failures leave stdout empty. Panic writes `panic: ` followed by the
message bytes and a newline. Other detected failures use `runtime error: ` and
a fixed description. Static diagnostics include source location and UTF-8 byte
ranges. Paths are escaped to distinguish invalid bytes, newlines, and backslashes.
Source paths must be valid UTF-8. Symlinks and duplicate physical inputs are
rejected. Directories are traversed regardless of their suffix. Other `.mgn`
entries must be regular files; FIFOs, sockets, and devices are rejected before
reading. An empty directory named `ignored.mgn` is not a source input. If it
contains a source, its directory name must satisfy the namespace identifier rules.

Before v1.0.0, backwards compatibility is not guaranteed. The old single-source
CLI and `bin/mognitio` command are removed. Package registries, external
dependencies, and separate compilation are outside this version's scope.

## Test

```sh
sbcl --noinform --script scripts/test.lisp
git diff --check
sha256sum -c verification/SHA256SUMS
```

The full suite requires a non-root Linux amd64 host, Python 3, and permission
to trace its own child processes. Test allocation and collection controls are
internal bindings, with no public CLI or environment-variable switches.
