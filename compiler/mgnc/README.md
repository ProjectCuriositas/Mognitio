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

The scalar lexer, byte-span classifier, and explicit continuation parser have
internal test runners under tests/mgnc. They are not yet connected to semantic
analysis or native generation. The current driver intentionally exits with an internal diagnostic until
the compiler pipeline is connected. It does not emit a placeholder artifact.
The public command will be mgnc build source.mgn -o new-artifact.

The seed's public Product/Sum types, templates, immutable lists and strings,
text I/O, numeric representation conversion and binary publication are the
only compiler dependencies. No seed-private runtime symbol is called.
