# Experimental native compiler

This source project is the independent Mognitio 1.3 compiler, mgnc.
It is built using the fixed Mognitio 1.2 seed and is not included in the
regular Debian package, APT repository, or installer bundle.

## Build

Verify the seed bundle and its signed manifest before building:

- source commit: 284a9b59abd2231a6bb15fefb3455ba3fa3fc481
- bundle: mognitio-1.2.0-linux-amd64.tar.gz
- bundle SHA-256: 36bcd0f9c60236b8b92cae51ab60dcf63bb79344e359d1f62e7d595cfe01c31d
- build identity: 9a74ec7c6016995d40054fc9aa32dd407281ea176f98f9dec37e220f3a25e686
- signed manifest SHA-256: 5c57f02fcc8f23aa659d53c696faa64dae28f2539efd89dcda9db1d81d474a40

Run the verified seed launcher, with an explicit path, from the repository root:

~~~sh
/path/to/verified-seed/bin/mgn build compiler/mgnc/mognitio.toml -o /new/output/mgnc
~~~

## Use

~~~sh
/new/output/mgnc build path/to/source.mgn -o path/to/new-artifact
/new/output/new-artifact argument
~~~

The source profile is a single namespace with explicitly typed scalar helpers
and main. Main takes List<String> and returns Int; its argument list supports
direct length queries. Helpers operate on Int, Bool and Unit. Blocks, mutable
locals, direct calls, branches, while loops, and checked signed arithmetic are
compiled into standalone Linux AMD64 ELF executables.

The compiler validates every function before publishing a new executable.
It never replaces an existing output, invokes a fallback compiler, or runs the
generated program during compilation. Normal compiler output streams are empty.
The native runtime validates UTF-8 arguments and preserves primary failures
even when its diagnostic stream is unavailable.

Internal and end-to-end runners are under tests/mgnc. The 55-condition
[implementation acceptance](../../verification/v1.3.0-review.md) includes the completed
21-cell resource profile. Acceptance is separate from release and publication.

The seed's public Product/Sum types, templates, immutable lists and strings,
text I/O, numeric representation conversion and binary publication are the
only compiler dependencies. No seed-private runtime symbol is called.
