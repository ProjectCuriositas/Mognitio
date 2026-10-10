#!/usr/bin/env python3
"""Malformed IR must be rejected for its intended invariant, not a shape accident."""
import argparse
from pathlib import Path
import shutil, subprocess, tempfile
ROOT=Path(__file__).resolve().parents[2]
def ints(values): return "List<Int>["+",".join(map(str,values))+"]"
def instruction(kind,slot=0,inputs=(),immediate=0,targets=()):
    return f"make({kind},{slot},{ints(inputs)},{immediate},{ints(targets)})"
def function(blocks,types=(2,1,1),parameters=(0,),fid=0):
    flat=[];items=[]
    for label,ops,term in blocks:
        start=len(flat);flat+=ops
        items.append(f"Block{{id:{label},start:{start},end:{len(flat)},terminator:{term}}}")
    return f"makeFunction({fid},{ints(types)},{ints(parameters)},List<Instruction>["+",".join(flat)+"],List<Block>["+",".join(items)+"])"
def main():
    parser=argparse.ArgumentParser();parser.add_argument("--seed",required=True,type=Path);args=parser.parse_args()
    jump=lambda n:instruction(17,targets=(n,))
    branch=instruction(18,inputs=(0,),targets=(1,2))
    ret=instruction(19,inputs=(1,))
    const=instruction(1,slot=1,immediate=7)
    diamond=[(0,[],branch),(1,[const],jump(3)),(2,[const],jump(3)),(3,[],ret)]
    missing=[(0,[],branch),(1,[const],jump(3)),(2,[],jump(3)),(3,[],ret)]
    unreachable=diamond+[(4,[],jump(3))]
    dead_only=[(0,[],jump(3)),(3,[],ret),(4,[const],jump(3))]
    body_only=[(0,[],jump(3)),(3,[],branch),(1,[const],jump(3)),(2,[],ret)]
    earlier=[(0,[instruction(2,slot=2,inputs=(1,)),const],ret)]
    loop=[(0,[const],jump(3)),(3,[],branch),(1,[],jump(3)),(2,[],ret)]
    cases=[(diamond,True),(missing,False),(unreachable,True),(dead_only,False),
           (body_only,False),(earlier,False),(loop,True)]
    entry=function([(0,[const],ret)],types=(1,1),parameters=(0,),fid=1)
    checks=[]
    for blocks,expected in cases:
        tested=function(blocks)
        checks.append("checkCase("+tested+","+entry+","+str(expected).lower()+");")
    source=r"""namespace Mgnc;
use Mgnc\Data\{Paged,empty,push,Span,Diagnostic};
use Mgnc\IR\{Instruction,Block,FunctionIR,ModuleIR};
use Mgnc\Verify\{verify};
let make:Function(Int,Int,List<Int>,Int,List<Int>):Instruction=
function(kind:Int,slot:Int,inputs:List<Int>,immediate:Int,targets:List<Int>):Instruction{
 Instruction{kind:kind,slot:slot,inputs:inputs,immediate:immediate,targets:targets,span:Span{start:0,end:0,line:1,column:1}}
};
let makeFunction:Function(Int,List<Int>,List<Int>,List<Instruction>,List<Block>):FunctionIR=
function(id:Int,types:List<Int>,parameters:List<Int>,operations:List<Instruction>,blocks:List<Block>):FunctionIR{
 var slotTable:Paged<Int>=empty<Int>();
 loop over(types as value:Int){slotTable=push<Int>(slotTable,value);};
 var instructionTable:Paged<Instruction>=empty<Instruction>();
 loop over(operations as operation:Instruction){instructionTable=push<Instruction>(instructionTable,operation);};
 var blockTable:Paged<Block>=empty<Block>();
 loop over(blocks as block:Block){blockTable=push<Block>(blockTable,block);};
 FunctionIR{id:id,parameters:parameters,result:1,slots:slotTable,instructions:instructionTable,blocks:blockTable}
};
let checkCase:Function(FunctionIR,FunctionIR,Bool):Unit=function(tested:FunctionIR,entry:FunctionIR,expected:Bool):Unit{
 branch on verify(ModuleIR{functions:List<FunctionIR>[tested,entry],entry:1}){
 Result<Unit,Diagnostic>::Ok(value:Unit)=>{assert expected;},
 Result<Unit,Diagnostic>::Err(error:Diagnostic)=>{assert !expected;assert error->phase=="internal";assert error->message=="IR read before definition";}}
};
let main:Function(List<String>):Int=function(args:List<String>):Int{
"""+"\n".join(checks)+"\n0\n};\n"
    with tempfile.TemporaryDirectory(prefix="mgnc-ir-negative-") as temporary:
        work=Path(temporary);project=work/"project";shutil.copytree(ROOT/"compiler/mgnc",project)
        (project/"src/mgnc.mgn").write_text(source);image=work/"test"
        build=subprocess.run([args.seed.resolve(),"build",project/"mognitio.toml","-o",image],capture_output=True,timeout=120)
        assert (build.returncode,build.stdout,build.stderr)==(0,b"",b""),build.stderr
        result=subprocess.run([image],capture_output=True,timeout=30)
        assert (result.returncode,result.stdout,result.stderr)==(0,b"",b""),result.stderr
    print("MGNC_IR_DEFINITIONS_OK positive=3 negative=4")
if __name__=="__main__":main()
