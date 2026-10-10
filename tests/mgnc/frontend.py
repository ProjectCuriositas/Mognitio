#!/usr/bin/env python3
"""Independent token positions and immutable UTF-8 width data."""
import argparse
import os
import signal
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[2]
KEYWORDS = set("alias as branch break continue contract discard else function implements let loop on over panic product return sum template try type var when while witness true false unit namespace use public".split())
PATTERN = re.compile(r"//[^\r\n]*|[ \t\r\n]+|[A-Za-z_][A-Za-z_0-9]*|[0-9]+|->|=>|==|!=|<=|>=|&&|\|\||::|[{}();,\\*%\[\]/+\-=!<>:]")
def literal(text):
    return '"' + "".join("\\u{" + format(ord(c),"x") + "}" for c in text) + '"'
def tokens(source):
    result=[]
    position=0
    for match in PATTERN.finditer(source):
        assert match.start()==position
        position=match.end()
        text=match.group()
        if text.startswith("//") or text.isspace():
            continue
        prefix=source[:match.start()]
        normalized=prefix.replace("\r\n","\n").replace("\r","\n")
        kind=4 if text in KEYWORDS else 1 if re.fullmatch(r"[A-Za-z_]\w*",text) else 2 if text.isdigit() else 3
        result.append((text,kind,len(prefix.encode()),len(source[:match.end()].encode()),
                       normalized.count("\n")+1,len(normalized.rsplit("\n",1)[-1])+1))
    assert position==len(source)
    normalized=source.replace("\r\n","\n").replace("\r","\n")
    result.append(("",0,len(source.encode()),len(source.encode()),normalized.count("\n")+1,len(normalized.rsplit("\n",1)[-1])+1))
    return result
def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--seed",required=True,type=Path)
    args=parser.parse_args()
    good=["", "namespace App; let main:Function(List<String>):Int=function(args:List<String>):Int{7};",
          "\r\n//あ😀\r\n\tlet x:Int=12;//é", "a==b!=c<=d>=e&&f||g->length();",
          "a/b//comment\rz+3*4%2", "_ _value abc123 0 9223372036854775808",
          "//\u0080\u07ff\u0800\ud7ff\ue000\uffff\U00010000\U0010ffff\ntrue"]
    bad=[("\ufeffx","source"),("01","lexical"),("0x8","lexical"),("&","lexical"),
         ("|","lexical"),("a & b","lexical"),("あ","lexical"),('"x"',"unsupported"),("@test","unsupported")]
    checks=[]
    count=0
    for i,source in enumerate(good):
        expected=tokens(source)
        values=[]
        for text,kind,start,end,line,column in expected:
            values.append("Expected{text:"+literal(text)+f",kind:{kind},start:{start},end:{end},line:{line},column:{column}"+"}")
            count+=1
        checks.append("discard try checkTokens("+literal(source)+",List<Expected>["+",".join(values)+"]);")
    for source,phase in bad:
        checks.append("branch on scan("+literal(source)+"){Result<Paged<Token>,Diagnostic>::Ok(value:Paged<Token>)=>{assert false;},Result<Paged<Token>,Diagnostic>::Err(error:Diagnostic)=>{assert error->phase=="+literal(phase)+";}};")
    source=r"""namespace Mgnc;
use Mgnc\Data\{Paged,Token,Diagnostic,lookup};
use Mgnc\Frontend\{scan};
use Std\Io\{writeStderr,IoError};
type Expected=product{text:String;kind:Int;start:Int;end:Int;line:Int;column:Int;};
let checkTokens:Function(String,List<Expected>):Result<Int,Diagnostic>=function(source:String,expected:List<Expected>):Result<Int,Diagnostic>{
 let tokens:Paged<Token>=try scan(source);
 assert tokens->count==expected->length();
 var index:Int=0;
 loop over(expected as oracle:Expected){
  let token:Token=try lookup<Token>(tokens,index);
  assert token->text==oracle->text && token->kind==oracle->kind;
  assert token->span->start==oracle->start && token->span->end==oracle->end;
  assert token->span->line==oracle->line && token->span->column==oracle->column;
  index=index+1;
 };
 Result<Int,Diagnostic>::Ok(index)
};
let check:Function():Result<Unit,Diagnostic>=function():Result<Unit,Diagnostic>{
"""+"\n".join(checks)+r"""
Result<Unit,Diagnostic>::Ok(unit)
};
let main:Function(List<String>):Int=function(args:List<String>):Int{
branch on check(){Result<Unit,Diagnostic>::Ok(value:Unit)=>0,
Result<Unit,Diagnostic>::Err(error:Diagnostic)=>{
discard writeStderr(error->phase+": "+error->message+"\n");1}}
};
"""
    with tempfile.TemporaryDirectory(prefix="mgnc-frontend-") as temporary:
        work=Path(temporary); project=work/"project"
        shutil.copytree(ROOT/"compiler/mgnc",project)
        (project/"src/mgnc.mgn").write_text(source)
        image=work/"test"
        built=subprocess.run([args.seed.resolve(),"build",project/"mognitio.toml","-o",image],capture_output=True,timeout=600)
        assert (built.returncode,built.stdout,built.stderr)==(0,b"",b""),built.stderr
        ran=subprocess.run([image],capture_output=True,timeout=600)
        assert (ran.returncode,ran.stdout,ran.stderr)==(0,b"",b""),ran.stderr
    print(f"MGNC_FRONTEND_OK sources={len(good)} token_oracles={count} rejected={len(bad)}")
if __name__=="__main__":
    main()
