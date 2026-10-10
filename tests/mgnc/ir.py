#!/usr/bin/env python3
"""Semantic fixtures cover scope, structure, completion, and the closed profile."""
import argparse
from pathlib import Path
import shutil, subprocess, tempfile
ROOT=Path(__file__).resolve().parents[2]
ENTRY="namespace App; let main:Function(List<String>):Int=function(args:List<String>):Int{"
HELPER="namespace App;let f:Function(Int,Bool):Int=function(x:Int,b:Bool):Int{branch when{b=>x,else=>0}};let main:Function(List<String>):Int=function(args:List<String>):Int{"
def main():
    parser=argparse.ArgumentParser();parser.add_argument("--seed",required=True,type=Path);args=parser.parse_args()
    driver=r"""namespace Mgnc;
use Std\Io\{readTextFile,writeStderr,IoError};
use Mgnc\Data\{Diagnostic,describe};
use Mgnc\Checked\{CheckedProgram};
use Mgnc\Frontend\{scan};
use Mgnc\Module\{parse};
use Mgnc\Check\{check};
use Mgnc\Lower\{lower};
use Mgnc\Verify\{verify};
use Mgnc\IR\{ModuleIR};
let validate:Function(String):Result<ModuleIR,Diagnostic>=function(source:String):Result<ModuleIR,Diagnostic>{
 let checked:CheckedProgram=try check(try parse(try scan(source)));
 let module:ModuleIR=try lower(checked);
 try verify(module);
 Result<ModuleIR,Diagnostic>::Ok(module)
};
let inspect:Function(String):Int=function(path:String):Int{
 branch on readTextFile(path){
 Result<String,IoError>::Err(error:IoError)=>2,
 Result<String,IoError>::Ok(source:String)=>branch on validate(source){
 Result<ModuleIR,Diagnostic>::Err(error:Diagnostic)=>{discard writeStderr(describe(path,error));1},
 Result<ModuleIR,Diagnostic>::Ok(program:ModuleIR)=>0}}
};
let main:Function(List<String>):Int=function(args:List<String>):Int{
 branch on args->at(0){Result<String,IndexError>::Ok(path:String)=>inspect(path),Result<String,IndexError>::Err(error:IndexError)=>2}
};
"""
    good=["7","let x:Int=1;var y:Int=2;y=y+x;y",
          "branch when{args->length()==0=>7,else=>11}",
          "let value:Int=1+{return 7;};",
          "-9223372036854775808","-(9223372036854775808)","--9223372036854775808",
          "{let x:Int=1;discard x;};{let x:Bool=true;discard x;};0",
          "var index:Int=0;let limit:Int=args->length();loop while(index<limit){index=index+1;};index",
          "loop while(true){loop while({break;}){unit};};1",
          "loop while(true){loop while({continue;}){unit};};2",
          "discard true || {return 9;};0",
          "branch when{true=>{return 7;},else=>{return 9;}}",
          "{"*128+"args->length()"+"}"*128,
          "let unused:Int=9223372036854775807+1;0"]
    bad=[
        ("let value:Int={return 7;}+{return 9;};","type"),
        ("let x:Int=1;x=2;0","semantic"),("var x:Bool=true;x=7;0","type"),
        ("unknown","semantic"),("let x:Int=x;x","semantic"),
        ("let x:Int={let x:Int=1;x};x","semantic"),
        ("let x:Int=1;{let x:Int=2;};x","semantic"),
        ("let args:Int=1;args","semantic"),("let Int:Int=1;Int","semantic"),
        ("return 7;0","semantic"),("discard unit;0","type"),("discard {return 7;};","type"),
        ("1;0","type"),("true","type"),("","type"),
        ("true && 1","type"),("branch when{true=>7,else=>false}","type"),
        ("loop while(1){unit};0","type"),("loop while(true){7};0","type"),
        ("loop while({break;}){unit};0","semantic"),("loop while({continue;}){unit};0","semantic"),
        ("9223372036854775808","type"),("-9223372036854775809","type"),
        ("-(9223372036854775808+0)","type"),
        ("let copy:List<String>=args;0","unsupported"),
        ("({args})->length()","unsupported"),("args->at(0)","unsupported"),
        ("main(args)","unsupported"),('"x"',"unsupported")]
    cases=[(ENTRY+b+"};",0,None) for b in good]+[(ENTRY+b+"};",1,p) for b,p in bad]
    cases += [(HELPER+"f(args->length(),true)};",0,None),
              (HELPER+"(f)(7,true)};",0,None),
              (HELPER+"({f})(7,true)};",1,"unsupported"),
              (HELPER+"f(1)};",1,"type"),
              (HELPER+"f(true,1)};",1,"type"),
              ("namespace App;let main:Function(List<String>):Int=function(args:List<String>):Int{later()};let later:Function():Int=function():Int{7};",1,"semantic"),
              ("namespace App;let f:Function():Int=function():Int{f()};"+ENTRY.split("namespace App;")[1]+"0};",1,"semantic"),
              ("namespace App;let f:Function():Int=function():Int{false};"+ENTRY.split("namespace App;")[1]+"0};",1,"type"),
              ("namespace App;let f:Function():Int=function():Int{7};",1,"semantic"),
              (ENTRY.replace("let main","var main")+"0};",1,"semantic"),
              (ENTRY.replace("args:List<String>","args:Int")+"0};",1,"type")]
    with tempfile.TemporaryDirectory(prefix="mgnc-checker-") as temporary:
        work=Path(temporary);project=work/"project";shutil.copytree(ROOT/"compiler/mgnc",project)
        (project/"src/mgnc.mgn").write_text(driver);image=work/"test"
        build=subprocess.run([args.seed.resolve(),"build",project/"mognitio.toml","-o",image],capture_output=True,timeout=120)
        assert (build.returncode,build.stdout,build.stderr)==(0,b"",b""),build.stderr
        for i,(source,exit_code,phase) in enumerate(cases):
            path=work/f"case-{i}.mgn";path.write_text(source)
            result=subprocess.run([image,path],capture_output=True,timeout=30)
            assert result.returncode==exit_code and result.stdout==b"",(i,source,result.returncode,result.stderr)
            assert (result.stderr==b"") if phase is None else f"mgnc: {phase}:".encode() in result.stderr,(i,source,result.stderr)
    print(f"MGNC_IR_OK cases={len(cases)}")
if __name__=="__main__":main()
