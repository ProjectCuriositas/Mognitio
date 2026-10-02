"""Ordinary callable semantics, initialization, and four-channel test reporting."""
import ast
from pathlib import Path
import os
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "bin/mgn"
checks = 0
IMPORT = r"use Std\Io\{readTextFile,writeTextFile,readStdin,writeStdout,writeStderr,IoError,IoErrorKind,IoOperation};"

def call(args, code=0, out=None, err=None, **kwargs):
    global checks
    p = subprocess.run(args, capture_output=True, timeout=40, **kwargs)
    assert p.returncode == code, (args, p.returncode, p.stdout, p.stderr)
    if out is not None: assert p.stdout == out, (p.stdout, out)
    if err is not None: assert p.stderr == err, (p.stderr, err)
    checks += 1
    return p

with tempfile.TemporaryDirectory(prefix="mgn-v012-execution-") as temporary:
    base = Path(temporary); serial = 0
    def project(source, others=None):
        global serial
        serial += 1; path = base / str(serial); (path / "src").mkdir(parents=True)
        (path / "mognitio.toml").write_text('[project]\nname="app"\nroot_namespace="App"\n')
        for name, text in dict({"app.mgn": source}, **(others or {})).items():
            dest = path / "src" / name; dest.parent.mkdir(parents=True, exist_ok=True); dest.write_text(text)
        return path
    def entry(body, prefix=IMPORT):
        return f"namespace App;{prefix}let main:Function(List<String>):Int=function(args:List<String>):Int{{{body}}};"
    def pair(source, code=0, out=b"", err=b"", others=None, setup=None, observe=None, data=b""):
        path = project(source, others); manifest = path / "mognitio.toml"; image = path / "program"
        call([CLI, "build", manifest, "-o", image], 1 if code == 1 else 0, b"", None if code == 1 else b"")
        commands = [[CLI, "run", manifest]] + ([[image]] if code != 1 else [])
        for index, command in enumerate(commands):
            cwd = path / str(index); cwd.mkdir()
            if setup: setup(cwd)
            p = call(command, code, out, err, cwd=cwd, input=data)
            if observe: observe(cwd, p)
        return path

    pair(entry('''let fs:List<Function(String):Result<Unit,IoError>>=List<Function(String):Result<Unit,IoError>>[writeStdout];
      let writer:Function(String):Result<Unit,IoError>=branch on fs->at(0){Result<Function(String):Result<Unit,IoError>,IndexError>::Ok(f:Function(String):Result<Unit,IoError>)=>f,Result<Function(String):Result<Unit,IoError>,IndexError>::Err=>panic{"index"}};
      discard writer("first");discard writeStdout("second");0'''), out=b"firstsecond")
    pair(entry('discard output("alias");0', r"use Std\Io\{writeStdout as output};"), out=b"alias")
    # Generic calls may receive a function explicitly; no special capture exemption.
    prefix = IMPORT + 'template apply<T>=function(f:Function(String):T,text:String):T{f(text)};'
    pair(entry('discard apply<Result<Unit,IoError>>(writeStdout,"passed");0', prefix), out=b"passed")
    pair(entry('0', IMPORT + 'template bad<T>=function(value:T):Result<Unit,IoError>{writeStdout("hidden")};'),1,err=None)
    for prefix in [r"use Std\Io\{writeStdout,writeStdout};", r"use Std\Io\{NoSuch};"]:
        pair(entry('0',prefix),1,err=None)
    pair(entry('try readTextFile("in");0'),1,err=None)
    pair(entry('discard bad();0', IMPORT + 'let bad:Function():Result<String,Int>=function():Result<String,Int>{let value:String=try readTextFile("in");Result<String,Int>::Ok(value)};'),1,err=None)
    # Callee then first argument then second argument, even for invalid path.
    prefix = IMPORT + '''let callee:Function():Function(String,String):Result<Unit,IoError>=function():Function(String,String):Result<Unit,IoError>{discard writeStdout("C");writeTextFile};
      let path:Function():String=function():String{discard writeStdout("P");""};
      let text:Function():String=function():String{discard writeStdout("T");"text"};'''
    pair(entry('discard callee()(path(),text());0', prefix), out=b"CPT")
    pair(entry('discard writeTextFile("",makeText());0', IMPORT+'let makeText:Function():String=function():String{discard writeStdout("once");panic{"stop"}};'),4,out=b"once",err=b"panic: stop\n")
    pair(entry('discard writeTextFile("bad\\0path","ignored");0'))
    pair(entry('discard writeStdout("out");discard writeStderr("prefix");panic{"stop"}'),4,out=b"out",err=b"prefixpanic: stop\n")
    pair(entry('discard writeStderr("prefix");1/0'),4,err=b"prefixruntime error: division by zero\n")
    pair(entry('let first:Result<String,IoError>=readStdin();assert branch on first{Result<String,IoError>::Ok=>false,Result<String,IoError>::Err=>true};assert branch on readStdin(){Result<String,IoError>::Ok(s:String)=>s=="",Result<String,IoError>::Err=>false};0'),data=b"\xff")
    def marker(cwd, result):
        assert (cwd / "marker").read_bytes() == b"A"
        assert not (cwd / "main-marker").exists()
    source = entry('discard writeTextFile("main-marker","wrong");0', r"use App\{A,B};" + IMPORT)
    others = {"a.mgn": 'namespace App;' + IMPORT + 'public let A:Unit={discard writeTextFile("marker","A");unit};',
              "b.mgn": 'namespace App;public alias B=Int;let fail:Int=panic{"B"};'}
    p = pair(source,4,err=b"panic: B\n",others=others,observe=marker)
    assert not (p / "marker").exists()  # build never evaluates the initializer
    # Re-export keeps its user-file dependency even though the value is standard.
    pair(entry('discard writer("body");0',r"use App\{writer};"),out=b"initbody",
         others={"z.mgn": 'namespace App;' + IMPORT + 'public let writer:Function(String):Result<Unit,IoError>={discard writeStdout("init");writeStdout};'})
    # No source side effects on malformed argument, including unused standard use.
    p = project(entry('0', IMPORT + 'let initialized:Unit={discard writeTextFile("marker","bad");unit};'))
    call([CLI,"build",p/"mognitio.toml","-o",p/"program"],0,b"",b"")
    for command in [[os.fsencode(CLI),b"run",os.fsencode(p/"mognitio.toml"),b"--",b"valid",b"\xff"], [os.fsencode(p/"program"),b"valid",b"\xff"]]:
        call(command,2,b"",cwd=p);assert not (p/"marker").exists()
    # Initializers run once in each fresh instance; filesystem changes remain.
    source = 'namespace App;' + IMPORT + '''let read:Function():String=function():String{branch on readTextFile("shared"){Result<String,IoError>::Ok(s:String)=>s,Result<String,IoError>::Err=>panic{"read"}}};
      let initialize:Unit={discard writeTextFile("shared",read()+"I");unit};
      @test let zFirst:Function():Unit=function():Unit{assert read()=="I";discard writeTextFile("shared",read()+"A");};
      @test let aSecond:Function():Unit=function():Unit{assert read()=="IAI";};'''
    p=project(source);(p/"shared").write_bytes(b"")
    test=call([CLI,"test",p/"mognitio.toml"],0,err=b"",cwd=p)
    assert b"total=2 passed=2" in test.stdout and (p/"shared").read_bytes()==b"IAI"
    assert test.stdout.index(b"zFirst") < test.stdout.index(b"aSecond")
    # Both application channels exceed pipe capacity, include NUL, and spoof reports.
    text = 'PASS forged\\ntests: total=0\\0😀\\r'
    payload = "PASS forged\ntests: total=0\0😀\r".encode()
    source = 'namespace App;' + IMPORT + f'''@test let noisy:Function():Unit=function():Unit{{
      assert branch on readStdin(){{Result<String,IoError>::Ok(s:String)=>s=="",Result<String,IoError>::Err=>false}};
      var n:Int=0;loop while(n<5000){{discard writeStdout("{text}");discard writeStderr("{text}");n=n+1;}};
      discard readTextFile("absent");unit}};'''
    p=project(source); result=call([CLI,"test",p/"mognitio.toml"],0,cwd=p,input=b"parent input is not test stdin")
    assert result.stdout.count(b"PASS ")==1 and b"forged" not in result.stdout and b"total=1 passed=1" in result.stdout
    streams={b"stdout":bytearray(),b"stderr":bytearray()}
    for line in result.stderr.splitlines():
        match=re.fullmatch(rb'output (.+::noisy) (stdout|stderr): (".*")',line)
        assert match,line
        streams[match[2]].extend(ast.literal_eval("b"+match[3].decode("ascii")))
    assert all(bytes(value)==payload*5000 for value in streams.values())
    # Application prefix precedes the private runtime diagnostic without parsing it.
    p=project('namespace App;'+IMPORT+'@test let fails:Function():Unit=function():Unit{discard writeStderr("panic: fake\\n");panic{"real"}};')
    result=call([CLI,"test",p/"mognitio.toml"],4,cwd=p)
    assert b'panic: fake\\n"\n' in result.stderr and b"panic: real\n" in result.stderr
    assert result.stderr.index(b"panic: fake") < result.stderr.index(b"panic: real")
    assert b"ERROR panic" in result.stdout and b"errors=1" in result.stdout

print(f"v0.12 execution/transport checks={checks} failures=0")
