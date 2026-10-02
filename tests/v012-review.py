"""Repeated stdin reads and startup diagnostics through both public backends."""
from pathlib import Path
import os
import resource
import signal
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "bin/mgn"
checks = 0


def expect(command, code=0, out=b"", err=b"", **kwargs):
    global checks
    p = subprocess.run(command, stdout=subprocess.PIPE, timeout=30, **kwargs)
    assert (p.returncode, p.stdout) == (code, out), (p.returncode, p.stdout, p.stderr)
    if err is not None:
        assert p.stderr == err, p.stderr
    checks += 1
    return p


def default_signals():
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    signal.signal(signal.SIGXFSZ, signal.SIG_DFL)


def limited_file():
    default_signals()
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    resource.setrlimit(resource.RLIMIT_FSIZE, (1, 1))


with tempfile.TemporaryDirectory(prefix="mognitio-review-") as directory:
    base = Path(directory)
    (base / "src").mkdir()
    manifest = base / "mognitio.toml"
    manifest.write_text('[project]\nname="app"\nroot_namespace="App"\n')
    source = base / "src/app.mgn"
    image = base / "app"
    kinds = ["InvalidPath", "InvalidEncoding", "NotFound", "PermissionDenied",
             "UnsupportedTarget", "BrokenPipe", "ResourceExhausted", "Other"]
    source.write_text(r'''namespace App;
use Std\Io\{readStdin, writeStdout, IoError, IoErrorKind};
let main:Function(List<String>):Int=function(args:List<String>):Int{
    assert branch on readStdin(){
        Result<String,IoError>::Ok=>false,
        Result<String,IoError>::Err(e:IoError)=>branch on e->kind{'''
        + ",".join(f"IoErrorKind::{kind}=>{'true' if kind == 'InvalidEncoding' else 'false'}" for kind in kinds)
        + r'''}};
    branch on readStdin(){
        Result<String,IoError>::Ok(rest:String)=>{discard writeStdout(rest);0},
        Result<String,IoError>::Err=>9
    }
};''')
    expect([CLI, "build", manifest, "-o", image], stderr=subprocess.PIPE)
    # A regular file makes read progress deterministic. Use fresh open positions
    # per backend; a pipe may independently choose short reads on each run.
    for position, invalid, failure_offset in [(8192, b"\xff", 0), (9000, b"\xff", 0),
                                               (20000, b"\xff", 0), (8191, b"\xe2(\xa1", 1)]:
        data = b"A" * position + invalid + b"B" * 20000
        consumed = ((position + failure_offset) // 4096 + 1) * 4096
        remaining = b"B" * (len(data) - consumed)
        path = base / "stdin"
        path.write_bytes(data)
        for command in [[CLI, "run", manifest], [image]]:
            with path.open("rb") as stream:
                expect(command, out=remaining, stdin=stream, stderr=subprocess.PIPE)
                assert stream.tell() == len(data)

    source.write_text(r'''namespace App; use Std\Io\{writeTextFile};
let initialized:Unit={discard writeTextFile("initialized", "I");unit};
let main:Function(List<String>):Int=function(args:List<String>):Int{
    initialized; discard writeTextFile("called", "M");0
};''')
    expect([CLI, "build", manifest, "-o", image], stderr=subprocess.PIPE)
    # Warm the host compiler cache before imposing an OS file-size limit.
    expect([CLI, "run", manifest], cwd=base, stderr=subprocess.PIPE)
    assert (base / "initialized").read_bytes() == b"I"
    assert (base / "called").read_bytes() == b"M"
    (base / "initialized").unlink()
    (base / "called").unlink()
    commands = [[CLI, "run", manifest, "--", b"\xff"], [image, b"\xff"]]
    for command in commands:
        normal = expect(command, code=2, err=None, cwd=base, stderr=subprocess.PIPE)
        assert normal.stderr
        path = base / "stderr"
        with path.open("wb") as stream:
            expect(command, code=2, err=None, cwd=base, stderr=stream, preexec_fn=limited_file)
        assert path.read_bytes() == normal.stderr[:1]
        readfd, writefd = os.pipe()
        os.close(readfd)
        try:
            expect(command, code=2, err=None, cwd=base, stderr=writefd, preexec_fn=default_signals)
        finally:
            os.close(writefd)
        expect(command, code=2, err=None, cwd=base, stderr=subprocess.PIPE,
               preexec_fn=lambda: os.close(2))
        with open("/dev/full", "wb", buffering=0) as stream:
            expect(command, code=2, err=None, cwd=base, stderr=stream)
        assert not (base / "initialized").exists()
        assert not (base / "called").exists()

print(f"v0.12 review checks={checks} failures=0")
