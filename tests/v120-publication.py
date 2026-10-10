#!/usr/bin/env python3
"""Observe native/host publication bytes, namespace safety and OS permissions."""
from pathlib import Path
import json
import os
import resource
import socket
import stat
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[1]
CLI=ROOT/"bin/mgn"
checks=0
IMPORTS="namespace App;\nuse Std\\Numeric\\{Bits};\nuse Std\\Binary\\{Bytes,bytesFromBits,publishFile,BinaryFileMode,BinaryOutputError,BinaryOutputErrorKind,BinaryOutputPhase,BinaryPublicationState};\n"
KINDS=["InvalidPath","AlreadyExists","NotFound","PermissionDenied","UnsupportedTarget","ResourceExhausted","Other"]
PHASES=["Input","Target","Body","Publish","Cleanup"]
STATES=["NotPublished","Published","Unknown"]

def enum(expression,typ,values,expected):
    return "branch on "+expression+"{"+",".join(f"{typ}::{v}=>{'true' if v==expected else 'false'}" for v in values)+"}"

def run(args,code=0,**kwargs):
    global checks
    p=subprocess.run(list(map(str,args)),capture_output=True,timeout=60,**kwargs);checks+=1
    assert p.returncode==code,(args,code,p.returncode,p.stdout,p.stderr)
    assert p.stdout==p.stderr==b"",(args,p.stdout,p.stderr)
    return p

def vector(values):
    return "bytesFromBits(List<Bits<8>>["+",".join(f"Bits<8>{{{v}}}" for v in values)+"])"

with tempfile.TemporaryDirectory(prefix="mgn-publish-") as temporary:
    root=Path(temporary);(root/"src").mkdir()
    manifest=root/"mognitio.toml";manifest.write_text('[project]\nname="app"\nroot_namespace="App"\n')
    source=root/"src/app.mgn";image=root/"program"
    def compile(body,declarations=""):
        source.write_text(IMPORTS+declarations+"\nlet main:Function(List<String>):Int=function(args:List<String>):Int{"+body+"};\n")
        run([CLI,"build",manifest,"-o",image])
    def body(path,values=(0,127,128,255),mode="Data",error=None,phase="Target",state="NotPublished"):
        errorcheck="false" if error is None else (
            "("+enum("e->kind","BinaryOutputErrorKind",KINDS,error)+") && ("+
            enum("e->phase","BinaryOutputPhase",PHASES,phase)+") && ("+
            enum("e->publication","BinaryPublicationState",STATES,state)+") && e->subject=="+json.dumps(str(path)))
        return (f"branch on publishFile({json.dumps(str(path))},{vector(values)},BinaryFileMode::{mode})"+
                "{Result<Unit,BinaryOutputError>::Ok(x:Unit)=>"+("0" if error is None else "1")+
                ",Result<Unit,BinaryOutputError>::Err(e:BinaryOutputError)=>branch when{"+errorcheck+"=>0,else=>2}}")
    def execute(native,**kwargs):
        return run([image] if native else [CLI,"run",manifest],**kwargs)
    def unchanged(names):
        assert {p.name for p in root.iterdir()}==names, list(root.iterdir())

    for mode,requested in (("Data",0o666),("Executable",0o777)):
        for mask in (0o022,0o077,0o111):
            target=root/f"{mode}-{mask:o}"
            compile(body(target,mode=mode))
            for native in (False,True):
                before={p.name for p in root.iterdir()}
                execute(native,umask=mask)
                assert target.read_bytes()==bytes([0,127,128,255])
                assert stat.S_IMODE(target.stat().st_mode)==requested & ~mask
                target.unlink();unchanged(before)
    for values in ([],list(range(256)),[255,0]*512):
        target=root/"raw"
        compile(body(target,values))
        for native in (False,True):
            execute(native);assert target.read_bytes()==bytes(values);target.unlink()
    # Existing entry kinds and every trailing-slash spelling are protected.
    regular=root/"existing";regular.write_bytes(b"original");regular.chmod(0o640)
    directory=root/"directory";directory.mkdir()
    hard=root/"hard";os.link(regular,hard)
    link=root/"link";link.symlink_to(regular)
    dirlink=root/"dirlink";dirlink.symlink_to(directory)
    dangling=root/"dangling";dangling.symlink_to(root/"absent")
    fifo=root/"fifo";os.mkfifo(fifo)
    sock=socket.socket(socket.AF_UNIX);sockpath=root/"socket";sock.bind(str(sockpath))
    try:
        for target in (regular,directory,hard,link,dirlink,dangling,fifo,sockpath):
            compile(body(target,error="AlreadyExists"))
            before={p.name for p in root.iterdir()}
            for native in (False,True):
                execute(native);unchanged(before)
                assert regular.read_bytes()==b"original" and stat.S_IMODE(regular.stat().st_mode)==0o640
        for spelling in ("","/","output/","output//",*[str(p)+"/" for p in (regular,directory,link,dirlink,dangling,root/"absent")]):
            compile(body(spelling,error="InvalidPath",phase="Input"))
            before={p.name for p in root.iterdir()}
            for native in (False,True):execute(native,cwd=root);unchanged(before)
        compile(body(str(root/"nul")+"\\u{0}",error="InvalidPath",phase="Input").replace("\\\\u{0}","\\u{0}"))
        for native in (False,True):execute(native)
    finally:sock.close()
    for target,error in ((root/"missing"/"out","NotFound"),(regular/"out","UnsupportedTarget")):
        compile(body(target,error=error))
        for native in (False,True):execute(native)
    # Intermediate symlinks follow normal OS path resolution.
    target=dirlink/"created";compile(body(target))
    for native in (False,True):
        execute(native);assert (directory/"created").read_bytes()==bytes([0,127,128,255]);target.unlink()
    # New entries on uncertified ext4 are rejected before creating staging files.
    if os.statvfs(ROOT).f_fsid != os.statvfs(root).f_fsid:
        with tempfile.TemporaryDirectory(prefix=".mgn-publish-",dir=ROOT) as other:
            destination=Path(other)/"out";compile(body(destination,error="UnsupportedTarget"))
            for native in (False,True):
                execute(native);assert list(Path(other).iterdir())==[]
    # A real file-size limit yields a partial write followed by EFBIG.
    target=root/"limited";compile(body(target,error="Other",phase="Body"))
    for native in (False,True):
        before={p.name for p in root.iterdir()}
        execute(native,preexec_fn=lambda:resource.setrlimit(resource.RLIMIT_FSIZE,(1,1)))
        assert not target.exists();unchanged(before)
    # Default ACL governs the creation mode without a second umask application.
    acl=root/"acl";acl.mkdir()
    subprocess.run(["setfacl","-m","d:u::rwx,d:g::r-x,d:o::---",str(acl)],check=True)
    for mode,expected in (("Data",0o640),("Executable",0o750)):
        target=acl/"out";compile(body(target,mode=mode))
        for native in (False,True):
            execute(native,umask=0o077);assert stat.S_IMODE(target.stat().st_mode)==expected
            target.unlink()
    # The requested file never inherits special bits from a setgid parent.
    group=root/"setgid";group.mkdir();group.chmod(0o2770)
    target=group/"out";compile(body(target,mode="Executable"))
    for native in (False,True):
        execute(native);assert stat.S_IMODE(target.stat().st_mode)&0o7000==0;target.unlink()
    # Concurrent no-replace commits have exactly one winner and preserve it.
    target=root/"race"
    compile(body(target).replace("=>2}}","=>11}}"))
    procs=[subprocess.Popen([image],stdout=subprocess.PIPE,stderr=subprocess.PIPE) for _ in range(12)]
    codes=[]
    for p in procs:
        out,err=p.communicate(timeout=30);checks+=1;assert out==err==b"";codes.append(p.returncode)
    assert sorted(codes)==[0]+[11]*11,codes
    assert target.read_bytes()==bytes([0,127,128,255]);target.unlink()
    assert not list(root.glob(".mgn-*"))
print(f"BINARY_PUBLICATION_OK checks={checks}")
