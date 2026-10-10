# Binary ELF emitter

This Mognitio project constructs a small Linux amd64 executable from numeric
fields, instruction fragments, and a selected payload. It does not invoke the
Compiler's ELF writer, a C compiler, assembler, or linker.

Build and run from the repository root:

```sh
bin/mgn build examples/binary-emitter/mognitio.toml -o /tmp/emitter
/tmp/emitter /tmp/generated ascii 0 exec
/tmp/generated
```

Arguments are a new output path, `ascii` or `jp`, `0` or `7`, and `exec` or
`data`. ASCII output is `MGN` plus LF; Japanese output is the UTF-8 bytes for
`あ`, LF, and `1`. The fourth argument controls permission requests only.
The fixture selects the second choice for other payload/exit/mode strings;
it is a fixed workload, not a general command-line encoder.

Publication also runs on unverified environments; the
[certified profile](../../verification/v1.2.0-publication-profile.md) determines
which failed commits have a proven NotPublished result. Existing destinations
and actual mechanism failures return errors without replacement or a weaker
fallback.
The example exits 1 on construction/publication errors and 0 after success.
Generated executables retry interrupted/short writes and use exit 111 for
unexpected output failure.

Fields, code offsets, ELF assembly, and publication are separate modules.
`tests/v120-emitter.py` independently checks every output byte, mode, execution,
repeat determinism and both host/native emitters. Its optional `--userland`
arguments require prepared minimal root filesystems with empty `/emitter` and
`/output` mount points; toolchain binaries must be absent. The harness uses
non-root bubblewrap namespaces, umask 0022, a tmpfs output directory, and no
post-publication chmod or patching.
