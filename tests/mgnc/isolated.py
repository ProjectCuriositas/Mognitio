#!/usr/bin/env python3
"""A-to-X compilation and standalone execution in fixed minimal Ubuntu userlands."""
import argparse,hashlib,json,os,stat,subprocess,tempfile
from pathlib import Path
from native import cases,elf
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def prefix(root,image,output):
    assert os.getuid()!=0
    for name in ["mgn","mgnc","sbcl","gcc","g++","cc","clang","as","ld","ld.lld","python3"]:
        assert not any((root/d/name).exists() for d in ["bin","usr/bin","usr/local/bin"]),name
    return ["bwrap","--unshare-user","--uid",str(os.getuid()),"--gid",str(os.getgid()),
            "--unshare-pid","--unshare-net","--unshare-ipc","--die-with-parent",
            "--ro-bind",root,"/","--proc","/proc","--dev","/dev",
            "--ro-bind",image,"/emitter","--bind",output,"/output","--chdir","/output",
            "--clearenv","--setenv","PATH","/unavailable"]
def main():
    parser=argparse.ArgumentParser();parser.add_argument("--compiler",required=True,type=Path)
    parser.add_argument("--userland",action="append",required=True,type=Path)
    parser.add_argument("--evidence",required=True,type=Path);args=parser.parse_args()
    records=[];environments=[]
    with tempfile.TemporaryDirectory(prefix="mgnc-isolated-") as temporary:
        work=Path(temporary);empty=work/"empty";empty.mkdir()
        for environment in args.userland:
            environment=environment.resolve();release=(environment/"etc/os-release").read_text()
            assert 'VERSION_ID="24.04"' in release or 'VERSION_ID="26.04"' in release,release
            inventory=[]
            for path in sorted(environment.rglob("*")):
                if path.is_symlink():inventory.append([str(path.relative_to(environment)),"link",os.readlink(path)])
                elif path.is_file():inventory.append([str(path.relative_to(environment)),stat.S_IMODE(path.stat().st_mode),digest(path)])
            identity=hashlib.sha256(json.dumps(inventory,sort_keys=True).encode()).hexdigest()
            environments.append(dict(name=environment.name,os_release=release,inventory_sha256=identity,files=len(inventory)))
            for name,source,want,stderr in cases():
                output=work/(environment.name+"-"+name);output.mkdir()
                path=output/"input.mgn";path.write_text(source);image=output/"program"
                build=subprocess.run(prefix(environment,args.compiler.resolve(),output)+["/emitter","build","input.mgn","-o","program"],
                                     capture_output=True,timeout=120,umask=0o022)
                assert (build.returncode,build.stdout,build.stderr)==(0,b"",b""),(environment.name,name,build)
                elf(image.read_bytes());assert stat.S_IMODE(image.stat().st_mode)==0o755
                result=subprocess.run(prefix(environment,image,empty)+["/emitter","a","b","c"],
                                      capture_output=True,timeout=3)
                assert (result.returncode,result.stdout,result.stderr)==(want,b"",stderr),(environment.name,name,result)
                records.append(dict(environment=environment.name,fixture=name,source_sha256=digest(path),
                                    artifact_sha256=digest(image),mode="0755",exit=result.returncode,
                                    stdout_hex=result.stdout.hex(),stderr_hex=result.stderr.hex()))
        trace=work/"exec.trace";source=work/"input.mgn";source.write_text(cases()[0][1])
        result=subprocess.run(["strace","-f","-qq","-e","trace=execve,execveat","-o",trace,args.compiler.resolve(),
                               "build",source,"-o",work/"traced"],capture_output=True,timeout=120)
        assert (result.returncode,result.stdout,result.stderr)==(0,b"",b"")
        assert len(trace.read_text().splitlines())==1,trace.read_text()
    evidence=dict(compiler_sha256=digest(args.compiler),kernel=os.uname().release,nonroot=os.getuid()!=0,
                  environments=environments,records=records,compiler_exec_count=1)
    args.evidence.write_text(json.dumps(evidence,indent=2)+"\n")
    print(f"MGNC_ISOLATED_OK cases={len(records)} environments={len(environments)}")
if __name__=="__main__":main()
