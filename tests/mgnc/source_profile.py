#!/usr/bin/env python3
"""Run complete source-profile cases through the public compiler driver."""
import argparse,subprocess,tempfile
from pathlib import Path
from source_cases import cases,ENTRY
def main():
    parser=argparse.ArgumentParser();parser.add_argument("--compiler",required=True,type=Path);args=parser.parse_args()
    rows=cases()
    for body,phase in [("01","lexical"),("1abc","lexical"),("1<2<3","parse"),
                       ("let true:Int=1;0","parse"),("let x:int=1;0","semantic"),
                       ("let x:Int=1+;0","parse"),("let x:Int=1 0","parse"),
                       ("loop while(true){break;}0","parse")]:
        rows.append((ENTRY+body+"};",1,phase))
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
            if index>=boundary_start:
                run=subprocess.run([output],capture_output=True,timeout=3)
                assert (run.returncode,run.stdout,run.stderr)==(7,b"",b""),run
    print(f"MGNC_SOURCE_PROFILE_OK cases={len(rows)}")
if __name__=="__main__":main()
