#!/usr/bin/env python3
"""Bytes and explicit endian encoding: host/native parity and independent vectors."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "bin/mgn"
checks = 0

def run(args, code=0):
    global checks
    p = subprocess.run(list(map(str,args)), capture_output=True, timeout=60)
    checks += 1
    assert p.returncode == code, (args, code, p.returncode, p.stdout, p.stderr)
    if code == 0:
        assert p.stderr == b"", p.stderr
    return p

def vector(values):
    return "bytesFromBits(List<Bits<8>>[" + ",".join(f"Bits<8>{{{x}}}" for x in values) + "])"

def case(expression, value, error, yes, no):
    t = f"Result<{value},{error}>"
    return f"assert branch on {expression} {{{t}::Ok(x:{value})=>{yes},{t}::Err(e:{error})=>{no}}};"

with tempfile.TemporaryDirectory(prefix="mgn-bytes-") as temporary:
    root=Path(temporary)
    (root/"src").mkdir()
    manifest=root/"mognitio.toml"
    manifest.write_text('[project]\nname="app"\nroot_namespace="App"\n')
    path=root/"src/app.mgn"
    prefix="namespace App;\nuse Std\\Numeric\\{Bits,Signed,Unsigned};\nuse Std\\Binary\\{Bytes,bytesFromBits,bytesFromInts,ByteOrder,ByteValueError,BitWidthError,BinaryDecodeError};\n"
    def execute(body, declarations="", code=0):
        path.write_text(prefix+declarations+"\nlet main:Function(List<String>):Int=function(args:List<String>):Int{"+body+"};\n")
        a=run([CLI,"run",manifest],code)
        b=run([CLI,"build",manifest,"-o",root/"program"],0 if code==0 else code)
        if code==0:
            c=run([root/"program"])
            assert a.stdout==c.stdout==b""
        return b

    execute("let empty:Bytes="+vector([])+";assert empty->length()==0;assert empty=="+vector([])+";assert empty!="+vector([0])+";assert "+vector([1,2])+"!="+vector([2,1])+";assert empty->concat(empty)==empty;0")
    for start in range(0,256,32):
        values=list(range(start,start+32))
        body="let b:Bytes="+vector(values)+";assert b->length()==32;"
        body+=case("bytesFromInts(List<Int>["+",".join(map(str,values))+"])","Bytes","ByteValueError","x==b","false")
        for i,value in enumerate(values):
            body+=case(f"b->at({i})","Bits<8>","IndexError",f"x==Bits<8>{{{value}}}","false")
        execute(body+"0")
    body="let b:Bytes="+vector([0,255,128,65])+";"
    for index in (-9223372036854775808,-1,4,9223372036854775807):
        body+=case(f"b->at({index})","Bits<8>","IndexError","false",f"e->index==({index}) && e->length==4")
    for start,end in ((0,0),(0,4),(1,3),(4,4)):
        body+=case(f"b->slice({start},{end})","Bytes","SliceError","x=="+vector([0,255,128,65][start:end]),"false")
    for start,end in ((-1,0),(0,-1),(2,1),(0,5),(5,5),(-9223372036854775808,9223372036854775807)):
        body+=case(f"b->slice({start},{end})","Bytes","SliceError","false",f"e->start==({start}) && e->end==({end}) && e->length==4")
    body+="assert b->append(Bits<8>{0})==b->concat("+vector([0])+");assert b->concat("+vector([])+")==b;assert b->length()==4;"
    execute(body+"0")
    for values,index in (([-1,256],0),([0,256,-1],1),([255,-9223372036854775808],1),([9223372036854775807],0)):
        execute(case("bytesFromInts(List<Int>["+",".join(map(str,values))+"])","Bytes","ByteValueError","false",f"e->index=={index} && e->value==({values[index]})")+"0")
    execute(case("bytesFromInts(List<Int>[])","Bytes","ByteValueError","x=="+vector([]),"false")+"0")
    for width in range(8,65,8):
        body=""
        for value in (0,(1<<width)-1,int.from_bytes(bytes(range(1,width//8+1)),"big")):
            for order in ("LittleEndian","BigEndian"):
                octets=value.to_bytes(width//8,"little" if order=="LittleEndian" else "big")
                body+=case(f"Bits<{width}>{{{value}}}->toBytes(ByteOrder::{order})","Bytes","BitWidthError","x=="+vector(octets),"false")
                body+=case(vector(octets)+f"->toBits<{width}>(ByteOrder::{order})",f"Bits<{width}>","BinaryDecodeError",f"x==Bits<{width}>{{{value}}}","false")
        execute(body+"0")
    for width in (1,7,9,63):
        body=case(f"Bits<{width}>{{0}}->toBytes(ByteOrder::LittleEndian)","Bytes","BitWidthError","false",f"e->width=={width}")
        body+=case(vector([0])+f"->toBits<{width}>(ByteOrder::BigEndian)",f"Bits<{width}>","BinaryDecodeError","false",f"e->width=={width} && e->length==1")
        execute(body+"0")
    for values in ([],[0],[0,1,2]):
        execute(case(vector(values)+"->toBits<16>(ByteOrder::LittleEndian)","Bits<16>","BinaryDecodeError","false",f"e->width==16 && e->length=={len(values)}")+"0")
    execute("let b:Bytes="+vector([128,0,255])+";assert encode<24>(b);0",
            "template encode<N:Int>=function(b:Bytes):Bool{branch on b->toBits<N>(ByteOrder::BigEndian){Result<Bits<N>,BinaryDecodeError>::Ok(x:Bits<N>)=>true,Result<Bits<N>,BinaryDecodeError>::Err(e:BinaryDecodeError)=>false}};")
    for body in (
        "discard Bytes{};0",
        "discard bytesFromBits(List<Int>[0]);0",
        "discard bytesFromInts(List<Bits<8>>[]);0",
        "discard "+vector([])+"->append(1);0",
        "discard "+vector([])+"->toBits<0>(ByteOrder::LittleEndian);0",
        "discard "+vector([])+"->toBits<65>(ByteOrder::LittleEndian);0",
        "discard "+vector([])+"->toBits<Int>(ByteOrder::LittleEndian);0",
        "discard "+vector([])+"->toBits<8>(1);0",
        "discard "+vector([])+" + "+vector([])+";0",
        "discard "+vector([])+" < "+vector([])+";0",
    ):
        execute(body,code=1)
print(f"BYTES_ENCODING_OK checks={checks}")
