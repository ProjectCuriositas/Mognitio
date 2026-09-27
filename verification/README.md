# Verification

Run these commands from the repository root. SBCL must be available on
`PATH`. The full suite requires a non-root Linux amd64 environment, bundled
SB-POSIX, Python 3, and permission to ptrace its own children.

## Automated tests

```sh
sbcl --noinform --script scripts/test.lisp
```

This invokes `asdf:test-system "mognitio"` and runs both unit and subprocess
tests. The summary reports test groups, assertions, child processes, and
failures. Any failure causes a nonzero exit.

The [test coverage matrix](../tests/README.md) describes the cases, including
strict source decoding, nested expressions, error classification, literal
paths, output isolation, and cold/warm compiler caches.

To repeat the complete suite with an isolated compiler cache:

```sh
(
    cache=$(mktemp -d) || exit 1
    trap 'rm -rf -- "$cache"' EXIT
    XDG_CACHE_HOME="$cache" ASDF_OUTPUT_TRANSLATIONS= CL_SOURCE_REGISTRY= \
        sbcl --noinform --script scripts/test.lisp
)
```

The temporary directory belongs to this invocation. Existing caches are
preserved.

## Command-line checks

```sh
./bin/mgn run examples/true.mgn
./bin/mgn run examples/false.mgn
./bin/mgn run examples/nested.mgn
```

The expected results are `true`, `false`, and `true`, respectively.
Each command must print exactly one result line, leave stderr empty, and
exit with status 0.

Subprocess tests independently capture stdout, stderr, and exit status for
source failures (1), invocation or I/O failures (2), internal failures (3), and evaluated integer failures (4).
Internal faults are injected through a test-only entry, not public CLI options.

## Native checks

```sh
./bin/mgn build --target linux/amd64 --output example examples/nested.mgn
./example
readelf -h -l example
```

Build must leave both output streams empty and exit 0. Execution prints
`true` and exits 0. `readelf` is an optional inspection tool, never part of
code generation. The automated suite checks the ELF fields independently.

Determinism is defined by source bytes, target, and compiler build/revision
identity. Matching semantic versions alone does not establish matching
identities. Record the revision, content manifest (including uncommitted
changes), SBCL/ASDF versions, and any code-generation configuration.
Paths, timestamps, process IDs, and cache contents are not embedded in the
executable. See the [v0.8.0 release validation](v0.8.0-release.md) for the current release.
The [v0.6.0 validation](v0.6.0.md) and [development progress](v0.6.0-progress.md)
remain historical records.
The [v0.5.0](v0.5.0.md), [v0.4.1](v0.4.1.md), [v0.4.0](v0.4.0.md), and
[v0.3.0](v0.3.0.md) validation records remain historical.

The [v0.7.0 development validation](v0.7.0.md) covers immutable nominal data,
unified branches, interfaces, graph collection, and ABI v4. Integration into
the version branch does not create a release.
The [follow-up review validation](v0.7.0-review.md) covers the current interface
requirement spelling, isolated rejection fixtures, reused payload initialization,
and implementation-table layout order.

The [v0.8.0 development validation](v0.8.0.md) covers explicit generics,
Result propagation and block panic. The source acceptance evidence can be
reproduced with `python3 scripts/verify-v08.py --output /tmp/v08-results.json`.
This supplements the cumulative suite and does not create a release.

## Repository checks

- Run `git diff --check` for whitespace errors.
- Include newly added files in the review; ordinary diffs omit untracked files.
- Check Markdown relative links and code fences.
- Keep source files UTF-8 with LF line endings and a final newline.
- Preserve the executable bit on `bin/mgn`.

The [checksum manifest](SHA256SUMS) identifies the current source snapshot,
excluding the manifest itself. Verify it from the repository root:

```sh
sha256sum -c verification/SHA256SUMS
```

Regenerate the manifest whenever a delivered file changes. Checksums identify
file contents; they do not independently prove that tests passed.

## Reporting results

Report the commands used, outcomes, and relevant unverified behavior in English.
Follow the [contribution guidelines](../CONTRIBUTING.md) when preparing public
logs and pull requests. Do not publish local setup details or session records.

Generated programs cover bounded samples, not every possible nesting depth.
The test bound is not a language limit. Operating-system termination,
uncatchable resource exhaustion, and simultaneous filesystem changes by other processes
are outside the guarantees established by the test suite. Native broken-output
handling is tested separately from successful delivery.

## v0.9.0 development

The [progress record](v0.9.0-progress.md) separates the implemented source and
lexer increment from the remaining frontend, runtime, and native migration.
The cumulative test suite still covers the retained v0.8.1 implementation.
