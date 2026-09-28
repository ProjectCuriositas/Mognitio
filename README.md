# Mognitio

Mognitio is a typed language with immutable data, persistent lists, explicit
contracts and generic templates, and first-class functions with snapshot captures.
This is the v0.9.0 source distribution for Linux amd64.

## Start here

- [Examples](examples/): small programs using the current language.
- [Test coverage and migration](tests/README.md): current and historical fixtures.
- [Release validation](verification/v0.9.0-release.md): pinned candidate and release checks.
- [Implementation verification](verification/v0.9.0.md): evidence and limits.
- [Verification commands](verification/README.md): reproduce the checks.
- [Contributing](CONTRIBUTING.md): public contribution conventions.

## Requirements and commands

The compiler host is Linux with SBCL, ASDF, UIOP, and SB-POSIX.
No Quicklisp, external compiler, assembler, or linker is required.

```sh
./bin/mognitio run examples/collections.mgn
./bin/mognitio build examples/collections.mgn -o example
./example
```

Run and native execution print a Boolean result and one newline.
Build succeeds silently. The generated Linux amd64 ELF needs no compiler,
source, libc, dynamic loader, or cache at runtime.

The canonical arguments are `run <source>` and `build <source> -o <artifact>`.
There is no required source suffix. Relative paths use the caller's directory;
prefix a filename starting with `-` with `./`.
The output parent must exist. Source/output aliases and non-regular output
files, including output symlinks, are rejected.

Build writes, closes, and verifies a temporary image before atomic replacement.
Precommit failures preserve the old artifact. A rename I/O error with an
unknown replacement outcome is reported as such.

## A small program

```mgn
template reader<T> = function(value: T): Function(): T {
    function(): T { value }
};
var readers: List<Function(): Int> = List<Function(): Int>[];
loop over (List<Int>[1, 2, 3] as value: Int) {
    readers = readers->append(reader<Int>(value));
};
var total: Int = 0;
loop over (readers as read: Function(): Int) {
    total = total + read();
};
total == 6
```

Bindings and parameters declare their types. `let` is immutable; `var`
permits exact-type rebinding. Functions retain values captured at creation.
A returned function or a value stored in a container remains usable.

`product` and `sum` create nominal types; `alias` preserves identity.
Contract values require explicit packaging backed by a `witness ... implements ...`
declaration. Templates require explicit type arguments. See
[contracts](examples/data-contract.mgn) and [results](examples/results.mgn).

`List<T>` is persistent: append returns a new list. Length is constant time,
append performs constant structural work, indexing is linear, and a complete
traversal prepares one forward buffer in linear time. Allocator, GC, and loop
body costs are separate. Indexing and String slicing return `Result`
values for invalid bounds.

## Results and failures

| Exit | Meaning |
|---|---|
| 0 | Successful run or build |
| 1 | Source, lexical, parse, name, or type error |
| 2 | Invocation or file I/O error |
| 3 | Internal compiler, execution, or bootstrap failure |
| 4 | Detected runtime failure or panic |

Runtime failures leave stdout empty. Panic writes `panic: `
followed by the message bytes and a final newline. Other detected failures use
`runtime error: `
and a fixed description. Bounds errors are ordinary Result values.
Diagnostics for static errors include source location and UTF-8 byte ranges.

## Test

```sh
sbcl --noinform --script scripts/test.lisp
git diff --check
sha256sum -c verification/SHA256SUMS
```

The full suite requires a non-root Linux amd64 host, Python 3, and permission
to trace its own child processes. Test allocation and collection controls are
internal bindings, with no public CLI or environment-variable switches.

## Loops and members

Unconditional loops return their explicit break value:

```mgn
let answer: Int = loop { break 42; };
answer == 42
```

Use `break unit;` for a Unit result; a loop without a normal break has no
normal result. While/over loops produce Unit and accept only plain `break;`.
All value members use `->`: fields, Function field calls, type operations,
and contract dispatch. Declare evidence with
`witness Concrete implements Contract { ... }`.
The identifier `_` is an ordinary name; use `discard expression;` to
discard a non-Unit value, or omit an unused payload binder.
