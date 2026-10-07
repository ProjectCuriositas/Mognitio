# Verification

The [1.1.0 native runtime record](v1.1.0-runtime.md) describes the free-list,
worklist, independent membership index, and their verification boundaries.

The [v0.14 review corrections](v0.14.0-review.md) cover first file close,
scalar root lifetime, and primary-phase guard verification.

The current implementation record is [v1.1.0](v1.1.0.md), with complete
[performance samples](v1.1.0-measurements.json). The retained [v0.14.0 record](v0.14.0.md) has its
[coverage ledger](v0.14.0-conformance.md). The inherited [v0.13.0 record](v0.13.0.md)
has a [42-condition ledger](v0.13.0-conformance.md) and [internal gates](v0.13.0-internals.md).
The [v0.13 review corrections](v0.13.0-review.md) cover directory mmap errno
classification and independent verification of internal-failure latch paths.
The [v0.12 review corrections](v0.12.0-review.md) cover repeated stdin consumption
and primary failure preservation across diagnostic and signal cleanup paths.
The retained v0.11 [72-case ledger](v0.11.0-testing.md) and
[process evidence](v0.11.0-process.md) describe the inherited runner.
The [runner review fixes](v0.11.0-review.md) cover host storage recovery,
helper frame-register preservation, and committed-result diagnostics.
The current release validation procedure is [v1.1.0](v1.1.0-release.md).
The retained stable release record is [v1.0.0](v1.0.0-release.md).
The retained source release record is [v0.14.0](v0.14.0-release.md).
Run checks from the repository root on a non-root Linux amd64 host with SBCL,
Python 3, glibc 2.34+, strace, getfacl/setfacl, and permission to trace child processes. The v0.13 different-group inheritance
fixture additionally requires membership in a supplementary group distinct
from the process effective GID; the owned fixture directory is assigned to it.

```sh
sbcl --noinform --script scripts/test.lisp
git diff --check
sha256sum -c verification/SHA256SUMS
```

[Test coverage](../tests/README.md) describes the active ASDF suite, migration,
independent oracles, and resource probes. Each failed assertion fails the run.

## CLI and native checks

```sh
./bin/mgn run examples/modules/mognitio.toml
./bin/mgn build examples/modules/mognitio.toml -o example
./example
```

All three commands succeed silently with exit 0. The suite checks ELF fields, standalone execution, deterministic
cold/warm caches, relocation, paths, and failures before and during publication.

Determinism uses source bytes, target, and compiler build identity.
Record the exact revision, manifest, SBCL/ASDF versions, and internal test options.
The [manifest](SHA256SUMS) covers delivered files except itself; it identifies
contents rather than proving that tests passed.

## Repository review

Include new files in review. Check changed Markdown links and fences, UTF-8,
LF endings, final newlines, executable launchers, and whitespace.
Follow [contribution guidelines](../CONTRIBUTING.md) and publish sanitized
evidence. Do not include private setup details in public records.

## Historical records

- [v0.13.0 release](v0.13.0-release.md)

- [v0.12.0 release](v0.12.0-release.md)
- [v0.11.0 release](v0.11.0-release.md)

- [v0.10.0 release](v0.10.0-release.md)
- [v0.9.0 initial source increment](v0.9.0-progress.md)
- [v0.8.1 release](v0.8.1-release.md)
- [v0.8.0 implementation](v0.8.0.md) and [release](v0.8.0-release.md)
- [v0.7.0 implementation](v0.7.0.md), [review](v0.7.0-review.md), and [release](v0.7.0-release.md)
- [v0.6.0](v0.6.0.md), [v0.5.0](v0.5.0.md), [v0.4.1](v0.4.1.md)
- [v0.4.0](v0.4.0.md), [v0.3.0](v0.3.0.md), [v0.2.0](v0.2.0.md)

Historical counts and old source oracles apply to their pinned revisions.
Version-branch completion does not authorize main integration, a tag, or release.

- [v0.15.1 package permissions](v0.15.1.md): archive modes and non-owner execution regression.
