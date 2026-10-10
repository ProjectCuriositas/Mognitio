#!/usr/bin/env python3
"""Observe publication and execution on a private noexec FUSE bind mount."""
import os,stat,subprocess,sys
from pathlib import Path
bindfs,compiler,source,directory=sys.argv[1:]
directory=Path(directory)
assert os.getuid()!=0 and directory.name=="noexec" and directory.parent.name.startswith("mgnc-driver-")
backing=directory.with_name("noexec-backing");backing.mkdir()
subprocess.run([bindfs,"--no-allow-other","-o","noexec",backing,directory],check=True)
try:
    output=directory/"program"
    result=subprocess.run([compiler,"build",source,"-o",output],capture_output=True,timeout=120,umask=0o022)
    if result.returncode==2:
        # This FUSE provider may reject atomic no-replace rename. Observe that
        # public failure separately, then execute a successful publication via
        # its noexec alias without changing either file's requested mode.
        assert result.stdout==b"" and b"UnsupportedTarget / Publish / Unknown" in result.stderr,result
        successful=backing/"successful"
        result=subprocess.run([compiler,"build",source,"-o",successful],capture_output=True,timeout=120,umask=0o022)
        assert (result.returncode,result.stdout,result.stderr)==(0,b"",b""),result
        output=directory/"successful"
    else:
        assert (result.returncode,result.stdout,result.stderr)==(0,b"",b""),result
    assert stat.S_IMODE(output.stat().st_mode)==0o755
    try:subprocess.run([output],capture_output=True,timeout=3)
    except PermissionError:pass
    else:raise AssertionError("expected noexec mount restriction")
finally:
    subprocess.run(["fusermount3","-u",directory],check=True)
