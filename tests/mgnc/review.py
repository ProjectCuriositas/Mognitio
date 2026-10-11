#!/usr/bin/env python3
"""Body boundaries, mixed comparisons and primary diagnostic locations."""
import argparse,hashlib,json,re,subprocess,tempfile
from pathlib import Path
ENTRY="namespace App;let main:Function(List<String>):Int=function(args:List<String>):Int{"
def fixtures():
    rows=[]
    def add(name,source,phase=None,exit=7,location=None):
        rows.append(dict(name=name,source=source,phase=phase,runtime_exit=exit,location=location))
    add("function-infix",ENTRY+"7}+1;","parse")
    add("function-postfix",ENTRY+"7}();","parse")
    add("helper-infix","namespace App;let f:Function():Int=function():Int{7}+1;"+ENTRY.split("namespace App;")[1]+"f()};","parse")
    add("while-equality",ENTRY+"let same:Bool=loop while(false){}==unit;branch when{same=>7,else=>9}};")
    add("while-inequality",ENTRY+"let same:Bool=loop while(false){}!=unit;branch when{same=>9,else=>7}};")
    add("while-left-operand",ENTRY+"let same:Bool=unit==loop while(false){};branch when{same=>7,else=>9}};")
    add("while-nested-tail",ENTRY+"let same:Bool=loop while(false){{unit}}==unit;branch when{same=>7,else=>9}};")
    add("ordinary-block",ENTRY+"let result:Int={7}+1;result};",exit=8)
    add("grouped-while",ENTRY+"let same:Bool=(loop while(false){})==unit;branch when{same=>7,else=>9}};")
    ops=["==","!=","<",">","<=",">="]
    for i,left in enumerate(ops):
        for j,right in enumerate(ops):
            # Parse rejection must precede any type error, in both operator orders.
            expression=f"true {left} 1 {right} 2"
            add(f"chain-{i}-{j}",ENTRY+"branch when{"+expression+"=>7,else=>9}};","parse")
    for index,expression in enumerate(["1<2","2>1","1<=1","2>=2","1==1","1!=2"]):
        for side,grouped in enumerate([f"true==({expression})",f"({expression})==true"]):
            add(f"group-{index}-{side}",ENTRY+"branch when{"+grouped+"=>7,else=>9}};")
    add("arithmetic-logical",ENTRY+"branch when{1+2*3==7 && !false || false=>7,else=>9}};")
    prefix="//日本語😀\r\n\t"+ENTRY
    for binding in ["let","var"]:
        source=prefix+f"{binding} value:Int=false;7}};"
        add(binding+"-initializer-span",source,"type",location="false")
    source=prefix+"var value:Int=1;value=false;7};"
    add("assignment-span",source,"type",location="false")
    source=prefix+"let value:Int=1;value=2;7};"
    add("immutable-name-span",source,"semantic",location="value=2")
    source=prefix+"let value:Int=1;{let value:Int=2;};7};"
    add("shadow-name-span",source,"semantic",location="value:Int=2")
    return rows
def main():
    ap=argparse.ArgumentParser();ap.add_argument("--compiler",required=True,type=Path)
    ap.add_argument("--evidence",required=True,type=Path);args=ap.parse_args()
    records=[]
    with tempfile.TemporaryDirectory(prefix="mgnc-review-") as temporary:
        root=Path(temporary)
        for case in fixtures():
            source=case["source"];path=root/(case["name"]+".mgn");path.write_bytes(source.encode())
            output=root/case["name"]
            result=subprocess.run([args.compiler.resolve(),"build",path,"-o",output],capture_output=True,timeout=120,umask=0o022)
            expected=1 if case["phase"] else 0
            okay=result.returncode==expected and result.stdout==b"" and output.exists()==(expected==0)
            if case["phase"]:okay=okay and ("mgnc: "+case["phase"]+":").encode() in result.stderr
            else:okay=okay and result.stderr==b""
            record=dict(fixture=case["name"],source=source,source_sha256=hashlib.sha256(source.encode()).hexdigest(),
                        expected_compile_exit=expected,expected_phase=case["phase"],compile_exit=result.returncode,
                        stdout_hex=result.stdout.hex(),stderr=result.stderr.decode().replace(str(root),"<fixture-root>"))
            if case["location"]:
                location=case["location"];start=source.index(location);text=location.split(":")[0].split("=")[0]
                before=source[:start];offset=len(before.encode());end=offset+len(text.encode())
                lines=re.split(r"\r\n|\r|\n",before);line=len(lines);column=len(lines[-1])+1
                record["expected_location"]=dict(start=offset,end=end,line=line,column=column)
                okay=okay and f"[{offset},{end})".encode() in result.stderr and f":{line}:{column}".encode() in result.stderr
            if output.exists():
                run=subprocess.run([output],capture_output=True,timeout=3)
                record.update(artifact_sha256=hashlib.sha256(output.read_bytes()).hexdigest(),runtime_exit=run.returncode,
                              runtime_stdout_hex=run.stdout.hex(),runtime_stderr_hex=run.stderr.hex())
                if expected==0:okay=okay and (run.returncode,run.stdout,run.stderr)==(case["runtime_exit"],b"",b"")
            record["pass"]=okay;records.append(record)
    evidence=dict(compiler_sha256=hashlib.sha256(args.compiler.read_bytes()).hexdigest(),
                  cases=records,passed=sum(row["pass"] for row in records),total=len(records))
    args.evidence.write_text(json.dumps(evidence,indent=2)+"\n")
    failed=[x["fixture"] for x in records if not x["pass"]]
    print(f"MGNC_REVIEW cases={len(records)} passed={evidence['passed']} failed={failed}")
    raise SystemExit(bool(failed))
if __name__=="__main__":main()
