#!/usr/bin/env python3
"""CLI, diagnostics, no-replace publication, races and OS restrictions."""
import argparse, os, resource, stat, subprocess, tempfile, sys
from pathlib import Path
from native import ENTRY, elf

def main():
    parser=argparse.ArgumentParser();parser.add_argument("--compiler",required=True,type=Path)
    parser.add_argument("--bindfs",default="bindfs");args=parser.parse_args();compiler=args.compiler.resolve();checks=0
    with tempfile.TemporaryDirectory(prefix="mgnc-driver-") as temporary:
        root=Path(temporary);source=root/"valid.mgn";source.write_text(ENTRY+"7};")
        def invoke(argv,want,fragment=b"",**kwargs):
            nonlocal checks
            p=subprocess.run([compiler,*map(str,argv)],capture_output=True,timeout=120,**kwargs)
            assert p.returncode==want and p.stdout==b"",(argv,p)
            assert fragment in p.stderr if fragment else p.stderr==b"",(argv,p.stderr)
            checks+=1;return p
        def build(src,out,want=0,fragment=b"",**kwargs):
            return invoke(["build",src,"-o",out],want,fragment,**kwargs)
        for argv in [[],["build"],["run","missing.mgn","-o","out"],
                     ["build","missing.mgn","--out","out"],["build","","-o","out"],
                     ["build","missing.mgn","-o",""],["build","missing.mgn","-o","out","extra"],
                     ["build","mognitio.toml","-o","out"],["build","missing.mgn","-o","out/"]]:
            invoke(argv,2,b"cli:",cwd=root)
            assert not (root/"out").exists()
        # Relative, absolute, spaces and leading hyphens are literal paths.
        for index,filename in enumerate(["relative.mgn","space input.mgn","-literal.mgn"]):
            src=root/filename;src.write_bytes(source.read_bytes());out=root/f"-output {index}"
            build(src.name,out.name,cwd=root);elf(out.read_bytes())
        build(source,root/"absolute");elf((root/"absolute").read_bytes())
        missing=root/"missing.mgn";build(missing,root/"no-output",2,b"NotFound")
        directory=root/"directory.mgn";directory.mkdir();build(directory,root/"no-output",2,b"UnsupportedTarget")
        denied=root/"denied.mgn";denied.write_bytes(source.read_bytes());denied.chmod(0)
        try:build(denied,root/"no-output",2,b"PermissionDenied")
        finally:denied.chmod(0o600)
        invalid=root/"invalid.mgn";invalid.write_bytes(b"\xff")
        build(invalid,root/"no-output",1,b"position unknown")
        bom=root/"bom.mgn";bom.write_bytes(b"\xef\xbb\xbf"+source.read_bytes())
        build(bom,root/"no-output",1,b"[0,3)")
        span=root/"span.mgn";span.write_text("//日本語😀\r\n\t"+ENTRY+"missing};")
        r=build(span,root/"no-output",1,b"semantic:")
        offset=span.read_bytes().index(b"missing")
        assert f"[{offset},{offset+7})".encode() in r.stderr and b":2:" in r.stderr
        existing=root/"existing";existing.write_bytes(b"original");existing.chmod(0o640)
        bad=root/"bad.mgn";bad.write_text(ENTRY+"missing};")
        build(bad,existing,1,b"semantic:")
        kinds=[existing,root/"directory",root/"symlink",root/"dangling",root/"hardlink"]
        kinds[1].mkdir();kinds[2].symlink_to(existing);kinds[3].symlink_to(root/"absent");os.link(existing,kinds[4])
        for out in kinds:
            build(source,out,2,b"AlreadyExists")
            assert existing.read_bytes()==b"original" and stat.S_IMODE(existing.stat().st_mode)==0o640
        input_copy=source.read_bytes();input_mode=stat.S_IMODE(source.stat().st_mode)
        alias=root/"alias";os.link(source,alias)
        for out in [source,alias]:
            build(source,out,2,b"AlreadyExists")
            assert source.read_bytes()==input_copy and stat.S_IMODE(source.stat().st_mode)==input_mode
        source_link=root/"source-link.mgn";source_link.symlink_to(source)
        build(source_link,root/"linked-input")
        build(source,str(root/"trailing")+"/",2,b"InvalidPath")
        build(source,root/"absent-parent"/"out",2,b"NotFound")
        assert not (root/"absent-parent").exists()
        protected=root/"protected";protected.mkdir();protected.chmod(0o500)
        try:build(source,protected/"out",2,b"PermissionDenied")
        finally:protected.chmod(0o700)
        limited=root/"limited"
        build(source,limited,2,b"NotPublished",preexec_fn=lambda:resource.setrlimit(resource.RLIMIT_FSIZE,(1,1)))
        assert not limited.exists() and not list(root.glob(".mgn-*"))
        for mask in [0o022,0o077,0o111]:
            out=root/f"mode-{mask:o}";build(source,out,umask=mask)
            assert stat.S_IMODE(out.stat().st_mode)==0o777 & ~mask
            if mask==0o111:
                try:subprocess.run([out],capture_output=True)
                except PermissionError:checks+=1
                else:raise AssertionError("non-executable output was repaired")
        acl=root/"acl";acl.mkdir()
        subprocess.run(["setfacl","-m","d:u::rwx,d:g::r-x,d:o::---",acl],check=True)
        build(source,acl/"out",umask=0o077);assert stat.S_IMODE((acl/"out").stat().st_mode)==0o750
        race=root/"race"
        processes=[subprocess.Popen([compiler,"build",source,"-o",race],stdout=subprocess.PIPE,stderr=subprocess.PIPE) for _ in range(8)]
        codes=[]
        for process in processes:
            out,err=process.communicate(timeout=120);codes.append(process.returncode)
            assert out==b"" and (err==b"" if process.returncode==0 else b"AlreadyExists" in err)
        assert sorted(codes)==[0]+[2]*7;before=race.read_bytes()
        build(source,race,2,b"AlreadyExists");assert race.read_bytes()==before;checks+=8
        restricted=root/"noexec";restricted.mkdir()
        controlled=subprocess.run([sys.executable,Path(__file__).with_name("noexec.py"),args.bindfs,compiler,source,restricted],
                                  capture_output=True,timeout=120)
        assert (controlled.returncode,controlled.stdout,controlled.stderr)==(0,b"",b""),controlled
        checks+=2
        for fault in ["closed","pipe"]:
            writer=None
            if fault=="closed":kwargs={"preexec_fn":lambda:os.close(2),"stderr":subprocess.PIPE}
            else:
                reader,writer=os.pipe();os.close(reader);kwargs={"stderr":writer}
            try:
                r=subprocess.run([compiler,"build",bad,"-o",root/"no-output"],stdout=subprocess.PIPE,timeout=120,**kwargs)
            finally:
                if writer is not None:os.close(writer)
            assert r.returncode==2 and r.stdout==b"";checks+=1
        assert not (root/"no-output").exists() and not list(root.glob(".mgn-*"))
    print(f"MGNC_DRIVER_OK checks={checks}")
if __name__=="__main__":main()
