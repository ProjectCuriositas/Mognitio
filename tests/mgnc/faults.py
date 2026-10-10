#!/usr/bin/env python3
"""Publication failure phases observed on the exact compiler executable."""
import argparse,hashlib,re,subprocess,sys,tempfile
from pathlib import Path
from native import ENTRY,elf
def main():
    parser=argparse.ArgumentParser();parser.add_argument("--compiler",required=True,type=Path)
    args=parser.parse_args();compiler=args.compiler.resolve();checks=0
    with tempfile.TemporaryDirectory(prefix="mgnc-faults-") as temporary:
        root=Path(temporary);source=root/"input.mgn";source.write_text(ENTRY+"7};")
        trace=root/"trace";normal=root/"normal"
        baseline=subprocess.run(["strace","-qq","-o",trace,compiler,"build",source,"-o",normal],capture_output=True,timeout=120)
        assert (baseline.returncode,baseline.stdout,baseline.stderr)==(0,b"",b"")
        lines=trace.read_text().splitlines()
        close_positions=[i for i,line in enumerate(lines) if line.startswith("close(")]
        commit=next(i for i,line in enumerate(lines) if line.startswith("renameat2("))
        file_close=max(i for i in close_positions if i<commit)
        parent_close=min(i for i in close_positions if i>commit)
        cases=[("read",0,1,False,2,b"io:",False),
               ("write",1,1,False,2,b"Other / Body / NotPublished",False),
               ("close-file",3,close_positions.index(file_close)+1,True,2,b"Other / Cleanup / NotPublished",False),
               ("commit",316,1,False,2,b"Other / Publish / Unknown",False),
               ("commit-reply",316,1,True,2,b"Other / Publish / Unknown",True),
               ("close-parent",3,close_positions.index(parent_close)+1,True,2,b"Other / Cleanup / Published",True),
               ("allocation",9,1,False,4,b"runtime error:",False)]
        for name,number,ordinal,after,want,message,published in cases:
            output=root/name
            command=[sys.executable,Path(__file__).with_name("syscall-fault.py"),"--syscall",str(number),
                     "--ordinal",str(ordinal),"--errno","12" if name=="allocation" else "5"]
            if after:command+=["--after"]
            result=subprocess.run(command+["--",compiler,"build",source,"-o",output],capture_output=True,timeout=120)
            assert result.returncode==want and result.stdout==b"" and message in result.stderr,(name,result)
            assert output.exists()==published,(name,published)
            if published:elf(output.read_bytes());assert output.read_bytes()==normal.read_bytes()
            assert not list(root.glob(".mgn-*")),(name,list(root.iterdir()))
            checks+=1
        large=root/"large.mgn"
        declarations="".join(f"let helper{i}:Function(Int):Int=function(value:Int):Int{{value+1}};" for i in range(1000))
        large.write_text(ENTRY.replace("namespace App;","namespace App;"+declarations)+"7};")
        try:subprocess.run([compiler,"build",large,"-o",root/"timed-output"],capture_output=True,timeout=.01)
        except subprocess.TimeoutExpired:checks+=1
        else:raise AssertionError("expected compiler harness timeout")
        assert not (root/"timed-output").exists()
        # Harness termination is not a source diagnostic or normal compiler exit.
        forever=root/"forever.mgn";forever.write_text(ENTRY+"loop while(true){};0};")
        built=subprocess.run([compiler,"build",forever,"-o",root/"forever"],capture_output=True,timeout=120)
        assert (built.returncode,built.stdout,built.stderr)==(0,b"",b"")
        try:subprocess.run([root/"forever"],capture_output=True,timeout=.05)
        except subprocess.TimeoutExpired:checks+=1
        else:raise AssertionError("expected independent harness timeout")
    print(f"MGNC_FAULTS_OK checks={checks}")
if __name__=="__main__":main()
