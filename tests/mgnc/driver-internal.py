#!/usr/bin/env python3
"""Inject a phase invariant failure without exposing a production fault flag."""
import argparse,os,shutil,subprocess,tempfile
from pathlib import Path
from native import ENTRY
ROOT=Path(__file__).resolve().parents[2]
def main():
    parser=argparse.ArgumentParser();parser.add_argument("--seed",required=True,type=Path);args=parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="mgnc-driver-internal-") as temporary:
        work=Path(temporary);project=work/"project";shutil.copytree(ROOT/"compiler/mgnc",project)
        (project/"src/Pipeline/compile.mgn").write_text(r"""namespace Mgnc\Pipeline;
use Std\Binary\{Bytes};
use Mgnc\Data\{Diagnostic,Span,problem};
public let compile:Function(String):Result<Bytes,Diagnostic>=function(source:String):Result<Bytes,Diagnostic>{
 Result<Bytes,Diagnostic>::Err(problem("internal",Span{start:0,end:0,line:1,column:1},"injected phase invariant"))
};
""")
        image=work/"compiler";source=work/"input.mgn";source.write_text(ENTRY+"7};")
        build=subprocess.run([args.seed.resolve(),"build",project/"mognitio.toml","-o",image],capture_output=True,timeout=120)
        assert (build.returncode,build.stdout,build.stderr)==(0,b"",b""),build
        for closed,want in [(False,3),(True,2)]:
            result=subprocess.run([image,"build",source,"-o",work/"output"],capture_output=True,timeout=5,
                                  preexec_fn=(lambda:os.close(2)) if closed else None)
            assert result.returncode==want and result.stdout==b"",result
            if not closed:assert b"mgnc: internal:" in result.stderr and b"injected phase invariant" in result.stderr
            assert not (work/"output").exists()
    print("MGNC_INTERNAL_DRIVER_OK checks=2")
if __name__=="__main__":main()
