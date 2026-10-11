#!/usr/bin/env python3
# Original UTF-8 spans, literal ranges, and residual punctuation scanner.
import argparse, shutil, subprocess, tempfile
from pathlib import Path
from frontend import literal
ROOT=Path(__file__).resolve().parents[2]
def run_entry(seed,source):
 with tempfile.TemporaryDirectory(prefix="mgnc-shared-") as t:
  work=Path(t);project=work/"project";shutil.copytree(ROOT/"compiler/mgnc",project)
  (project/"src/mgnc.mgn").write_text(source)
  result=subprocess.run([seed,"build",project/"mognitio.toml","-o",work/"test"],capture_output=True,timeout=600)
  assert (result.returncode,result.stdout,result.stderr)==(0,b"",b""),result.stderr.decode()
  result=subprocess.run([work/"test"],capture_output=True,timeout=120)
  assert (result.returncode,result.stdout,result.stderr)==(0,b"",b""),result.stderr.decode()
def main():
 parser=argparse.ArgumentParser();parser.add_argument("--seed",required=True);args=parser.parse_args()
 checks=[]
 good=['', '""', '"日本é😀"', '"\\\"\\\\\\n\\r\\t\\0\\u{0}\\u{10ffff}"', 'N:Int', '999999999999999999999999999999999999', '//é😀\r\n\t"ok"', '//'+('x'*1021)+'\r\n"a\\u{1f600}"', '"'+('x'*65536)+'"', '9'*65536]
 bad=['\ufeffx','01','0x1','0_1','1abc','"a\n"','"a\r"','"\\q"','"\\u"','"\\u{}"','"\\u{0000000}"','"\\u{d800}"','"\\u{dfff}"','"\\u{110000}"','"unterminated','"\\','|','&']
 for s in good:
  checks.append('discard try scanSource('+literal(s)+');')
 for s in bad:
  checks.append('branch on scanSource('+literal(s)+'){Result<Snapshot,Diagnostic>::Ok(value:Snapshot)=>{assert false;},Result<Snapshot,Diagnostic>::Err(error:Diagnostic)=>unit};')
 cases=[('>==',[(True,'>',0,1),(False,'==',1,3)]),('>=>',[(True,'>',0,1),(False,'=>',1,3)]),('>==>',[(True,'>',0,1),(False,'==',1,3),(False,'>',3,4)]),('>===',[(True,'>',0,1),(False,'==',1,3),(False,'=',3,4)]),('>>=',[(True,'>',0,1),(True,'>',1,2),(False,'=',2,3)]),('>=',[(False,'>=',0,2)]),('>= =',[(True,'>',0,1),(False,'=',1,2),(False,'=',3,4)]),('>=//x\r\n>',[(True,'>',0,1),(False,'=',1,2),(False,'>',7,8)])]
 for s,steps in cases:
  checks.append('{let snap:Snapshot=try scanSource('+literal(s)+');var cursor:Int=0;')
  for close,token,start,end in steps:
   checks.append('{let terminal:Terminal=try scanAt(snap,cursor,'+str(close).lower()+');assert terminal->token->text=='+literal(token)+f';assert terminal->token->site->span->start=={start}&&terminal->token->site->span->end=={end};cursor=terminal->next;}};')
  checks.append('let done:Terminal=try scanAt(snap,cursor,false);assert done->token->kind==0;};')
 s='//é😀\r\n\t"x\\u{41}日" 999';b=len(s.encode());n=s.replace('\r\n','\n');line=n.count('\n')+1;col=len(n.rsplit('\n',1)[-1])+1
 checks.append('{let snap:Snapshot=try scanSource('+literal(s)+f');assert snap->end->span->start=={b};assert snap->end->span->line=={line}&&snap->end->span->column=={col};let token:Lexeme=try lookup<Lexeme>(snap->tokens,0);assert token->text=="";assert (try spelling(snap,token))=='+literal('"x\\u{41}日"')+';};')
 source=r'''namespace Mgnc;
use Mgnc\Data\{Diagnostic,lookup};
use Mgnc\Source\{Snapshot,Lexeme,spelling};
use Mgnc\Lexical\{scanSource};
use Mgnc\Cursor\{Terminal,scanAt};
use Std\Io\{writeStderr};
let check:Function():Result<Unit,Diagnostic>=function():Result<Unit,Diagnostic>{
'''+"\n".join(checks)+r'''
Result<Unit,Diagnostic>::Ok(unit)
};
let main:Function(List<String>):Int=function(args:List<String>):Int{
branch on check(){Result<Unit,Diagnostic>::Ok(value:Unit)=>0,Result<Unit,Diagnostic>::Err(error:Diagnostic)=>{discard writeStderr(error->phase+": "+error->message+"\n");1}}
};
'''
 run_entry(args.seed,source)
 print(f"SHARED_LEXER_OK good={len(good)} negative={len(bad)} residual_cases={len(cases)}")
if __name__=='__main__':main()
