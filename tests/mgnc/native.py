#!/usr/bin/env python3
"""End-to-end scalar native execution with independent arithmetic and ELF oracles."""
import argparse, hashlib, json, os, stat, struct, subprocess, tempfile
from pathlib import Path

ENTRY = "namespace App;let main:Function(List<String>):Int=function(args:List<String>):Int{"
OVERFLOW = b"runtime error: integer overflow\n"
DIVISION = b"runtime error: division by zero\n"
EXIT = b"runtime error: invalid exit status\n"
UTF8 = b"runtime: invalid UTF-8 runtime argument\n"

def elf(data):
    assert data[:16] == b"\x7fELF\x02\x01\x01" + bytes(9)
    h = struct.unpack_from("<HHIQQQIHHHHHH", data, 16)
    assert h == (2, 62, 1, 0x400078, 64, 0, 0, 64, 56, 1, 0, 0, 0), h
    ph = struct.unpack_from("<IIQQQQQQ", data, 64)
    assert ph == (1, 5, 0, 0x400000, 0x400000, len(data), len(data), 4096), ph
    assert h[3] == ph[3] + 120 and data[120:123] == b"\x4c\x8b\x24"

def run(image, argv=(), fault=None, timeout=3):
    read_fd = write_fd = None
    preexec = None
    stderr = subprocess.PIPE
    if fault == "closed":
        preexec = lambda: os.close(2)
    elif fault == "pipe":
        read_fd, write_fd = os.pipe()
        os.close(read_fd)
        stderr = write_fd
    try:
        result = subprocess.run([image, *argv], stdout=subprocess.PIPE, stderr=stderr,
                                preexec_fn=preexec, timeout=timeout)
    finally:
        if write_fd is not None:
            os.close(write_fd)
    return result

def cases():
    values = [("zero", "0", 0, b""), ("seven", "7", 7, b""), ("max-exit", "255", 255, b""),
              ("argc", "args->length()", 3, b""), ("invalid-low", "-1", 4, EXIT),
              ("invalid-high", "256", 4, EXIT)]
    comparisons = ["-7/3 == -2", "-7%3 == -1", "7%-3 == 1",
                   "-9223372036854775808%-1 == 0", "-9223372036854775808 < 0",
                   "9223372036854775807 > 0", "3<=3", "3>=3", "3!=4",
                   "!(3==4)", "(true==true)", "(unit==unit)", "(false!=true)"]
    for i, expression in enumerate(comparisons):
        values.append((f"compare-{i}", "branch when{"+expression+"=>7,else=>99}", 7, b""))
    for i, expression in enumerate(["9223372036854775807+1", "-9223372036854775808-1",
                                   "9223372036854775807*2", "--9223372036854775808",
                                   "-9223372036854775808/-1"]):
        values.append((f"overflow-{i}", expression, 4, OVERFLOW))
    for i, expression in enumerate(["1/0", "1%0"]):
        values.append((f"zero-div-{i}", expression, 4, DIVISION))
    values += [
        ("operand-order", "var x:Int=1;let v:Int={x=x+1;x}*{x=x+1;x};v+x", 9, b""),
        ("snapshot-left", "var x:Int=1;let v:Int=x+{x=5;x};v", 6, b""),
        ("first-failure", "discard (1/0)+(9223372036854775807+1);0", 4, DIVISION),
        ("short-and", "discard false && (1/0==0);7", 7, b""),
        ("short-or", "discard true || (1/0==0);7", 7, b""),
        ("branch-order", "var x:Int=0;let y:Int=branch when{{x=x+1;true}=>7,{x=99;true}=>9,else=>11};x+y", 8, b""),
        ("non-completion", "let v:Int=1+{return 7;};", 7, b""),
        ("loop", "let limit:Int=args->length();var i:Int=0;loop while(i<limit){i=i+1;};i", 3, b""),
        ("loop-control", "var i:Int=0;var total:Int=0;loop while(i<5){i=i+1;branch when{i==2=>{continue;},else=>unit};branch when{i==4=>{break;},else=>unit};total=total+i;};total", 4, b""),
        ("loop-return", "loop while(true){return 7;};0", 7, b""),
        ("nested", "var i:Int=0;var j:Int=0;loop while(i<3){i=i+1;loop while(true){j=j+1;break;};};j", 3, b""),
        ("condition-break", "var visits:Int=0;loop while(visits<2){visits=visits+1;loop while({break;}){};};visits", 1, b""),
        ("condition-continue", "var visits:Int=0;loop while(visits<2){visits=visits+1;loop while({continue;}){};};visits", 2, b""),
        ("unselected-overflow", "branch when{true=>7,else=>9223372036854775807+1}", 7, b""),
        ("unit", "let value:Unit={unit};discard value==unit;7", 7, b""),
    ]
    result = [(name, ENTRY+body+"};", want, diagnostic) for name, body, want, diagnostic in values]
    helpers = [
        ("call-order", "let pair:Function(Int,Int):Int=function(a:Int,b:Int):Int{a*10+b};",
         "var x:Int=0;pair({x=x+1;x},{x=x+1;x})", 12),
        ("call-snapshot", "let pair:Function(Int,Int):Int=function(a:Int,b:Int):Int{a*10+b};",
         "var x:Int=1;pair(x,{x=3;x})", 13),
        ("unit-call", "let done:Function():Unit=function():Unit{unit};", "done();7", 7),
        ("bool-call", "let yes:Function(Bool):Bool=function(b:Bool):Bool{!b};",
         "branch when{yes(false)=>7,else=>9}", 7),
        ("nested-call", "let inc:Function(Int):Int=function(x:Int):Int{x+1};let two:Function(Int):Int=function(x:Int):Int{inc(inc(x))};",
         "(two)((args)->length())", 5),
        ("many-args", "let total:Function(Int,Int,Int,Int,Int,Int,Int,Int):Int=function(a:Int,b:Int,c:Int,d:Int,e:Int,f:Int,g:Int,h:Int):Int{a+b+c+d+e+f+g+h};",
         "total(1,2,3,4,5,6,7,8)", 36),
    ]
    for name, helpers_source, body, want in helpers:
        result.append((name, ENTRY.replace("namespace App;", "namespace App;"+helpers_source)+body+"};", want, b""))
    return result

def main():
    parser=argparse.ArgumentParser();parser.add_argument("--compiler",required=True,type=Path)
    parser.add_argument("--seed",type=Path);parser.add_argument("--evidence",type=Path);args=parser.parse_args()
    count=0;records=[]
    with tempfile.TemporaryDirectory(prefix="mgnc-native-") as temporary:
        work=Path(temporary);compiler=args.compiler.resolve()
        for name,source,want,diagnostic in cases():
            path=work/(name+".mgn");path.write_text(source);image=work/name
            built=subprocess.run([compiler,"build",path,"-o",image],capture_output=True,timeout=120)
            assert (built.returncode,built.stdout,built.stderr)==(0,b"",b""),(name,built.stderr)
            data=image.read_bytes();elf(data)
            result=run(image,["a","b","c"])
            assert (result.returncode,result.stdout,result.stderr)==(want,b"",diagnostic),(name,result)
            records.append(dict(fixture=name,source_sha256=hashlib.sha256(source.encode()).hexdigest(),
                                artifact_sha256=hashlib.sha256(data).hexdigest(),mode=oct(stat.S_IMODE(image.stat().st_mode)),
                                argv_hex=[b"a".hex(),b"b".hex(),b"c".hex()],exit=result.returncode,
                                stdout_hex=result.stdout.hex(),stderr_hex=result.stderr.hex()))
            count+=1
            if args.seed:
                project=work/(name+"-project");(project/"src").mkdir(parents=True)
                (project/"mognitio.toml").write_text('[project]\nname="app"\nroot_namespace="App"\n')
                (project/"src/app.mgn").write_text(source)
                old=work/(name+"-old")
                built=subprocess.run([args.seed.resolve(),"build",project/"mognitio.toml","-o",old],capture_output=True,timeout=120)
                assert (built.returncode,built.stdout,built.stderr)==(0,b"",b""),(name,"seed",built.stderr)
                result=run(old,["a","b","c"])
                assert (result.returncode,result.stdout,result.stderr)==(want,b"",diagnostic),(name,"seed",result)
                records[-1]["seed_equal"]=True
                records[-1]["seed_artifact_sha256"]=hashlib.sha256(old.read_bytes()).hexdigest()
        for replacement in [0x78,0x400079]:
            data=bytearray((work/"seven").read_bytes());struct.pack_into("<Q",data,24,replacement)
            try:elf(data)
            except AssertionError:count+=1
            else:raise AssertionError("entry oracle accepted corrupted entry")
        valid=[b"",b" ",b"--","日本語".encode(),b"\x7f",b"\xc2\x80",b"\xdf\xbf",b"\xe0\xa0\x80",
               b"\xed\x9f\xbf",b"\xee\x80\x80",b"\xef\xbf\xbf",b"\xf0\x90\x80\x80",b"\xf4\x8f\xbf\xbf"]
        invalid=[b"\x80",b"\xbf",b"\xc0\x80",b"\xc1\xbf",b"\xc2",b"\xe0\x9f\xbf",
                 b"\xed\xa0\x80",b"\xf0\x8f\xbf\xbf",b"\xf4\x90\x80\x80",b"\xf5\x80\x80\x80",b"\xff",
                 b"\xe1",b"\xe1\x80",b"\xf1\x80\x80",b"\xc2a",b"\xe1\x80a",b"\xf1\x80\x80a"]
        for raw in valid+invalid:
            want,diagnostic=(7,b"") if raw in valid else (2,UTF8)
            result=run(work/"seven",[b"a",raw,b"b"])
            assert (result.returncode,result.stdout,result.stderr)==(want,b"",diagnostic),(raw,result)
            records.append(dict(fixture="seven",argv_hex=[b"a".hex(),raw.hex(),b"b".hex()],
                                exit=result.returncode,stdout_hex=result.stdout.hex(),stderr_hex=result.stderr.hex()))
            count+=1
        for fault in ["closed","pipe"]:
            for name,argv,want in [("seven",[],7),("zero-div-0",[],4),("overflow-0",[],4),("seven",[b"\xff"],2)]:
                result=run(work/name,argv,fault)
                assert result.returncode==want and result.stdout==b"",(fault,name,result)
                records.append(dict(fixture=name,argv_hex=[arg.hex() for arg in argv],stderr_fault=fault,
                                    exit=result.returncode,stdout_hex=result.stdout.hex()))
                count+=1
        path=work/"forever.mgn";path.write_text(ENTRY+"loop while(true){};0};")
        built=subprocess.run([compiler,"build",path,"-o",work/"forever"],capture_output=True,timeout=120)
        assert (built.returncode,built.stdout,built.stderr)==(0,b"",b"")
        for name in ["seven","loop","nested-call"]:
            source=work/(name+".mgn");copy=work/(name+" copy.mgn");copy.write_bytes(source.read_bytes())
            built=subprocess.run([compiler,"build",copy,"-o",work/(name+"-copy")],capture_output=True,timeout=120)
            assert (built.returncode,built.stdout,built.stderr)==(0,b"",b"")
            assert (work/name).read_bytes()==(work/(name+"-copy")).read_bytes()
            count+=1
    if args.evidence:
        args.evidence.write_text(json.dumps(dict(compiler_sha256=hashlib.sha256(args.compiler.read_bytes()).hexdigest(),
                                                checks=count,records=records),indent=2)+"\n")
    print(f"MGNC_NATIVE_OK checks={count} differential={bool(args.seed)}")
if __name__=="__main__":main()
