#!/usr/bin/env python3
"""Independent CLI, discovery, assertion and process-output conformance."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

CLI = Path(__file__).resolve().parents[1] / "bin/mgn"
checks = 0
covered = set()


def command(args, code=0, contains=(), empty=False):
    global checks
    result = subprocess.run([str(x) for x in args], capture_output=True, timeout=30)
    checks += 1
    assert result.returncode == code, (args, code, result.returncode, result.stdout, result.stderr)
    for fragment in contains:
        assert fragment.encode() in result.stdout + result.stderr, (fragment, result.stdout, result.stderr)
    if empty:
        assert not result.stdout, result.stdout
        assert b"tests:" not in result.stderr, result.stderr
    if code == 0:
        assert not result.stderr, result.stderr
    return result


def test(root, code=0, total=1, passed=None, failed=0, errors=0, contains=(), ids=()):
    covered.update(ids)
    r = command([CLI, "test", root / "mognitio.toml"], code, contains, code in (1, 2, 3))
    if code not in (1, 2, 3):
        if passed is None:
            passed = total - failed - errors
        expected = f"tests: total={total} passed={passed} failed={failed} errors={errors} aborted=0 not_run=0\n"
        assert r.stdout.endswith(expected.encode()), (expected, r.stdout)
        assert r.stdout.count(b"tests:") == 1
    return r


def declaration(name="check", body="assert true;", prefix="@test "):
    if name == "main" and prefix == "":
        return f"let main: Function(List<String>): Int = function(args: List<String>): Int {{ {body if body != 'unit' else ''} 0 }};"
    return f"{prefix}let {name}: Function(): Unit = function(): Unit {{ {body} }};"


with tempfile.TemporaryDirectory(prefix="mgn-v011-cli-") as temporary:
    base = Path(temporary)
    serial = 0

    def project(files, name="app", namespace="App"):
        global serial
        serial += 1
        root = base / str(serial)
        (root / "src").mkdir(parents=True)
        (root / "mognitio.toml").write_text(f'[project]\nname="{name}"\nroot_namespace="{namespace}"\n')
        for name, source in files.items():
            p = root / "src" / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(source if isinstance(source, bytes) else source.encode())
        return root

    def one(source, **options):
        return project({"app.mgn": "namespace App; " + source}, **options)

    main = declaration("main", "unit", "")
    test(one('// @test\nlet text:String="@test";' + declaration("test_check", prefix="")
             + declaration("check_test", prefix="")), total=0, ids=["A01", "A03"])
    test(project({"test_checks_test.mgn": "namespace App; " + main}), total=0, ids=["A04"])
    for name in ["ordinary", "renamed", "test"]:
        test(one(declaration(name)), contains=["::" + name], ids=["A02"])
    for name in ["unknown", "Test", "deprecated"]:
        test(one(declaration(prefix="@" + name + " ")), 1, contains=["semantic:"], ids=["A05"])
    test(one(declaration(prefix="@test @test ")), 1,
         contains=["Duplicate", "First attribute", "semantic:"], ids=["A06"])
    for prefix in ['@test() ', '@test("label") ', 'public @test ', '#[test] ']:
        test(one(declaration(prefix=prefix)), 1, contains=["parse:"], ids=["A07", "A08"])
    test(one("@test"), 1, contains=["parse:"], ids=["A08"])
    for target in ["var x:Int=1;", "type X=product{};", "alias X=Int;", "contract X{}",
                   "template x<T>=function(v:T):T{v};",
                   "witness P=X implements C{}"]:
        preamble = "type X=product{};contract C{}" if target.startswith("witness") else ""
        test(one(preamble + "@test " + target), 1, contains=["semantic:", "Invalid attribute target"], ids=["A09"])
    test(one(declaration(body=declaration("nested"))), 1, contains=["semantic:"], ids=["A10"])
    for source in ["let x:Int=@test 1;", "let f:Function(Int):Int=function(@test x:Int):Int{x};",
                   "type X=product{@test value:Int;};", "contract X{@test get(self:Self):Int;}"]:
        test(one(source), 1, contains=["parse:"], ids=["A11"])
    test(one(declaration(prefix="@ // before name\n test // before visibility\npublic\n")), ids=["A12", "T01"])
    for type_, value in [("Int", "1"), ("Function():Bool", "function():Bool{true}"),
                          ("Function(Int):Unit", "function(x:Int):Unit{unit}"),
                          ("Function():Result<Int,Int>", "function():Result<Int,Int>{Result<Int,Int>::Err(1)}")]:
        test(one(f"@test let check:{type_}={value};"), 1, contains=["type:", "actual " + type_.replace(":", ": ").replace(",", ", ")], ids=["T02"])
    test(one("alias Check=Function():Unit; @test let check:Check=function():Unit{assert true;};"), ids=["T03"])
    factory = "let make:Function(Int):Function():Unit=function(n:Int):Function():Unit{function():Unit{assert n==42;}};"
    test(one(factory + "@test let check:Function():Unit=make(42);"), ids=["T04"])
    template = "template make<T>=function(value:T):Function():Unit{function():Unit{assert true;}};"
    test(one(template + "@test let check:Function():Unit=make<Int>(42);"), ids=["T04", "S11"])
    root = project({"a.mgn": "namespace App; " + declaration("first", prefix="@test public "),
                    "b.mgn": "namespace App; use App\\{first as imported}; let copy:Function():Unit=imported;",
                    "c.mgn": "namespace App; use App\\{first as another}; let copy:Function():Unit=another;"})
    test(root, ids=["T05", "D04"])
    test(one(declaration("first") + "@test let second:Function():Unit=first;"), total=2, ids=["T06"])
    for source in [declaration(body="check();"), declaration(body="discard later;") + "let later:Int=1;"]:
        test(one(source), 1, ids=["T07"])
    test(project({"a.mgn": "namespace App; let value:Int=1;",
                  "b.mgn": "namespace App; use App\\{value}; " + declaration()}), 1, ids=["T08"])

    for body in ["assert true;", "var n:Int=0; assert {n=n+1; n==1}; assert n==1;",
                 'assert true || panic {"unreachable"}; assert !(false && panic {"unreachable"});',
                 'assert {return unit;};',
                 'loop while(true){assert {break;};};',
                 'var n:Int=0;loop while(n<2){n=n+1; assert {continue;};};assert n==2;',
                 'let nested:Function():Unit=function():Unit{assert true;};nested();']:
        root = one(declaration(body=body) + declaration("main", "check();", ""))
        test(root, ids=["S01", "S04", "S05", "S08", "S11", "S12"])
        command([CLI, "run", root / "mognitio.toml"])
        command([CLI, "build", root / "mognitio.toml", "-o", root / "program"])
        command([root / "program"])
    test(one(declaration(body='assert false; panic {"not run"};')), 5, failed=1, ids=["S02"])
    for body in ['assert 1;', 'assert "x";']:
        root = one(declaration(body=body) + main)
        test(root, 1, contains=["type:", "assert requires Bool; actual"], ids=["S03", "D10"])
        command([CLI, "build", root / "mognitio.toml", "-o", root / "program"], 1, ["type:"], True)
    for body, kind in [('assert panic {"stop"};', "panic"), ("assert 1/0==0;", "division-by-zero"),
                       ("assert 9223372036854775807+1==0;", "overflow")]:
        test(one(declaration(body=body)), 4, errors=1, contains=[kind, "stage=body"], ids=["S06", "S07"])
    for body in ["let x:Bool=assert true;", "assert true", "assert true true;"]:
        test(one(declaration(body=body)), 1, contains=["parse:"], ids=["S13"])
    test(one("assert true;"), 1, contains=["parse:"], ids=["S13"])
    test(one(declaration(body='assert panic {"stop"}; assert true;')), 1, contains=["Unreachable"], ids=["S14"])
    result = "let failure:Function():Result<Int,Int>=function():Result<Int,Int>{Result<Int,Int>::Err(1)};"
    test(one(result + declaration(body="discard failure(); assert true;")), ids=["S15"])
    # Literal independently counted position: CRLF, multibyte text, two assertions.
    source = 'namespace App;\r\nlet h:Function():Unit=function():Unit{discard "😀"; assert true; assert false;};\r\n'
    root = project({"helper.mgn": source.replace("let h:", "public let h:") + "",
                    "checks.mgn": 'namespace App;use App\\{h};' + declaration(body="h();")})
    test(root, 5, failed=1, contains=["src/helper.mgn:2:72", "[bytes 90,103)", "src/checks.mgn::App::check"], ids=["S09", "S10"])
    root = one(declaration("helper", "assert false;", "") + declaration("main", "helper();", ""))
    command([CLI, "run", root / "mognitio.toml"], 5, ["assertion:"])
    command([CLI, "build", root / "mognitio.toml", "-o", root / "program"])
    before = command([root / "program"], 5, ["assertion:"], True)
    detached = base / "detached-program"
    shutil.move(root / "program", detached)
    shutil.rmtree(root)
    after = command([detached], 5, ["assertion:"], True)
    assert before.stderr == after.stderr
    covered.update(["S16", "S17"])

    root = project({"app.mgn": "namespace App;" + main,
                    "z.mgn": "namespace App;" + declaration("same"),
                    "a.mgn": "namespace App;" + declaration("same")})
    first = test(root, total=2, ids=["D01", "D05", "D06", "E01"])
    copied = base / "different-checkout"
    shutil.copytree(root, copied)
    assert test(copied, total=2).stdout == first.stdout
    assert first.stdout.index(b"src/a.mgn") < first.stdout.index(b"src/z.mgn")
    for bad in ["let x:Int=true;", "@unknown " + main]:
        test(project({"app.mgn": "namespace App;" + declaration(), "unused.mgn": "namespace App;" + bad}), 1, ids=["D02"])
    test(project({"app.mgn": "namespace App;" + declaration(),
                  "a.mgn": "namespace App;use App\\{B};public alias A=Int;",
                  "b.mgn": "namespace App;use App\\{A};public alias B=Int;"}), 1, ids=["D02"])
    root = one(main)
    (root / "tests").mkdir()
    (root / "tests/check.mgn").write_text("@test invalid")
    (root / "outside.mgn").write_text("@test invalid")
    test(root, total=0, ids=["D03"])
    for files in [{"lib.mgn": "namespace App;" + declaration()},
                  {"app.mgn": "namespace App;" + declaration()},
                  {"app.mgn": "namespace App; let main:Int=1;" + declaration()}]:
        root = project(files)
        test(root, ids=["D07", "D11"])
        command([CLI, "run", root / "mognitio.toml"], 1 if "app.mgn" in files else 2, empty=True)
        command([CLI, "build", root / "mognitio.toml", "-o", root / "program"], 1 if "app.mgn" in files else 2, empty=True)
    for namespace in ["assert", "App\\\\assert"]:
        test(project({}, namespace=namespace), 2, ids=["D12"])
    test(project({"assert/check.mgn": "namespace App\\assert;" + declaration()}), 2, ids=["D13"])
    root = project({"assert.mgn": "namespace App;" + main + declaration()}, name="assert")
    test(root, ids=["D14"])
    command([CLI, "run", root / "mognitio.toml"])
    command([CLI, "build", root / "mognitio.toml", "-o", root / "program"])
    for argv in [[], ["missing", "--filter", "x"], ["missing", "extra"]]:
        command([CLI, "test", *argv], 2, empty=True)
        covered.add("D09")
    for problem in ["manifest", "symlink", "hardlink", "utf8"]:
        root = one(declaration())
        if problem == "manifest":
            (root / "mognitio.toml").write_text("broken")
        elif problem == "symlink":
            (root / "src/link.mgn").symlink_to(root / "src/app.mgn")
        elif problem == "hardlink":
            os.link(root / "src/app.mgn", root / "src/link.mgn")
        else:
            with open(os.fsencode(root / "src") + b"/\xff.mgn", "wb") as f:
                f.write(b"namespace App;")
        test(root, 2, ids=["D08"])

    for body, code, failed, errors in [("assert false;", 5, 1, 0), ('panic {"assertion: fake"}', 4, 0, 1)]:
        test(one(declaration("first", body) + declaration("next")), code, total=2, failed=failed, errors=errors,
             contains=["PASS src/app.mgn::App::next"], ids=["E04", "E05", "E14"])
    test(one(declaration("first", "assert false;") + declaration("next", 'panic {"stop"}')), 4, total=2,
         failed=1, errors=1, ids=["E06"])
    test(one(declaration(body='panic {"body must not run"}') + 'let stop:Int=panic {"init"};'), 4,
         errors=1, contains=["stage=initialization", "panic: init"], ids=["E03"])
    test(one('let stop:Int=panic {"must not run"};'), total=0, ids=["E09"])
    test(one("let x:Int=true;"), 1, ids=["E10"])
    test(one(declaration("callee", "assert false;") + declaration("caller", "callee();")), 5,
         total=2, failed=2, ids=["E11"])
    root = one(declaration(body='panic {"must not auto-run"}') + main)
    command([CLI, "run", root / "mognitio.toml"])
    command([CLI, "build", root / "mognitio.toml", "-o", root / "program"])
    command([root / "program"])
    before = {p: (p.read_bytes(), p.stat().st_mode) for p in root.rglob("*") if p.is_file()}
    test(root, 4, errors=1, ids=["E12", "E13"])
    assert before == {p: (p.read_bytes(), p.stat().st_mode) for p in before}
    # Larger than pipe capacity, including multibyte scalars and raw NUL/LF.
    payload = "😀\0\nassertion: not an event" * 5000
    quoted = payload.replace("\0", "\\0").replace("\n", "\\n")
    r = test(one(declaration(body=f'panic {{"{quoted}"}}')), 4, errors=1)
    assert r.stderr.startswith(b"panic: " + payload.encode() + b"\n")

    for broken in ["stdout", "stderr"]:
        root = one(declaration(body='panic {"payload"}' if broken == "stderr" else "unit"))
        with tempfile.TemporaryFile() as report:
            p = subprocess.Popen([str(CLI), "test", str(root / "mognitio.toml")],
                                 stdout=subprocess.PIPE if broken == "stdout" else report,
                                 stderr=subprocess.PIPE if broken == "stderr" else report)
            getattr(p, broken).close()
            assert p.wait(timeout=30) == 2
            checks += 1
            covered.add("E21")

print(f"v0.11 CLI checks={checks} failures=0 IDs={','.join(sorted(covered))}")
