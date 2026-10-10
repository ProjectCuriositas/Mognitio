#!/usr/bin/env python3
"""Add observed parser size/depth without using compiler output as a runtime oracle."""
import argparse,hashlib,json,shutil,subprocess,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
DRIVER=r"""namespace Mgnc;
use Std\Io\{readTextFile,writeStdout,IoError};
use Mgnc\Data\{Paged,Token,Diagnostic,empty,push,lookup,number};
use Mgnc\Syntax\{Program,Node};
use Mgnc\Frontend\{scan};
use Mgnc\Module\{parse};
let inspect:Function(String):Result<String,Diagnostic>=function(source:String):Result<String,Diagnostic>{
 let tokens:Paged<Token>=try scan(source);let program:Program=try parse(tokens);
 var depths:Paged<Int>=empty<Int>();var maximum:Int=0;
 loop over(program->nodes->pages->append(program->nodes->tail) as page:List<Node>){
  loop over(page as node:Node){
   var depth:Int=1;
   loop over(node->children as child:Int){
    let childDepth:Int=try lookup<Int>(depths,child);
    branch when{childDepth+1>depth=>{depth=childDepth+1;},else=>unit};
   };
   depths=push<Int>(depths,depth);
   branch when{depth>maximum=>{maximum=depth;},else=>unit};
  };
 };
 Result<String,Diagnostic>::Ok("{\"tokens\":"+number(tokens->count)+",\"nodes\":"+number(program->nodes->count)+",\"max_depth\":"+number(maximum)+",\"functions\":"+number(program->declarations->length())+"}\n")
};
let main:Function(List<String>):Int=function(args:List<String>):Int{
 let path:String=branch on args->at(0){Result<String,IndexError>::Ok(value:String)=>value,Result<String,IndexError>::Err=>{return 2;}};
 let source:String=branch on readTextFile(path){Result<String,IoError>::Ok(value:String)=>value,Result<String,IoError>::Err=>{return 2;}};
 let result:String=branch on inspect(source){Result<String,Diagnostic>::Ok(value:String)=>value,Result<String,Diagnostic>::Err=>{return 3;}};
 branch on writeStdout(result){Result<Unit,IoError>::Ok=>0,Result<Unit,IoError>::Err=>2}
};
"""
def main():
    parser=argparse.ArgumentParser();parser.add_argument("--seed",required=True,type=Path)
    parser.add_argument("--fixtures",required=True,type=Path);args=parser.parse_args()
    manifest=args.fixtures/"manifest.json";rows=json.loads(manifest.read_text())
    with tempfile.TemporaryDirectory(prefix="mgnc-metadata-") as temporary:
        work=Path(temporary);project=work/"project";shutil.copytree(ROOT/"compiler/mgnc",project)
        (project/"src/mgnc.mgn").write_text(DRIVER);image=work/"probe"
        built=subprocess.run([args.seed.resolve(),"build",project/"mognitio.toml","-o",image],capture_output=True,timeout=120)
        assert (built.returncode,built.stdout,built.stderr)==(0,b"",b""),built
        for row in rows:
            source=args.fixtures/(row["name"]+".mgn");assert hashlib.sha256(source.read_bytes()).hexdigest()==row["sha256"]
            result=subprocess.run([image,source.resolve()],capture_output=True,timeout=120)
            assert result.returncode==0 and result.stderr==b"",result
            observed=json.loads(result.stdout);assert observed["tokens"]==row["tokens"],(row,observed)
            row.update(observed)
    manifest.write_text(json.dumps(rows,indent=2)+"\n")
    print(f"MGNC_METADATA_OK cells={len(rows)}")
if __name__=="__main__":main()
