#!/usr/bin/env python3
"""Publication evaluation order, first-class values and non-executing frontends."""
from pathlib import Path
import hashlib,json,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1];checks=0
PREFIX="namespace App;use Std\\Numeric\\{Bits,Unsigned,IntegerConversionError};use Std\\Binary\\{Bytes,bytesFromBits,bytesFromInts,ByteValueError,ByteOrder,BinaryDecodeError,publishFile,BinaryFileMode,BinaryOutputError,BinaryOutputErrorKind};use Std\\Io\\{writeStdout};"
EMPTY="bytesFromBits(List<Bits<8>>[])"
def run(args,code=0,out=b"",input=None):
 global checks
 p=subprocess.run(list(map(str,args)),input=input,capture_output=True,timeout=60);checks+=1
 assert p.returncode==code,(args,p.returncode,p.stdout,p.stderr)
 if out is not None:assert p.stdout==out,p.stdout
 if code==0:assert p.stderr==b"",p.stderr
 return p
with tempfile.TemporaryDirectory(prefix="mgn-publish-surface-") as tmp:
 root=Path(tmp);(root/"src").mkdir();source=root/"src/app.mgn";manifest=root/"mognitio.toml";image=root/"program"
 manifest_text='[project]\nname="app"\nroot_namespace="App"\n';manifest.write_text(manifest_text)
 target=root/"never"
 def program(body,extra=""):
  return PREFIX+extra+"let main:Function(List<String>):Int=function(args:List<String>):Int{"+body+"};"
 def both(text,code=0,out=b""):
  source.write_text(text);run([ROOT/"bin/mgn","build",manifest,"-o",image])
  for args in ([ROOT/"bin/mgn","run",manifest],[image]):run(args,code,out)
 def analyze(text,complete):
  result=run(["sbcl","--noinform","--script",ROOT/"scripts/analysis-entry.lisp"],out=None,
   input=(json.dumps({"root":str(root),"manifest":manifest_text,"sources":{"src/app.mgn":text}})+"\n").encode())
  assert json.loads(result.stdout)["complete"] is complete,result.stdout
 # All arguments finish left to right exactly once before invalid-path validation.
 both(program('discard publishFile({discard writeStdout("p");""},{discard writeStdout("b");'+EMPTY+'},{discard writeStdout("m");BinaryFileMode::Data});0'),out=b"pbm")
 both(program('discard publishFile({discard writeStdout("p");""},{discard writeStdout("b");stop()},{discard writeStdout("m");BinaryFileMode::Data});0','let stop:Function():Bytes=function():Bytes{panic{"stop"}};'),4,b"pb")
 both(program('assert receiver()->length()==8;0','let receiver:Function():Bits<8>=function():Bits<8>{discard writeStdout("r");Bits<8>{1}};'),out=b"r")
 both(program('assert receiver()->asInteger<Unsigned>()==Int<8,Unsigned>{1};0','let receiver:Function():Bits<8>=function():Bits<8>{discard writeStdout("r");Bits<8>{1}};'),out=b"r")
 both(program('assert branch on receiver()->convertTo<Int<8,Unsigned>>(){Result<Int<8,Unsigned>,IntegerConversionError>::Ok(x:Int<8,Unsigned>)=>x==Int<8,Unsigned>{1},Result<Int<8,Unsigned>,IntegerConversionError>::Err=>false};0','let receiver:Function():Int=function():Int{discard writeStdout("r");1};'),out=b"r")
 both(program('assert branch on receiver()->toBits<8>(ByteOrder::LittleEndian){Result<Bits<8>,BinaryDecodeError>::Ok(x:Bits<8>)=>x==Bits<8>{1},Result<Bits<8>,BinaryDecodeError>::Err=>false};0','let receiver:Function():Bytes=function():Bytes{discard writeStdout("r");bytesFromBits(List<Bits<8>>[Bits<8>{1}])};'),out=b"r")
 # A constructor Err propagates before publication despite an invalid first argument.
 extra='let attempt:Function():Result<Unit,ByteValueError>=function():Result<Unit,ByteValueError>{discard publishFile({discard writeStdout("p");""},try bytesFromInts(List<Int>[-1]),{discard writeStdout("m");BinaryFileMode::Data});Result<Unit,ByteValueError>::Ok(unit)};'
 both(program("branch on attempt(){Result<Unit,ByteValueError>::Ok=>1,Result<Unit,ByteValueError>::Err(e:ByteValueError)=>branch when{e->index==0 && e->value == -1=>0,else=>2}}",extra),out=b"p")
 # The public function value obeys ordinary try and Result error identity.
 extra='let attempt:Function():Result<Unit,BinaryOutputError>=function():Result<Unit,BinaryOutputError>{let save:Function(String,Bytes,BinaryFileMode):Result<Unit,BinaryOutputError>=publishFile;try save("",'+EMPTY+',BinaryFileMode::Data);Result<Unit,BinaryOutputError>::Ok(unit)};'
 both(program("branch on attempt(){Result<Unit,BinaryOutputError>::Ok=>1,Result<Unit,BinaryOutputError>::Err(e:BinaryOutputError)=>0}",extra))
 # Parsing, analysis, building, and test discovery must not run main.
 text=program('discard publishFile('+json.dumps(str(target))+','+EMPTY+',BinaryFileMode::Data);0')+'@test let check:Function():Unit=function():Unit{assert branch on publishFile("",'+EMPTY+',BinaryFileMode::Data){Result<Unit,BinaryOutputError>::Ok=>false,Result<Unit,BinaryOutputError>::Err=>true};};'
 source.write_text(text);analyze(text,True);run([ROOT/"bin/mgn","build",manifest,"-o",image]);run([ROOT/"bin/mgn","test",manifest],out=None)
 assert not target.exists()
 # Import-only runtime execution causes no publication.
 both(program("0"));assert not target.exists()
 for value in ('"text"','List<Int>[0]','List<String>["x"]','bytesFromInts(List<Int>[0])'):
  bad=program('discard publishFile("",'+value+',BinaryFileMode::Data);0')
  source.write_text(bad);saved=image.read_bytes()
  for command in ("run","build","test"):
   args=[ROOT/"bin/mgn",command,manifest]+(["-o",image] if command=="build" else [])
   run(args,1)
  analyze(bad,False);assert image.read_bytes()==saved
 # Existing source/manifest/artifact and their aliases are never modified.
 for path in (source,manifest,image):
  alias=root/(path.name+".link");alias.symlink_to(path)
  for dest in (path,alias):
   text=program('branch on publishFile('+json.dumps(str(dest))+','+EMPTY+',BinaryFileMode::Data){Result<Unit,BinaryOutputError>::Ok=>1,Result<Unit,BinaryOutputError>::Err(e:BinaryOutputError)=>branch on e->kind{BinaryOutputErrorKind::AlreadyExists=>0,BinaryOutputErrorKind::InvalidPath=>2,BinaryOutputErrorKind::NotFound=>2,BinaryOutputErrorKind::PermissionDenied=>2,BinaryOutputErrorKind::UnsupportedTarget=>2,BinaryOutputErrorKind::ResourceExhausted=>2,BinaryOutputErrorKind::Other=>2}}')
   source.write_text(text);run([ROOT/"bin/mgn","build",manifest,"-o",image])
   before={p:(hashlib.sha256(p.read_bytes()).hexdigest(),p.stat().st_mode) for p in (source,manifest,image)}
   run([ROOT/"bin/mgn","run",manifest]);run([image])
   assert before=={p:(hashlib.sha256(p.read_bytes()).hexdigest(),p.stat().st_mode) for p in before}
print(f"PUBLICATION_SURFACE_OK checks={checks}")
