#!/usr/bin/env python3
"""Cross-entry forwarding constraints and explicit dynamic conversion boundaries."""
from pathlib import Path
import json,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1];checks=0
def run(args,code=0,input=None):
 global checks
 p=subprocess.run(list(map(str,args)),input=input,capture_output=True,timeout=60);checks+=1
 assert p.returncode==code,(args,code,p.returncode,p.stdout,p.stderr)
 if code==0:assert p.stderr==b"",p.stderr
 return p
with tempfile.TemporaryDirectory(prefix="mgn-acceptance-edges-") as tmp:
 root=Path(tmp);(root/"src").mkdir();source=root/"src/app.mgn";image=root/"program"
 manifest='[project]\nname="app"\nroot_namespace="App"\n';path=root/"mognitio.toml";path.write_text(manifest)
 prefix="namespace App;use Std\\Numeric\\{Bits,Signed,Unsigned,IntegerConversionError,BitShiftError};"
 def analyze(text,expected):
  snapshot={"root":str(root),"manifest":manifest,"sources":{"src/app.mgn":text}}
  p=run(["sbcl","--noinform","--script",ROOT/"scripts/analysis-entry.lisp"],input=json.dumps(snapshot).encode()+b"\n")
  assert json.loads(p.stdout)["complete"] is expected
 def execute(body,declarations=""):
  text=prefix+declarations+"let main:Function(List<String>):Int=function(args:List<String>):Int{"+body+"0};"
  source.write_text(text);run([ROOT/"bin/mgn","run",path]);run([ROOT/"bin/mgn","build",path,"-o",image]);run([image]);return text
 declarations="alias Pattern<N:Int>=Bits<N>;template makePattern<N:Int>=function():Pattern<N>{Pattern<N>{255}};template forward<M:Int>=function():Pattern<M>{makePattern<M>()};template relay<K:Int>=function():Pattern<K>{forward<K>()};"
 text=execute("assert relay<8>()==Bits<8>{255};",declarations)
 text+='@test let forwarding:Function():Unit=function():Unit{assert relay<8>()==Bits<8>{255};};'
 source.write_text(text);assert b"forwarding" in run([ROOT/"bin/mgn","test",path]).stdout;analyze(text,True)
 for bad in (text.replace("relay<8>()","relay<7>()"),
             prefix+"let main:Function(List<String>):Int=function(args:List<String>):Int{let x:Int<64,Signed>=1;0};"):
  source.write_text(bad)
  for command in ("run","test","build"):
   run([ROOT/"bin/mgn",command,path]+(["-o",image] if command=="build" else []),1)
  analyze(bad,False)
 body=""
 for sign,values,lo,hi in (("Unsigned",(-1,0,255,256),0,255),("Signed",(-129,-128,127,128),-128,127)):
  t=f"Int<8,{sign}>"
  for value in values:
   good=lo<=value<=hi
   body+=f"assert branch on ({value})->convertTo<{t}>(){{Result<{t},IntegerConversionError>::Ok(x:{t})=>"+(f"x=={t}{{{value}}}" if good else "false")+f",Result<{t},IntegerConversionError>::Err=>"+("false" if good else "true")+"};"
 execute(body)
 body=""
 for count in (-9223372036854775808,-1,0,7,8,9223372036854775807):
  for method in ("shiftLeft","shiftRight"):
   good=0<=count<8
   expected=(129<<count)&255 if good and method=="shiftLeft" else 129>>count if good else 0
   body+=f"assert branch on Bits<8>{{129}}->{method}({count}){{Result<Bits<8>,BitShiftError>::Ok(x:Bits<8>)=>"+(f"x==Bits<8>{{{expected}}}" if good else "false")+",Result<Bits<8>,BitShiftError>::Err(e:BitShiftError)=>"+("false" if good else f"e->count==({count}) && e->width==8")+"};"
  good=0<=count<8
  body+=f"assert branch on Bits<8>{{129}}->at({count}){{Result<Bool,IndexError>::Ok(x:Bool)=>"+(("x" if ((129>>count)&1) else "!x") if good else "false")+",Result<Bool,IndexError>::Err(e:IndexError)=>"+("false" if good else f"e->index==({count}) && e->length==8")+"};"
 execute(body)
print(f"ACCEPTANCE_EDGES_OK checks={checks}")
