#!/usr/bin/env python3
"""Independent byte vectors and invalid machine records exercise the encoder."""
import argparse,shutil,subprocess,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
def main():
    parser=argparse.ArgumentParser();parser.add_argument("--seed",required=True,type=Path);args=parser.parse_args()
    source=r"""namespace Mgnc;
use Std\Numeric\{Bits};
use Std\Binary\{Bytes,bytesFromBits,BinaryOutputError,BinaryOutputErrorKind,BinaryOutputPhase,BinaryPublicationState};
use Mgnc\Data\{Span,Diagnostic,empty};
use Mgnc\Fields\{i32,i64,u16,u32,u64};
use Mgnc\Machine\{Code,Record,raw,label,reference,field};
use Mgnc\Encode\{encode};
use Mgnc\Driver\{publicationMessage};
let main:Function(List<String>):Int=function(args:List<String>):Int{
let span:Span=Span{start:0,end:0,line:1,column:1};
"""
    checks=0
    for func,width,signed,values in [("i32",4,True,[-2**31,-1,0,2**31-1]),
                                   ("i64",8,True,[-2**63,-1,0,2**63-1]),
                                   ("u16",2,False,[0,1,65535]),("u32",4,False,[0,2**32-1]),
                                   ("u64",8,False,[0,2**63-1])]:
        for value in values:
            expected=value.to_bytes(width,"little",signed=signed)
            vector="bytesFromBits(List<Bits<8>>["+",".join(f"Bits<8>{{{b}}}" for b in expected)+"])"
            source+=f"assert branch on {func}({value},span){{Result<Bytes,Diagnostic>::Ok(b:Bytes)=>b=={vector},Result<Bytes,Diagnostic>::Err=>false}};\n";checks+=1
    for func,value in [("i32",2**31),("i32",-2**31-1),("u16",-1),("u16",65536),("u32",2**32),("u64",-1)]:
        source+=f"assert branch on {func}({value},span){{Result<Bytes,Diagnostic>::Ok=>false,Result<Bytes,Diagnostic>::Err(d:Diagnostic)=>d->phase==\"internal\"}};\n";checks+=1
    source+="let base:Code=Code{records:empty<Record>(),nextLabel:2};\n"
    bad=["label(label(base,0),0)","label(base,2)","reference(label(base,0),2,1)",
         "label(raw(base,List<Int>[144]),0)","raw(label(base,0),List<Int>[256])",
         "field(label(base,0),3,2147483648)"]
    for code in bad:
        source+=f'assert branch on encode({code}){{Result<Bytes,Diagnostic>::Ok=>false,Result<Bytes,Diagnostic>::Err(d:Diagnostic)=>d->phase=="internal"}};\n';checks+=1
    for state in ["NotPublished","Published","Unknown"]:
        expected=f"mgnc: publication: output: Other / Cleanup / {state}\\n"
        source+=f'assert publicationMessage(BinaryOutputError{{kind:BinaryOutputErrorKind::Other,phase:BinaryOutputPhase::Cleanup,publication:BinaryPublicationState::{state},subject:"output"}})=="{expected}";\n';checks+=1
    source+="0};\n"
    with tempfile.TemporaryDirectory(prefix="mgnc-encoding-") as temporary:
        work=Path(temporary);project=work/"project";shutil.copytree(ROOT/"compiler/mgnc",project)
        (project/"src/mgnc.mgn").write_text(source);image=work/"test"
        built=subprocess.run([args.seed.resolve(),"build",project/"mognitio.toml","-o",image],capture_output=True,timeout=120)
        assert (built.returncode,built.stdout,built.stderr)==(0,b"",b""),built.stderr
        result=subprocess.run([image],capture_output=True,timeout=30)
        assert (result.returncode,result.stdout,result.stderr)==(0,b"",b""),result
    print(f"MGNC_ENCODING_OK checks={checks}")
if __name__=="__main__":main()
