"""Public host/native I/O observations, independent of runtime helper tables."""
from pathlib import Path
import subprocess
import tempfile
import os

ROOT = Path(__file__).resolve().parents[1]
checks = 0
with tempfile.TemporaryDirectory(prefix="mognitio-host-io-") as directory:
    base = Path(directory)
    (base / "src").mkdir()
    manifest = base / "mognitio.toml"
    manifest.write_text('[project]\nname="app"\nroot_namespace="App"\n')
    source = base / "src/app.mgn"
    imports = r"use Std\Io\{readTextFile,writeTextFile,readStdin,writeStdout,writeStderr,IoError,IoOperation,IoErrorKind};"
    def check(body, code=0, output=b"", stderr=b"", data=b"", prefix=imports):
        global checks
        source.write_text(f"namespace App; {prefix}\nlet main: Function(List<String>): Int = function(args:List<String>):Int {{ {body} }};\n")
        p = subprocess.run([ROOT / "bin/mgn", "run", manifest], input=data, capture_output=True, cwd=base, timeout=20)
        assert (p.returncode, p.stdout) == (code, output), (p.returncode, p.stdout, p.stderr)
        if stderr is not None:
            assert p.stderr == stderr, p.stderr
        checks += 1
        image = base / "app"
        build = subprocess.run([ROOT / "bin/mgn", "build", manifest, "-o", image], capture_output=True, timeout=20)
        assert build.returncode == (1 if code == 1 else 0), build.stderr
        assert not build.stdout
        checks += 1
        if build.returncode == 0:
            native = subprocess.run([image], input=data, capture_output=True, cwd=base, timeout=20)
            assert (native.returncode, native.stdout, native.stderr) == (code, output, stderr), (native.returncode, native.stdout, native.stderr)
            checks += 1

    check('discard writeStdout("A😀\\0\\r\\n"); discard writeStderr("B"); 0', output="A😀\0\r\n".encode(), stderr=b"B")
    check('let text:String=branch on readStdin(){Result<String,IoError>::Ok(x:String)=>x,Result<String,IoError>::Err=>panic{"stdin"}}; discard writeStdout(text); 0', data=b"\xef\xbb\xbfA\x00\r\n", output=b"\xef\xbb\xbfA\x00\r\n")
    check('discard writeTextFile("out.txt", "A😀\\0\\r\\n"); let value:String=branch on readTextFile("out.txt"){Result<String,IoError>::Ok(x:String)=>x,Result<String,IoError>::Err=>panic{"read"}}; discard writeStdout(value); 0', output="A😀\0\r\n".encode())
    assert (base / "out.txt").read_bytes() == "A😀\0\r\n".encode()
    (base / "bad.txt").write_bytes(b"\xed\xa0\x80")
    os.mkfifo(base / "fifo")
    for path, kind in [("", "InvalidPath"), ("bad.txt", "InvalidEncoding"), ("absent", "NotFound"), (".", "UnsupportedTarget"), ("fifo", "UnsupportedTarget")]:
        operations = ",".join(f"IoOperation::{name} => {'true' if name == 'ReadTextFile' else 'false'}" for name in ["ReadTextFile", "WriteTextFile", "ReadStdin", "WriteStdout", "WriteStderr"])
        kinds = ",".join(f"IoErrorKind::{name} => {'true' if name == kind else 'false'}" for name in ["InvalidPath", "InvalidEncoding", "NotFound", "PermissionDenied", "UnsupportedTarget", "BrokenPipe", "ResourceExhausted", "Other"])
        check(f'''assert branch on readTextFile("{path}") {{
            Result<String,IoError>::Ok => false,
            Result<String,IoError>::Err(error:IoError) => {{
                assert error->subject == "{path}";
                assert branch on error->operation {{ {operations} }};
                branch on error->kind {{ {kinds} }}
            }}
        }}; 0''')
    check('discard writeStdout("x"); 0', code=1, stderr=None, prefix="")
    check('0', code=1, stderr=None, prefix=r"use Std\Io\{unknown};")

print(f"v0.12 host/native I/O checks={checks} failures=0")
