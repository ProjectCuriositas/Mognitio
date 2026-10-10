#!/usr/bin/env python3
"""Value argument identity through imports, CLI entry points and static analysis."""
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "bin/mgn"
checks = 0

def run(args, code=0, input=None):
    global checks
    result = subprocess.run([str(x) for x in args], input=input, capture_output=True, timeout=30)
    checks += 1
    assert result.returncode == code, (code, result.returncode, result.stderr)
    if code == 0:
        assert result.stderr == b"", result.stderr
    return result

with tempfile.TemporaryDirectory(prefix="mgn-value-arguments-") as temporary:
    root = Path(temporary)
    (root / "src/Lib").mkdir(parents=True)
    manifest = '[project]\nname="app"\nroot_namespace="App"\n'
    (root / "mognitio.toml").write_text(manifest)
    lib = """namespace App\\Lib;
public type Item<N: Int, T> = product { value: T; };
public alias Same<K: Int, V> = Item<K, V>;
public template keep<N: Int, T> = function(x: Item<N, T>): Item<N, T> { x };
"""
    source = """namespace App;
use App\\Lib\\{Item, Same, keep};
let main: Function(List<String>): Int = function(args: List<String>): Int {
    let x: Same<(-1), Int> = keep<-1, Int>(Item<-1, Int>{value: 7});
    branch when { x->value == 7 => 0, else => panic { "value argument" } }
};
@test let valueParameter: Function(): Unit = function(): Unit {
    assert keep<8, Int>(Item<8, Int>{value: 42})->value == 42;
};
"""
    (root / "src/Lib/item.mgn").write_text(lib)
    app = root / "src/app.mgn"
    app.write_text(source)
    assert run([CLI, "run", root / "mognitio.toml"]).stdout == b""
    run([CLI, "build", root / "mognitio.toml", "-o", root / "program"])
    assert run([root / "program"]).stdout == b""
    tested = run([CLI, "test", root / "mognitio.toml"])
    assert b"valueParameter" in tested.stdout, tested.stdout

    def analyze(text, complete):
        snapshot = {"root": str(root), "manifest": manifest,
                    "sources": {"src/app.mgn": text, "src/Lib/item.mgn": lib}}
        result = run(["sbcl", "--noinform", "--script", ROOT / "scripts/analysis-entry.lisp"],
                     input=json.dumps(snapshot).encode() + b"\n")
        data = json.loads(result.stdout)
        assert data["complete"] is complete, data
        return data

    # Analysis must not execute this initializer, even in the positive snapshot.
    data = analyze(source + '\nlet dormant: Int = panic { "must not execute" };', True)
    for path, text in (("src/app.mgn", source), ("src/Lib/item.mgn", lib)):
        raw = text.encode()
        for start, end, kind, modifiers in data["tokens"][path]:
            if end <= len(raw):
                assert raw[start:end] not in (b"-1", b"8", b"42", b"(-1)"), (raw[start:end], kind)
    for old, new in (("Same<(-1), Int>", "Same<1, Int>"),
                     ("keep<-1, Int>", "keep<Int, Int>"),
                     ("Same<(-1), Int>", "Same<-9223372036854775809, Int>")):
        bad = source.replace(old, new)
        app.write_text(bad)
        run([CLI, "run", root / "mognitio.toml"], 1)
        previous = (root / "program").read_bytes()
        run([CLI, "build", root / "mognitio.toml", "-o", root / "program"], 1)
        assert (root / "program").read_bytes() == previous
        run([CLI, "test", root / "mognitio.toml"], 1)
        analyze(bad, False)

print(f"VALUE_ARGUMENT_PROJECTS_OK checks={checks}")
