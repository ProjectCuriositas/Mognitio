#!/usr/bin/env python3
"""Exercise the shared static analyzer without running user programs."""
import argparse,json,subprocess
from pathlib import Path
parser=argparse.ArgumentParser()
parser.add_argument("--payload",type=Path,required=True)
args=parser.parse_args()
root=Path(__file__).resolve().parent.parent
payload=args.payload.resolve()
def analyze(sources,project=True):
 snapshot={"root":"/fixture" if project else None,"sources":sources}
 if project:snapshot["manifest"]='[project]\nname = "sample"\nroot_namespace = "Example"\n'
 result=subprocess.run([str(payload/"runtime/sbcl"),"--core",str(payload/"runtime/mognitio.core"),"--noinform","--no-sysinit","--no-userinit","--mognitio-worker"],input=json.dumps(snapshot).encode()+b"\n",capture_output=True,timeout=12)
 assert result.returncode==0,(result.returncode,result.stderr)
 return json.loads(result.stdout)
def one(text,complete=True):
 result=analyze({"src/sample.mgn":"namespace Example;\n"+text})
 assert result["complete"] is complete,result
 return result
one('let main: Int = 1;')
one('@test let testBody: Function(): Unit = function(): Unit { let wrong: Int = false; };',False)
one('let crash: Int = panic { "must not run" };')
one('let a: Int = ; let b: Int = ; let valid: Int = 2;',False)
result=analyze({"one.mgn":'let a: String = "unfinished',"two.mgn":"let b: Int = 2;"},False)
assert not result["complete"] and result["tokens"]["two.mgn"],result
text="let call: Function(Function(Int): Int): Int = function(callback: Function(Int): Int): Int { callback(1) };"
result=one(text)
source=("namespace Example;\n"+text).encode()
rows=[(source[a:b].decode(),kind,mods) for a,b,kind,mods in result["tokens"]["src/sample.mgn"]]
assert any(name=="call" and kind==4 and mods==3 for name,kind,mods in rows),rows
assert all(kind==6 for name,kind,mods in rows if name=="callback"),rows
text='let words: String = "hello"; let length: Int = words->length();'
result=one(text);source=("namespace Example;\n"+text).encode()
assert any(source[a:b]==b"length" and kind==8 and mods&4 for a,b,kind,mods in result["tokens"]["src/sample.mgn"]),result
text="type Box<T> = product { T: Int; value: T; }; let box: Box<Int> = Box<Int> { T: 1, value: 2 };"
result=one(text);source=("namespace Example;\n"+text).encode()
roles=[kind for a,b,kind,mods in result["tokens"]["src/sample.mgn"] if source[a:b]==b"T"]
assert sorted(roles)==[3,3,7,7],roles
text=r'use Std\Io\{IoError, readTextFile}; let response: Result<String,IoError> = readTextFile("not-opened");'
result=one(text);source=("namespace Example;\n"+text).encode()
standard=[mods for a,b,kind,mods in result["tokens"]["src/sample.mgn"] if source[a:b]==b"IoError"]
assert len(standard)>=2 and all(mods&4 for mods in standard),standard
# All shipped example projects share exactly the compiler's grammar and checker.
count=0
for manifest in sorted((root/"examples").glob("*/mognitio.toml")):
 snapshot={"root":"/fixture","manifest":manifest.read_text(),"sources":{p.relative_to(manifest.parent).as_posix():p.read_text() for p in (manifest.parent/"src").rglob("*.mgn")}}
 result=subprocess.run([str(payload/"runtime/sbcl"),"--core",str(payload/"runtime/mognitio.core"),"--noinform","--no-sysinit","--no-userinit","--mognitio-worker"],input=json.dumps(snapshot).encode()+b"\n",capture_output=True,timeout=12)
 assert result.returncode==0,(manifest.parent.name,result.stderr)
 data=json.loads(result.stdout)
 assert data["complete"],(manifest.parent.name,data["diagnostics"])
 count+=1
print("PASS analysis-only entry/test/panic, recovery, Function parameter precedence, intrinsic method; examples="+str(count))
