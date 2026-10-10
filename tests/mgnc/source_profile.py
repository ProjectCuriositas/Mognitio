#!/usr/bin/env python3
"""Run complete source-profile cases through the public compiler driver."""
import argparse,hashlib,json,stat,subprocess,tempfile
from pathlib import Path
from source_cases import cases,ENTRY
def main():
    parser=argparse.ArgumentParser();parser.add_argument("--compiler",required=True,type=Path);parser.add_argument("--evidence",type=Path);args=parser.parse_args()
    rows=cases();records=[]
    for body,phase in [("01","lexical"),("1abc","lexical"),("1<2<3","parse"),
                       ("let true:Int=1;0","parse"),("let x:int=1;0","semantic"),
                       ("let x:Int=1+;0","parse"),("let x:Int=1 0","parse"),
                       ("loop while(true){break;}0","parse")]:
        rows.append((ENTRY+body+"};",1,phase))
    rows += [("",1,"parse"),("let main:Function(List<String>):Int=function(args:List<String>):Int{7};",1,"parse"),
             ("namespace App; unit;",1,"parse"),(ENTRY+"7",1,"parse"),
             (ENTRY+"discard false && (1+true==0);0};",1,"type"),
             (ENTRY+"let inner:Function():Int=function():Int{7};0};",1,"unsupported"),
             ("namespace App; use Std\\\\Io\\\\{writeStdout};"+ENTRY.split("namespace App;")[1]+"0};",1,"unsupported"),
             ("namespace App; template identity<T>=function(value:T):T{value};"+ENTRY.split("namespace App;")[1]+"0};",1,"unsupported")]
    boundary_start=len(rows)
    prefixes=[" "*1023+"//日本語😀\n"+ENTRY+"7};",
              "//"+"x"*1021+"\r\n"+ENTRY+"7};"]
    prefix=ENTRY+"let "
    prefixes.append(prefix+" "*(1023-len(prefix))+"identifier"+"x"*54+":Int=7;7};")
    prefix=ENTRY+"let value:Int="
    prefixes.append(prefix+" "*(1023-len(prefix))+"9223372036854775807;7};")
    prefix=ENTRY+"branch when{1 "
    prefixes.append(prefix+" "*(1023-len(prefix))+"<=2=>7,else=>9}};")
    rows.extend((source,0,None) for source in prefixes)
    with tempfile.TemporaryDirectory(prefix="mgnc-profile-") as temporary:
        work=Path(temporary)
        for index,(source,want,phase) in enumerate(rows):
            path=work/f"case-{index}.mgn";path.write_text(source);output=work/f"case-{index}"
            result=subprocess.run([args.compiler.resolve(),"build",path,"-o",output],capture_output=True,timeout=120)
            assert result.returncode==want and result.stdout==b"",(index,source,result)
            assert (result.stderr==b"") if phase is None else f"mgnc: {phase}:".encode() in result.stderr,(index,source,result.stderr)
            assert output.exists()==(want==0)
            row=dict(fixture=f"case-{index}",source_sha256=hashlib.sha256(source.encode()).hexdigest(),
                     exit=result.returncode,stdout_hex=result.stdout.hex(),
                     stderr_text=result.stderr.decode().replace(str(work),"<fixture-root>"),
                     stderr_sha256=hashlib.sha256(result.stderr).hexdigest())
            if output.exists():row.update(artifact_sha256=hashlib.sha256(output.read_bytes()).hexdigest(),
                                          mode=oct(stat.S_IMODE(output.stat().st_mode)))
            records.append(row)
            if index>=boundary_start:
                run=subprocess.run([output],capture_output=True,timeout=3)
                assert (run.returncode,run.stdout,run.stderr)==(7,b"",b""),run
    if args.evidence:
        args.evidence.write_text(json.dumps(dict(compiler_sha256=hashlib.sha256(args.compiler.read_bytes()).hexdigest(),
                                                records=records),indent=2)+"\n")
    print(f"MGNC_SOURCE_PROFILE_OK cases={len(rows)}")
if __name__=="__main__":main()
