"""Real filesystem, UTF-8, startup and signal observations for both backends."""
from pathlib import Path
import os
import resource
import shutil
import signal
import stat
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "bin/mgn"
checks = 0
KINDS = ["InvalidPath", "InvalidEncoding", "NotFound", "PermissionDenied", "UnsupportedTarget", "BrokenPipe", "ResourceExhausted", "Other"]
IMPORT = r"use Std\Io\{readTextFile,writeTextFile,readStdin,writeStdout,writeStderr,IoError,IoErrorKind,IoOperation};"

def process(args, code=0, out=b"", err=b"", **kwargs):
    global checks
    p = subprocess.run(args, capture_output=True, timeout=30, **kwargs)
    assert (p.returncode, p.stdout) == (code, out), (args, p.returncode, p.stdout, p.stderr)
    if err is not None:
        assert p.stderr == err, (args, p.stderr, err)
    checks += 1
    return p

def limit_one():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    resource.setrlimit(resource.RLIMIT_FSIZE, (1, 1))
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    signal.signal(signal.SIGXFSZ, signal.SIG_DFL)

with tempfile.TemporaryDirectory(prefix="mgn-v012-files-") as temporary:
    base = Path(temporary)
    project = base / "project"
    (project / "src").mkdir(parents=True)
    manifest = project / "mognitio.toml"
    manifest.write_text('[project]\nname="app"\nroot_namespace="App"\n')
    source = project / "src/app.mgn"
    image = project / "app"
    def build(body, prefix=IMPORT):
        source.write_text(f"namespace App; {prefix}\nlet main:Function(List<String>):Int=function(args:List<String>):Int{{{body}}};")
        process([CLI, "build", manifest, "-o", image])
    def commands(args=()):
        return [[CLI, "run", manifest, "--", *args], [image, *args]]
    get = 'let get:Function(Int):String=function(i:Int):String{branch on args->at(i){Result<String,IndexError>::Ok(s:String)=>s,Result<String,IndexError>::Err=>panic{"argument"}}};'
    kinds = ",".join(f"IoErrorKind::{name}=>{i}" for i, name in enumerate(KINDS))
    build(get + '''let input:String=get(0);let output:String=get(1);
      let copy:Function():Result<Unit,IoError>=function():Result<Unit,IoError>{
        let text:String=try readTextFile(input);try writeTextFile(output,text);Result<Unit,IoError>::Ok(unit)};
      branch on copy(){Result<Unit,IoError>::Ok=>0,Result<Unit,IoError>::Err(e:IoError)=>{
        let operation:Int=branch on e->operation{IoOperation::ReadTextFile=>{assert e->subject==input;100},IoOperation::WriteTextFile=>{assert e->subject==output;200},IoOperation::ReadStdin=>panic{"op"},IoOperation::WriteStdout=>panic{"op"},IoOperation::WriteStderr=>panic{"op"}};
        operation + branch on e->kind{''' + kinds + '}}}')
    # Each execution owns a fresh fixture: no second backend observes prior writes.
    serial = 0
    def fixture():
        global serial
        serial += 1
        path = base / str(serial)
        path.mkdir()
        return path
    valid = [b"", b"ASCII", b"line\n", b"\xef\xbb\xbf\r\n\0", "日本😀".encode(), chr(0x10ffff).encode()]
    for scalar in ["¢", "あ", "😀"]:
        for boundary in range(1, len(scalar.encode())):
            valid.append(b"x" * (4096 - boundary) + scalar.encode() + b"y" * 4100)
    for data in valid:
        for command in commands(["in", "out"]):
            cwd = fixture(); (cwd / "in").write_bytes(data); (cwd / "out").write_bytes(b"long previous content")
            process(command, cwd=cwd)
            assert (cwd / "out").read_bytes() == data
    invalid = [b"\x80", b"\xc0\x80", b"\xc1\xbf", b"\xe0\x80\x80", b"\xed\xa0\x80", b"\xf0\x80\x80\x80", b"\xf4\x90\x80\x80", b"\xf5\x80\x80\x80", b"\xfe", b"\xff", b"\xc2", b"\xe2\x82", b"\xf0\x9f\x98"]
    for data in invalid:
        for command in commands(["in", "out"]):
            cwd = fixture(); (cwd / "in").write_bytes(b"x" * 4095 + data)
            process(command, 101, cwd=cwd)
            assert not (cwd / "out").exists()
    for args, code in [(["", "out"], 100), (["absent", "out"], 102), (["in", "missing/out"], 202), (["in", ""], 200), (["directory", "out"], 104), (["fifo", "out"], 104), (["in", "fifo"], 204), (["in", "directory"], 204)]:
        for command in commands(args):
            cwd = fixture(); (cwd / "in").write_bytes(b"data"); (cwd / "directory").mkdir(); os.mkfifo(cwd / "fifo")
            process(command, code, cwd=cwd)
    assert os.geteuid() != 0, "Permission cases require a non-root test user"
    for inaccessible in ["file", "search"]:
        for command in commands(["blocked" if inaccessible == "file" else "blocked/in", "out"]):
            cwd = fixture(); blocked = cwd / "blocked"
            if inaccessible == "file": blocked.write_bytes(b"data")
            else: blocked.mkdir(); (blocked / "in").write_bytes(b"data")
            blocked.chmod(0)
            try: process(command, 103, cwd=cwd)
            finally: blocked.chmod(0o700)
    for mask, existing, expected in [(0o022, False, 0o644), (0o077, False, 0o600), (0o022, True, 0o600)]:
        for command in commands(["in", "out"]):
            cwd = fixture(); (cwd / "in").write_bytes(b"mode")
            acl = subprocess.check_output(["getfacl", "-cp", cwd])
            assert b"default:" not in acl
            if existing: (cwd / "out").write_bytes(b"old"); (cwd / "out").chmod(0o600)
            process(command, cwd=cwd, preexec_fn=lambda: os.umask(mask))
            assert stat.S_IMODE((cwd / "out").stat().st_mode) == expected
    for command in commands(["in", "out"]):
        cwd = fixture(); (cwd / "in").write_bytes(b"acl")
        subprocess.run(["setfacl", "-m", "d:u::rw-,d:g::rw-,d:o::---", cwd], check=True)
        process(command, cwd=cwd, preexec_fn=lambda: os.umask(0o077))
        assert stat.S_IMODE((cwd / "out").stat().st_mode) == 0o660
    for link in ["symlink", "hardlink", "same"]:
        for command in commands(["in", "alias"]):
            cwd = fixture(); (cwd / "in").write_bytes(b"same physical file")
            if link == "symlink": (cwd / "alias").symlink_to("in")
            elif link == "hardlink": os.link(cwd / "in", cwd / "alias")
            else: command[-1] = "in"
            process(command, cwd=cwd)
            assert (cwd / "in").read_bytes() == b"same physical file"
    for command in commands([" -[*] ", "out"]):
        cwd = fixture(); (cwd / " -[*] ").write_bytes(b"literal")
        process(command, cwd=cwd)
        assert (cwd / "out").read_bytes() == b"literal"
    # One artifact re-reads data and runs after source and manifest disappear.
    detached = base / "detached"; shutil.copy2(image, detached)
    for value in [b"first", b"second"]:
        cwd = fixture(); (cwd / "in").write_bytes(value)
        process([detached, "in", "out"], cwd=cwd, env={"PATH": "/nonexistent"})
        assert (cwd / "out").read_bytes() == value
    # Real file-size limit: short progress, then EFBIG, with explicit default signals.
    for command in commands(["in", "out"]):
        cwd = fixture(); (cwd / "in").write_bytes(b"AB")
        process(command, 207, cwd=cwd, preexec_fn=limit_one)
        assert (cwd / "out").read_bytes() == b"A"
    for operation, endpoint in [("writeStdout", 1), ("writeStderr", 2)]:
        build(f'discard {operation}("AB");0')
        # Warm CL cache before imposing a limit on the isolated process.
        process([CLI, "run", manifest], out=b"AB" if endpoint == 1 else b"", err=b"AB" if endpoint == 2 else b"")
        for command in commands():
            cwd = fixture(); output = cwd / "redirect"
            with output.open("wb") as stream:
                p = subprocess.run(command, stdout=stream if endpoint == 1 else subprocess.PIPE,
                                   stderr=stream if endpoint == 2 else subprocess.PIPE,
                                   preexec_fn=limit_one, timeout=30)
            assert p.returncode == 0, p.returncode
            assert output.read_bytes() == b"A"
            checks += 1
        for command in commands():
            readfd, writefd = os.pipe(); os.close(readfd)
            try:
                p = subprocess.run(command, stdout=writefd if endpoint == 1 else subprocess.PIPE,
                                   stderr=writefd if endpoint == 2 else subprocess.PIPE, timeout=30)
            finally: os.close(writefd)
            assert p.returncode == 0, (p.returncode, p.stderr)
            checks += 1

print(f"v0.12 filesystem/signal checks={checks} failures=0")
