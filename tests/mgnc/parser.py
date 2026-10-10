#!/usr/bin/env python3
"""Exercise the continuation parser with independent positive and negative sources."""
import argparse
from pathlib import Path
import shutil, subprocess, tempfile
ROOT=Path(__file__).resolve().parents[2]
ENTRY="namespace App; let main:Function(List<String>):Int=function(args:List<String>):Int{"
def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--seed",required=True,type=Path)
    args=parser.parse_args()
    driver=r"""namespace Mgnc;
use Std\Io\{readTextFile,writeStderr,IoError};
use Mgnc\Data\{Paged,Token,Diagnostic,describe};
use Mgnc\Syntax\{Program,Node};
use Mgnc\Frontend\{scan};
use Mgnc\Module\{parse};
let check:Function(String):Int=function(path:String):Int{
 branch on readTextFile(path){
 Result<String,IoError>::Err(error:IoError)=>2,
 Result<String,IoError>::Ok(source:String)=>branch on scan(source){
 Result<Paged<Token>,Diagnostic>::Err(error:Diagnostic)=>{discard writeStderr(describe(path,error));1},
 Result<Paged<Token>,Diagnostic>::Ok(tokens:Paged<Token>)=>branch on parse(tokens){
 Result<Program,Diagnostic>::Err(error:Diagnostic)=>{discard writeStderr(describe(path,error));1},
 Result<Program,Diagnostic>::Ok(program:Program)=>{assert program->nodes->count>0;
 var index:Int=0;
 loop over(program->nodes->pages as page:List<Node>){
  loop over(page as node:Node){loop over(node->children as child:Int){assert child<index;};index=index+1;};
 };
 loop over(program->nodes->tail as node:Node){loop over(node->children as child:Int){assert child<index;};index=index+1;};
 assert index==program->nodes->count;0}}}}
};
let main:Function(List<String>):Int=function(args:List<String>):Int{
 branch on args->at(0){Result<String,IndexError>::Ok(path:String)=>check(path),
 Result<String,IndexError>::Err(error:IndexError)=>2}
};
"""
    good=["let copy:List<String>=args;0","7","let x:Int=1; var y:Int=2; y=y+x; y",
          "branch when{args->length()==0=>7,else=>11,}",
          "var x:Int=0; loop while(x<3){x=x+1;}; x",
          "let x:Int=1+{return 7;};",
          "discard f(1,2,); f(3,4)",
          "(f)((args)->length())",
          "branch when{true=>{return 7;},false=>1,else=>2}",
          "loop while({break;}){unit};0",
          "{"*128+"args->length()"+"}"*128]
    bad=[("let x:Int>=7;0","parse"),("1+;","parse"),("let x=1;0","parse"),("branch when{true=>1}","parse"),
         ("loop while(true) unit;0","parse"),("1<2<3","parse"),
         ("f(,);0","parse"),("let x:Int=0 0","parse"),("use Std;0","unsupported"),
         ("function():Int{7}","unsupported")]
    with tempfile.TemporaryDirectory(prefix="mgnc-parser-") as temporary:
        work=Path(temporary);project=work/"project"
        shutil.copytree(ROOT/"compiler/mgnc",project)
        (project/"src/mgnc.mgn").write_text(driver)
        image=work/"test"
        build=subprocess.run([args.seed.resolve(),"build",project/"mognitio.toml","-o",image],capture_output=True,timeout=120)
        assert (build.returncode,build.stdout,build.stderr)==(0,b"",b""),build.stderr
        for i,body in enumerate(good):
            source=work/f"good-{i}.mgn";source.write_text(ENTRY+body+"};")
            result=subprocess.run([image,source],capture_output=True,timeout=30)
            assert (result.returncode,result.stdout,result.stderr)==(0,b"",b""),(i,result.stderr)
        for i,(body,phase) in enumerate(bad):
            source=work/f"bad-{i}.mgn";source.write_text(ENTRY+body+"};")
            result=subprocess.run([image,source],capture_output=True,timeout=30)
            assert result.returncode==1 and result.stdout==b"" and f"mgnc: {phase}:".encode() in result.stderr,(i,result.stderr)
    print(f"MGNC_PARSER_OK positive={len(good)} negative={len(bad)} block_depth=128")
if __name__=="__main__":main()
