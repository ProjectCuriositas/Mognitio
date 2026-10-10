#!/usr/bin/env python3
"""Deterministic compile-scale cells and independent runtime expectations."""
import argparse, hashlib, json, re
from pathlib import Path
ENTRY = "let main:Function(List<String>):Int=function(args:List<String>):Int{"
def helper(name,body):
    return f"let {name}:Function(Int):Int=function(value:Int):Int{{{body}}};\n"
def nested_branch(depth,tail,otherwise="11"):
    for _ in range(depth):
        tail="branch when{args->length()==0=>{"+tail+"},else=>"+otherwise+"}"
    return tail
def generate(family,size,long_names=False):
    def name(prefix,i):
        short=f"{prefix}{i}"
        return short+"x"*(64-len(short)) if long_names else short
    declarations=""
    if family=="bindings":
        body="let "+name("v",0)+":Int=args->length();"
        for i in range(1,size+1):body+=f"let {name('v',i)}:Int={name('v',i-1)}+1;"
        body+=name("v",size)+"%251"
        expected=[(k+size)%251 for k in [0,1,3]]
    elif family=="helpers":
        declarations="".join(helper(name("h",i),"value+1") for i in range(size))
        body=name("h",size-1)+"(args->length())";expected=[1,2,4]
    elif family=="blocks":
        body="{"*size+"args->length()"+"}"*size;expected=[0,1,3]
    elif family=="branches":
        body=nested_branch(size,"7");expected=[7,11,11]
    elif family=="call-chain":
        for i in range(size):
            declarations+=helper(name("h",i),"value+1" if i==0 else name("h",i-1)+"(value)+1")
        body=name("h",size-1)+"(args->length())%251";expected=[(k+size)%251 for k in [0,1,3]]
    else:
        for i in range(1000):
            declarations+=helper(name("h",i),name("h",i-1)+"(value)+1" if 0<i<128 else "value+1")
        body=f"let {name('v',0)}:Int={name('h',127)}(args->length());"
        for i in range(1,1001):body+=f"let {name('v',i)}:Int={name('v',i-1)}+1;"
        body+="let blocked:Int="+"{"*128+name("v",1000)+"}"*128+";"
        body+="("+nested_branch(128,"blocked","blocked")+")%251"
        expected=[(k+1128)%251 for k in [0,1,3]]
    return "namespace App;\n"+declarations+ENTRY+body+"};\n",expected
def main():
    parser=argparse.ArgumentParser();parser.add_argument("--output",required=True,type=Path)
    args=parser.parse_args();args.output.mkdir(parents=True,exist_ok=True);rows=[]
    cells=[(family,size) for family in ["bindings","helpers"] for size in [10,100,1000]]
    cells += [(family,size) for family in ["blocks","branches","call-chain"] for size in [1,8,32,128]]
    cells += [("combined",1000),("combined-long",1000),("combined-comment",1000)]
    for family,size in cells:
        source,expected=generate(family,size,family=="combined-long")
        if family=="combined-comment":
            unit="ascii 日本語 😀 "
            comment="//"+unit*((65536+len(unit.encode())-1)//len(unit.encode()))+"\n"
            source=comment+source
        data=source.encode();name=f"{family}-{size}";(args.output/(name+".mgn")).write_bytes(data)
        rows.append(dict(name=name,family=family,size=size,bytes=len(data),scalars=len(source),
                         sha256=hashlib.sha256(data).hexdigest(),argv_counts=[0,1,3],expected=expected,
                         tokens=1+len([token for token in re.findall(r"//[^\r\n]*|->|=>|==|!=|<=|>=|&&|\|\||::|[A-Za-z_][A-Za-z_0-9]*|[0-9]+|\S",source) if not token.startswith("//")]),
                         declared_bindings=len(re.findall(r"\blet\b",source)),
                         block_extra_depth=size if family=="blocks" else 128 if family.startswith("combined") else 0,
                         branch_extra_depth=size if family=="branches" else 128 if family.startswith("combined") else 0,
                         call_chain_depth=size if family=="call-chain" else 128 if family.startswith("combined") else 1 if family=="helpers" else 0))
    (args.output/"manifest.json").write_text(json.dumps(rows,indent=2)+"\n")
    print(f"MGNC_SCALE_FIXTURES_OK cells={len(rows)}")
if __name__=="__main__":main()
