# Linux toolchain distribution

The standard payload contains the compiler, shared frontend and standard
catalog in a saved Lisp core, a pinned SBCL executable, and the stdio language
server. It does not consult a host SBCL installation, ASDF cache, or user init
file when launched. Ubuntu 24.04 and 26.04 amd64 are the supported userlands.
Python 3.12 or later, glibc, libzstd1, and util-linux are OS dependencies.

## Build an immutable payload

Use the runtime, input core, copyright notice, and Ubuntu image digest in
[build-lock.json](build-lock.json). The release mode checks every locked digest.
Build inside that Ubuntu image with a clean checkout and an empty HOME.
Development builds may use other explicit runtime inputs and embed their full
identity rather than claiming a formal release.

Invoke scripts/build-toolchain.py with --runtime, --core, --runtime-notice,
--image-digest, and --output. Use --mode release only for an intentional formal
candidate from a clean source tree; the default is development.
The script prints the immutable payload directory. Add its bin directory to
PATH or invoke bin/mgn and bin/mognitio-lsp directly.

Both tools accept --version. The server accepts --stdio. CLI run/build/test
commands remain unchanged. The source checkout's older bin/mgn is a contributor
bootstrap and does not provide a built toolchain identity; use a generated
payload for version and LSP acceptance.

VERSION is the upstream release version. Development versions additionally
identify the full commit, source digest, dirty state, and complete build
fingerprint. Artifact checksums are recorded after generation separately from
the build fingerprint. Never replace an immutable published release.

## Package and verify

Run scripts/package-toolchain.py PAYLOAD --output OUTPUT to create a Debian
package, offline archive, and manifest.json from one verified release payload.
The Debian revision is separate from the upstream toolchain version.
Packaging exports directories as 0755, executable files as 0755, and data as
0644, regardless of the build umask or private staging directory modes. The
source payload remains unchanged. Validate system packages as an unprivileged
user after root installation; execution as the installing root user is not
sufficient to detect inaccessible payload directories.

Sign the manifest with the independently managed bundle signing subkey.
Before extracting or executing an offline installer, use scripts/verify-bundle.py
with --manifest, --signature, --keyring, and --fingerprint. Obtain the public key
and full fingerprint from the reviewed [APT key record](https://github.com/ProjectCuriositas/apt#production-public-key);
a key supplied by the archive itself is not sufficient trust. GitHub and Pages
share an account authority; an independent trust channel is not yet available.
This checks signature and artifact hashes, not current revocation status.
Refresh trust information before installing; stale offline keyrings cannot
establish that a key has not since been revoked.

No production signing key, repository URL, or official release is created by
these scripts. Do not substitute test keys or fixture URLs into public setup
instructions.

## Offline user installation

After external verification, extract the archive, then run its install.sh with
--prefix PATH. The default is ~/.local; do not use sudo. --version VERSION
requires the exact formal version contained in the bundle. Both programs are
exposed under PREFIX/bin, which the installer prints for PATH setup.

The installer locks the prefix, validates payload and ownership, stages an
immutable generation, and atomically switches the active generation. Interrupted
operations are recovered on the next invocation. Repeating the same verified
version is a no-op; downgrades and a different build of the same version are
rejected. Previous generations are retained for existing processes.

Use the printed PREFIX/lib/mognitio/uninstall.sh command even after removing the
downloaded archive. Only unchanged recorded files are removed. Modified files
and unrelated user data are retained; partial removal returns status 2.
Do not manually replace managed files or ownership metadata.

## APT staging

scripts/apt-repository.py --output NEW_DIRECTORY --signing-key APT_SUBKEY DEB...
creates a signed stable/main amd64 repository tree. It requires dpkg-scanpackages,
apt-ftparchive, and GnuPG. Use a signing subkey separate from bundle signing.
The script stages files without uploading them.

The official repository must be published and its key independently authenticated
before users can register it with signed-by and run sudo apt install mognitio.
APT verifies signed repository metadata and package hashes. Do not use trusted=yes
or allow-unauthenticated. Removing or purging this package leaves user projects
and independently installed user-prefix toolchains intact.

A language server session retains its verified payload so it can reanalyze after
APT reclaims an older installation. Restart the server to select a new toolchain.
The selected executable path determines the running version; another mgn on PATH
may belong to a different installation.

## Release signing environment

An owner registers the separately exported encrypted bundle subkey with
scripts/register-bundle-key.py /path/to/online-transfer after checking the public
fingerprints against the offline record. Enter the passphrase in the local
terminal only. The script rejects primary secret material and other subkeys,
verifies the passphrase through a temporary signature, and registers only
BUNDLE_SIGNING_KEY and BUNDLE_SIGNING_PASSPHRASE in the release-signing environment.

Prepare immutable draft release assets and record manifest.json's SHA-256.
Dispatch the Sign frozen release manifest workflow on main with that digest.
The version tag must name the exact main commit. The workflow verifies the
frozen artifact set and attaches only manifest.json.asc to the draft; publishing
the release is a separate action after final verification.
