#!/usr/bin/env python3
"""Independent ELF oracle and standalone Mognitio emitter workload."""
from pathlib import Path
import argparse, hashlib, json, os, shutil, stat, struct, subprocess, tempfile

ROOT=Path(__file__).resolve().parents[1]
checks=0
def run(args,code=0,out=b"",**kwargs):
    global checks
    p=subprocess.run(list(map(str,args)),capture_output=True,timeout=60,**kwargs)
    checks+=1
    assert (p.returncode,p.stdout,p.stderr)==(code,out,b""),(args,p.returncode,p.stdout,p.stderr)

def expected(payload,status):
    # Independently specified instruction addresses: loop 17, failure 67,
    # RIP after LEA 12, code extent 79. These are checked against the ELF fields.
    code=(bytes.fromhex("bf01000000488d35")+struct.pack("<i",79-12)+
          b"\xba"+struct.pack("<I",len(payload))+
          bytes.fromhex("b8010000000f054883f8fc0f84")+struct.pack("<i",17-34)+
          bytes.fromhex("4885c00f8e")+struct.pack("<i",67-43)+
          bytes.fromhex("4801c64829c20f85")+struct.pack("<i",17-55)+
          b"\xbf"+struct.pack("<I",status)+bytes.fromhex("b83c0000000f05bf6f000000b83c0000000f05"))
    assert len(code)==79
    size=120+79+len(payload)
    header=b"\x7fELF\x02\x01\x01"+b"\0"*9+struct.pack("<HHIQQQIHHHHHH",2,62,1,0x400078,64,0,0,64,56,1,0,0,0)
    segment=struct.pack("<IIQQQQQQ",1,5,0,0x400000,0x400000,size,size,4096)
    return header+segment+code+payload

def observe(path,payload,status,mode):
    actual=path.read_bytes()
    assert actual==expected(payload,status)
    assert stat.S_IMODE(path.stat().st_mode)==mode
    assert struct.unpack_from("<Q",actual,96)[0]==len(actual)
    return hashlib.sha256(actual).hexdigest()

def isolated_prefix(root,image,output):
    assert os.getuid()!=0
    assert (root/"emitter").is_file() and (root/"output").is_dir()
    # A distribution base rootfs has no development toolchain or Mognitio.
    for binary in ("sbcl","mgn","gcc","cc","clang","as","ld","ld.lld"):
        assert not any((root/d/binary).exists() for d in ("bin","usr/bin","usr/local/bin")),binary
    return ["bwrap","--unshare-user","--uid",str(os.getuid()),"--gid",str(os.getgid()),
            "--unshare-pid","--unshare-net","--unshare-ipc","--die-with-parent",
            "--ro-bind",root,"/","--proc","/proc","--dev","/dev",
            "--ro-bind",image,"/emitter","--bind",output,"/output","--chdir","/output",
            "--clearenv","--setenv","PATH","/unavailable"]

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--userland",action="append",default=[],type=Path)
    parser.add_argument("--evidence",type=Path)
    args=parser.parse_args()
    records=[]
    with tempfile.TemporaryDirectory(prefix="mgn-emitter-") as tmp:
        work=Path(tmp);project=work/"project"
        shutil.copytree(ROOT/"examples/binary-emitter",project)
        manifest=project/"mognitio.toml";image=work/"emitter"
        run([ROOT/"bin/mgn","build",manifest,"-o",image])
        # Both paths repeat with changed names; output identity must not include paths.
        for selection,payload in (("ascii",b"MGN\n"),("jp",bytes([227,129,130,10,49]))):
            for status in (0,7):
                for native in (False,True):
                    for repeat in range(2):
                        path=work/f"{selection}-{status}-{native}-{repeat}"
                        command=[image] if native else [ROOT/"bin/mgn","run",manifest,"--"]
                        run(command+[path,selection,str(status),"exec"],umask=0o022)
                        digest=observe(path,payload,status,0o755)
                        run([path],status,payload,env={"PATH":"/unavailable"})
                        before=path.read_bytes();run(command+[path,selection,str(status),"exec"],1)
                        assert path.read_bytes()==before
                        records.append({"payload":selection,"exit":status,"native":native,"repeat":repeat,"sha256":digest})
                path=work/f"data-{selection}-{status}"
                run([image,path,selection,str(status),"data"],umask=0o022)
                observe(path,payload,status,0o644)
        # Isolated runs receive only the immutable emitter and writable output.
        for root in args.userland:
            release=(root/"etc/os-release").read_text()
            for selection,payload in (("ascii",b"MGN\n"),("jp",bytes([227,129,130,10,49]))):
                for status in (0,7):
                    output=work/f"isolated-{root.name}-{selection}-{status}";output.mkdir()
                    command=isolated_prefix(root,image,output)
                    run(command+["/emitter","/output/generated",selection,str(status),"exec"],umask=0o022)
                    digest=observe(output/"generated",payload,status,0o755)
                    run(command+["/output/generated"],status,payload)
                    records.append({"userland":root.name,"os_release":release,"payload":selection,"exit":status,"sha256":digest})
        if args.evidence:
            args.evidence.write_text(json.dumps({"compiler":subprocess.check_output(["git","rev-parse","HEAD"],cwd=ROOT,text=True).strip(),
                "kernel":os.uname().release,"uid_nonzero":os.getuid()!=0,"checks":checks,"records":records},indent=2)+"\n")
    print(f"BINARY_EMITTER_OK checks={checks} userlands={len(args.userland)}")

if __name__=="__main__":main()
