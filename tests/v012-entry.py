"""Public entry/argument observations, independent of compiler helper tables."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MGN = ROOT / "bin/mgn"
checks = 0

def run(command, code=0, out=b"", err=None, **kwargs):
    global checks
    p = subprocess.run(command, capture_output=True, timeout=30, **kwargs)
    assert p.returncode == code, (command, p.returncode, p.stderr)
    assert p.stdout == out, (command, p.stdout)
    if err is not None:
        assert p.stderr == err, (command, p.stderr, err)
    checks += 1
    return p

with tempfile.TemporaryDirectory(prefix="mognitio-entry-") as area:
    base = Path(area)
    (base / "src").mkdir()
    manifest = base / "mognitio.toml"
    manifest.write_text('[project]\nname="app"\nroot_namespace="App"\n')
    source = base / "src/app.mgn"
    image = base / "app"
    def program(body, signature="Function(List<String>): Int", parameters="args: List<String>", result="Int"):
        source.write_text(f"namespace App; let main: {signature} = function({parameters}): {result} {{ {body} }};\n")

    program('''assert args->length() == 5;
        let first: String = branch on args->at(0) {
            Result<String, IndexError>::Ok(value: String) => value,
            Result<String, IndexError>::Err => panic { "missing" }
        }; assert first == "";
        let get:Function(Int):String=function(i:Int):String{branch on args->at(i){Result<String,IndexError>::Ok(s:String)=>s,Result<String,IndexError>::Err=>panic{"index"}}};
        assert get(1)=="日本😀";assert get(2)=="--";assert get(3)=="-o";assert get(4)=="x y";17''')
    args = [b"", "日本😀".encode(), b"--", b"-o", b"x y"]
    run([os.fsencode(MGN), b"run", os.fsencode(manifest), b"--", *args], code=17, err=b"")
    run([MGN, "build", manifest, "-o", image], err=b"")
    run([os.fsencode(image), *args], code=17, err=b"")
    for invalid in [b"\x80", b"\xc0\x80", b"\xed\xa0\x80", b"\xf4\x90\x80\x80", b"\xf0\x9f"]:
        run([os.fsencode(MGN), b"run", os.fsencode(manifest), b"--", invalid], code=2)
        run([os.fsencode(image), invalid], code=2)
    for result in [0, 1, 2, 3, 255, -1, 256]:
        program(str(result))
        code = result if 0 <= result <= 255 else 4
        err = b"" if code == result else b"runtime error: invalid exit status\n"
        run([MGN, "run", manifest], code=code, err=err)
        run([MGN, "build", manifest, "-o", image], err=b"")
        run([image], code=code, err=err)
    program("assert args->length()==0;0")
    run([MGN,"run",manifest],err=b"")
    run([MGN,"run",manifest,"--"],err=b"")
    run([MGN,"build",manifest,"-o",image],err=b"")
    run([image],err=b"")
    program("unit", signature="Function(): Unit", parameters="", result="Unit")
    run([MGN, "run", manifest], code=1)
    run([MGN, "build", manifest, "-o", image], code=1)
    for command in [["run", manifest, "arg"], ["test", manifest, "--"], ["build", manifest, "-o", image, "--"]]:
        run([MGN, *command], code=2)
    source.write_text("namespace App; this is invalid;\n")
    run([os.fsencode(MGN), b"run", os.fsencode(manifest), b"--", b"\xff"], code=1)

print(f"v0.12 entry checks={checks} failures=0")
