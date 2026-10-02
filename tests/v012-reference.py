"""The distributed converter, including source-absent execution and Mognitio tests."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[1]
checks=0
def run(args,code=0,out=b"",err=b"",**kwargs):
    global checks
    p=subprocess.run(args,capture_output=True,timeout=30,**kwargs)
    assert (p.returncode,p.stdout,p.stderr)==(code,out,err),(args,p.returncode,p.stdout,p.stderr)
    checks+=1

with tempfile.TemporaryDirectory(prefix="mgn-v012-reference-") as temporary:
    base=Path(temporary);project=base/"project"
    shutil.copytree(ROOT/"examples/file-converter",project)
    manifest=project/"mognitio.toml";image=base/"converter"
    run([ROOT/"bin/mgn","build",manifest,"-o",image])
    for i,(args,data,code,out,err) in enumerate([
        (["input","output"],b"hello",0,b"converted\n",b""),
        ([],b"hello",2,b"",b"usage: convert INPUT OUTPUT\n"),
        (["missing","output"],b"hello",1,b"",b"conversion failed\n"),
        (["input","output"],b"\xff",1,b"",b"conversion failed\n"),
        (["input","missing/output"],b"hello",1,b"",b"conversion failed\n"),
    ]):
        for backend in ["cl","native"]:
            cwd=base/f"{i}-{backend}";cwd.mkdir();(cwd/"input").write_bytes(data)
            (cwd/"output").write_bytes(b"original longer content remains on failed read")
            command=[ROOT/"bin/mgn","run",manifest,"--",*args] if backend=="cl" else [image,*args]
            run(command,code,out,err,cwd=cwd)
            assert (cwd/"input").read_bytes()==data
            if code==0:assert (cwd/"output").read_bytes()==b"# Converted\nhello"
            else:assert (cwd/"output").read_bytes()==b"original longer content remains on failed read"
    fixtures=project/"fixtures";fixtures.mkdir();(fixtures/"input.txt").write_bytes(b"hello")
    p=subprocess.run([ROOT/"bin/mgn","test",manifest],capture_output=True,timeout=30,cwd=project)
    assert p.returncode==0 and not p.stderr and b"total=2 passed=2" in p.stdout,(p.returncode,p.stdout,p.stderr)
    assert (fixtures/"output.txt").read_bytes()==b"# Converted\nhello"
    checks+=1
    shutil.rmtree(project)
    for content in [b"new",b"changed again"]:
        (base/"input").write_bytes(content)
        run([image,"input","output"],out=b"converted\n",cwd=base,env={"PATH":"/not-present"})
        assert (base/"output").read_bytes()==b"# Converted\n"+content

print(f"v0.12 reference checks={checks} failures=0")
