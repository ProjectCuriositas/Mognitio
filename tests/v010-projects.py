#!/usr/bin/env python3
"""Project boundary and native conformance; uses only temporary fixtures."""
import os
from pathlib import Path
import shutil
import socket
import stat
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "bin/mgn"
checks = 0

def command(args, code=0, err=None, out=b"", env=None):
    global checks
    r = subprocess.run([str(x) for x in args], capture_output=True, timeout=25, env=env)
    checks += 1
    assert r.returncode == code, (args[0], code, r.returncode, r.stderr.decode(errors="backslashreplace"))
    assert r.stdout == out, (r.stdout, out)
    if err is not None:
        assert err.encode() in r.stderr, r.stderr
    elif code == 0:
        assert r.stderr == b"", r.stderr
    return r

with tempfile.TemporaryDirectory(prefix="mgn-project-tests-") as tmp:
    base = Path(tmp)
    count = 0
    def project(files, manifest='[project]\nname="app"\nroot_namespace="App"\n'):
        global count
        count += 1
        root = base / str(count)
        (root / "src").mkdir(parents=True)
        (root / "mognitio.toml").write_text(manifest)
        for name, value in files.items():
            path = root / "src" / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(value if isinstance(value, bytes) else value.encode())
        return root

    empty = "namespace App; let main: Function(): Unit = function(): Unit { unit };"
    def pair(files, code=0, err=None):
        root = project(files)
        command([CLI, "run", root / "mognitio.toml"], code, err)
        if code in (0, 4):
            command([CLI, "build", root / "mognitio.toml", "-o", root / "out"])
            command([root / "out"], code, err)
        else:
            artifact = root / "out"
            artifact.write_bytes(b"old-artifact")
            before = {p: p.read_bytes() for p in root.rglob("*") if p.is_file()}
            command([CLI, "build", root / "mognitio.toml", "-o", artifact], code, err)
            assert before == {p: p.read_bytes() for p in before}
        return root

    pair({"app.mgn": empty})
    pair({"app.mgn": 'namespace App; use App\\Lib\\{answer as value,}; let main: Function(): Unit = function(): Unit { branch when { value == 42 => unit, else => panic { "wrong" } } };',
          "Lib/data.mgn": "namespace App\\Lib; public let answer: Int = 42;"})
    pair({"app.mgn": 'namespace App; use App\\{make}; let main: Function(): Unit = make();',
          "factory.mgn": "namespace App; public let make: Function(): Function(): Unit = function(): Function(): Unit { function(): Unit { unit } };"})
    pair({"app.mgn": empty, "unused.mgn": 'namespace App; let stop: Int = panic { "unused" };'})
    pair({"app.mgn": 'namespace App; use App\\{Stop}; let main: Function(): Unit = function(): Unit { panic { "main" } };',
          "stop.mgn": 'namespace App; public alias Stop = Int; let stop: Int = panic { "init" };'}, 4, "panic: init")
    pair({"app.mgn": empty, "bad.mgn": 'namespace App; let stop: Int = panic { "init" }; let later: Int = 0;'}, 1, "Unreachable")
    pair({"app.mgn": empty, "bad.mgn": "namespace Other; public alias X = Int;"}, 1, "Namespace")
    pair({"app.mgn": 'namespace App; use App\\{Hidden}; let main: Function(): Unit = function(): Unit { unit };',
          "hidden.mgn": 'namespace App; alias Hidden = Int;'}, 1, "Import")
    pair({"app.mgn": 'namespace App; use App\\{X as A, X as B}; let main: Function(): Unit = function(): Unit { unit };',
          "x.mgn": "namespace App; public alias X = Int;"}, 1, "Duplicate")
    pair({"app.mgn": 'namespace App; use App\\{X}; public alias X = Int; let main: Function(): Unit = function(): Unit { unit };'}, 1, "Import")
    pair({"app.mgn": empty, "one.mgn": "namespace App; public alias X = Int;",
          "two.mgn": "namespace App; public alias X = Bool;"}, 1, "Previous declaration")
    pair({"app.mgn": empty, "one.mgn": "namespace App; use App\\{B}; public alias A = Int;",
          "two.mgn": "namespace App; use App\\{A}; public alias B = Int;"}, 1, "Cyclic")
    pair({"app.mgn": "namespace App;"}, 1, "main")
    pair({"app.mgn": "namespace App; var main: Function(): Unit = function(): Unit { unit };"}, 1, "main")
    pair({"app.mgn": "namespace App; let main: Function(): Bool = function(): Bool { true };"}, 1, "Function(): Unit")
    pair({"app.mgn": empty + " true"}, 1, "tail")
    pair({"app.mgn": "namespace App; let main: Function(): Unit = function(): Unit { discard later; unit }; let later: Int = 1;"}, 1, "visible")
    pair({"app.mgn": empty, "leak.mgn": "namespace App; type Hidden = product { value: Int; }; public alias Leak = Hidden;"}, 1, "private")
    pair({"app.mgn": 'namespace App; use App\\{Box, id}; let main: Function(): Unit = function(): Unit { let b: Box<Int> = Box<Int> { value: id<Int>(42) }; branch when { b->value == 42 => unit, else => panic { "generic" } } };',
          "lib.mgn": "namespace App; public type Box<T> = product { value: T; }; public template id<T> = function(value: T): T { value };"})
    pair({"app.mgn": 'namespace App; use App\\{User, Printable, UserPrintable}; let main: Function(): Unit = function(): Unit { let p: Printable = Printable(User { value: 7 }); branch when { p->read() == 7 => unit, else => panic { "witness" } } };',
          "lib.mgn": 'namespace App; public type User = product { value: Int; }; public contract Printable { read(self: Self): Int; } public witness UserPrintable = User implements Printable { read(self: Self): Int { self->value } }'})
    pair({"app.mgn": 'namespace App; use App\\{User, Printable}; let main: Function(): Unit = function(): Unit { let p: Printable = Printable(User { value: 7 }); unit };',
          "lib.mgn": 'namespace App; public type User = product { value: Int; }; public contract Printable { read(self: Self): Int; } public witness UserPrintable = User implements Printable { read(self: Self): Int { self->value } }'}, 1, "evidence")
    pair({"app.mgn": 'namespace App; use App\\{left, right}; let main: Function(): Unit = function(): Unit { branch when { left->read() == 1 && right->read() == 2 => unit, else => panic { "identity" } } };',
          "contract.mgn": 'namespace App; public contract Read { read(self: Self): Int; }',
          "left.mgn": 'namespace App; use App\\{Read}; type Hidden = product { value: Int; }; witness Proof = Hidden implements Read { read(self: Self): Int { self->value } } public let left: Read = Read(Hidden { value: 1 });',
          "right.mgn": 'namespace App; use App\\{Read}; type Hidden = product { value: Int; }; witness Proof = Hidden implements Read { read(self: Self): Int { self->value } } public let right: Read = Read(Hidden { value: 2 });'})

    pair({"app.mgn": 'namespace App; alias Entry = Function(): Unit; public let main: Entry = function(): Unit { unit };'})
    for body in ["public var n: Int = 1;", "public use App\\{X};", "use App\\X;", "use App\\*;", "use App\\{};", "namespace Other;", "let main:Function():Unit=function():Unit{unit}; use App\\{X};"]:
        pair({"app.mgn": "namespace App; " + body}, 1)
    pair({"app.mgn": 'namespace App; use App\\{entry as main};',
          "lib.mgn": 'namespace App; public let entry:Function():Unit=function():Unit{unit};'}, 1, "main")
    for leak in ["public type Box = product { value: Hidden; };",
                 "public type Box = sum { Value(Hidden); };",
                 "public let create: Function(): Hidden = function():Hidden{Hidden{value:1}};",
                 "public template make<T> = function(value:T):Hidden{Hidden{value:1}};",
                 "public alias Items<T> = List<Hidden>;",
                 "public contract C { get(self:Self):Hidden; }"]:
        pair({"app.mgn": empty, "lib.mgn": "namespace App; type Hidden=product{value:Int;}; " + leak}, 1, "private")
    pair({"app.mgn": 'namespace App; use App\\{id, Box as Other}; let main:Function():Unit=function():Unit{let b:Other<Int>=id<Int>(41);branch when{b->value==42=>unit,else=>panic{"definition"}}};',
          "lib.mgn": 'namespace App; public type Box<T>=product{value:Int;}; template add<T>=function(value:Int):Box<T>{Box<T>{value:value+1}}; public template id<T>=function(value:Int):Box<T>{add<T>(value)};'})
    pair({"app.mgn": 'namespace App; use App\\{num}; template bad<T>=function():Int{num}; let main:Function():Unit=function():Unit{unit};',
          "lib.mgn": 'namespace App; public let num:Int=42;'}, 1)
    pair({"app.mgn": 'namespace App; use App\\{C, Proof}; let main:Function():Unit=function():Unit{discard Proof;unit};',
          "lib.mgn": 'namespace App; public contract C{read(self:Self):Int;}public witness Proof = Int implements C{read(self:Self):Int{self}}'}, 1)
    pair({"app.mgn": empty,
          "c.mgn": 'namespace App; public contract C{read(self:Self):Int;}',
          "a.mgn": 'namespace App; use App\\{C}; witness A = Int implements C{read(self:Self):Int{self}}',
          "b.mgn": 'namespace App; use App\\{C}; witness B = Int implements C{read(self:Self):Int{self}}'}, 1)
    pair({"app.mgn": 'namespace App; use App\\{B,A}; let main:Function():Unit=function():Unit{panic{"main"}};',
          "a.mgn": 'namespace App; public alias A=Int; let stop:Int=panic{"a first"};',
          "b.mgn": 'namespace App; public alias B=Int; let stop:Int=panic{"b first"};'}, 4, "a first")
    pair({"app.mgn": 'namespace App; use App\\{Value, again}; let main:Function():Unit=function():Unit{branch when{Value==again=>unit,else=>panic{"shared"}}};',
          "data.mgn": 'namespace App; public let Value:Int=42;',
          "alias.mgn": 'namespace App; use App\\{Value}; public let again:Int=Value;'})
    # Stable strings, symbols, images and standalone execution across roots/caches.
    files = {"app.mgn": 'namespace App; use App\\{left,right}; let main:Function():Unit=function():Unit{branch when{left=="left"&&right=="right"=>unit,else=>panic{"strings"}}};',
             "a.mgn": 'namespace App; public let left:String="left";',
             "日本語.mgn": 'namespace App; public let right:String="right";'}
    images = []
    for locale in ["C", "C.UTF-8"]:
        root = project(files)
        for iteration in range(2):
            command([CLI, "build", root / "mognitio.toml", "-o", root / "out"],
                    env=dict(os.environ, LC_ALL=locale, XDG_CACHE_HOME=str(base / "fresh-cache")))
            images.append((root / "out").read_bytes())
        shutil.rmtree(root / "src")
        (root / "mognitio.toml").unlink()
        command([root / "out"], env={"PATH": "/nonexistent"})
    assert all(image == images[0] for image in images)


    pair({"app.mgn": 'namespace App; use App\\A\\{Value as Left}; use App\\B\\{Value as Right}; let main:Function():Unit=function():Unit{branch when{Left==1&&Right==2=>unit,else=>panic{"alias"}}};',
          "A/value.mgn": 'namespace App\\A; public let Value:Int=1;',
          "B/value.mgn": 'namespace App\\B; public let Value:Int=2;'})
    pair({"app.mgn": empty, "bad.mgn": 'namespace App; let num:Int=true;'}, 1, "type:")
    pair({"app.mgn": 'namespace App; let main:Function(Int):Unit=function(n:Int):Unit{unit};'}, 1, "type:")
    pair({"app.mgn": 'namespace App; template main<T>=function():Unit{unit};'}, 1, "semantic:")
    pair({"app.mgn": 'namespace App; let value:C=C(42); contract C{read(self:Self):Int;} witness Proof=Int implements C{read(self:Self):Int{self}} let main:Function():Unit=function():Unit{branch when{value->read()==42=>unit,else=>panic{"forward"}}};'})
    pair({"app.mgn": 'namespace App; let implement:Int=1;let against:Int=2;let private:Int=3;let main:Function():Unit=function():Unit{discard implement+against+private;unit};'})
    for body in ['use \\App\\{X};', 'use App\\{X,{Y}};', 'use witness X;', 'use App\\{X}', 'use App\\{X};let X:Int=1;']:
        pair({"app.mgn": 'namespace App; ' + body + ' let main:Function():Unit=function():Unit{unit};',
              "lib.mgn": 'namespace App; public alias X=Int;'}, 1)
    pair({"app.mgn": 'namespace App;use App\\{X,Y};let main:Function():Unit=function():Unit{let x:X=Y{n:42};discard x;unit};',
          "lib.mgn": 'namespace App;public type X=product{n:Int;};public alias Y=X;'})
    # Caller-visible output aliases must preserve every physical input.
    root = project({"app.mgn": empty, "unused.mgn": "namespace App;"})
    for kind in ["symlink", "hardlink"]:
        target = root / kind
        if kind == "symlink": target.symlink_to(root / "src/unused.mgn")
        else: os.link(root / "src/unused.mgn", target)
        command([CLI, "build", root / "mognitio.toml", "-o", target], 2)
        assert target.read_text() == "namespace App;"
    (root / "aliasdir").symlink_to(root / "src", target_is_directory=True)
    command([CLI, "build", root / "mognitio.toml", "-o", root / "aliasdir/new.mgn"], 2)
    assert not (root / "src/new.mgn").exists()
    command([CLI, "build", root / "mognitio.toml", "-o", root / "out"])
    command(["sh", "-c", 'exec "$1" >/dev/full', "project", root / "out"])
    command(["sh", "-c", 'exec "$1" 1>&-', "project", root / "out"])
    (root / "mognitio.toml").rename(root / "mgn.toml")
    command([CLI, "run", root / "mgn.toml"], 2)

    # Manifest schema and alternative legal TOML representations.
    for manifest in ['project = { name = "app", root_namespace = "App" }\n',
                     '"project".name = \'app\'\nproject."root_namespace" = """App"""\n',
                     '[ "project" ]\nname = "\\u0061pp"\nroot_namespace = \'App\'\n']:
        root = project({"app.mgn": empty}, manifest)
        command([CLI, "run", root / "mognitio.toml"])
    for manifest in ['[project]\nname="app"\n', '[project]\nname="app"\nroot_namespace="App"\nx="bad"\n',
                     '[project]\nname=42\nroot_namespace="App"\n',
                     '[project]\nname="app"\nname="app"\nroot_namespace="App"\n',
                     'project = {name="app", root_namespace="App",}\n']:
        root = project({"app.mgn": empty}, manifest)
        command([CLI, "run", root / "mognitio.toml"], 2)
    root = project({"app.mgn": empty, "日本語.mgn": "namespace App; alias Other = Int;"})
    for locale in ["C", "C.UTF-8"]:
        command([CLI, "run", root / "mognitio.toml"], env=dict(os.environ, LC_ALL=locale))
    bad = os.fsencode(root / "src") + b"/bad\xff.mgn"
    with open(bad, "wb") as f:
        f.write(b"namespace App;")
    command([CLI, "run", root / "mognitio.toml"], 2)
    os.unlink(bad)
    root = project({"app.mgn": empty, "bad.mgn": b"\xff"})
    command([CLI, "run", root / "mognitio.toml"], 1, "UTF-8")
    for kind in ["fifo", "socket", "symlink", "hardlink"]:
        root = project({"app.mgn": empty})
        special = root / "src/special.mgn"
        sock = None
        if kind == "fifo": os.mkfifo(special)
        elif kind == "socket":
            sock = socket.socket(socket.AF_UNIX)
            sock.bind(str(special))
        elif kind == "symlink": special.symlink_to(root / "src/app.mgn")
        else: os.link(root / "src/app.mgn", special)
        try:
            command([CLI, "run", root / "mognitio.toml"], 2)
            artifact = root / "out"
            artifact.write_bytes(b"preserved")
            before = {p: p.read_bytes() for p in root.rglob("*") if stat.S_ISREG(p.lstat().st_mode)}
            command([CLI, "build", root / "mognitio.toml", "-o", artifact], 2)
            assert before == {p: p.read_bytes() for p in before}
        finally:
            if sock: sock.close()
    root = project({"app.mgn": empty, "unused.mgn": "namespace App;"})
    for target in [root / "mognitio.toml", root / "src/app.mgn", root / "src/unused.mgn", root / "src/generated.mgn"]:
        before = {p: p.read_bytes() for p in root.rglob("*") if p.is_file()}
        command([CLI, "build", root / "mognitio.toml", "-o", target], 2)
        assert before == {p: p.read_bytes() for p in root.rglob("*") if p.is_file()}
    command([CLI, "run", root / "src/app.mgn"], 2)

    diagnostics = []
    for name in ["new\nline.mgn", r"new\nline.mgn"]:
        root = project({"app.mgn": empty, name: "@"})
        diagnostics.append(command([CLI, "run", root / "mognitio.toml"], 1).stderr)
    assert diagnostics[0] != diagnostics[1]
    assert all(d.count(b"\n") == 1 for d in diagnostics)
    assert not (ROOT / "bin/mognitio").exists()
    print(f"Project checks={checks} failures=0")
