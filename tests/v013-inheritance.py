"""Non-root directory permissions, default ACL and setgid inheritance."""
from pathlib import Path
import os
import stat
import subprocess
import tempfile
from v013_support import Suite,ROOT

def metadata(path):
    s=path.stat();return s.st_uid,s.st_gid,stat.S_IMODE(s.st_mode)

with tempfile.TemporaryDirectory(prefix='mgn-v013-inheritance-') as temporary:
    suite=Suite(temporary)
    assert os.geteuid()!=0
    groups=os.getgroups();different=next((g for g in groups if g!=os.getegid()),None)
    assert different is not None,'The different-group fixture requires supplementary group membership'
    body='discard createDirectory("parent/child");discard createDirectory("parent/child");0'
    project,manifest=suite.project(body);image=project/'app'
    suite.command([ROOT/'bin/mgn','build',manifest,'-o',image])
    for acl in (False,True):
        for setgid in (False,True):
            for backend in ('host','native'):
                cwd=project/f'{acl}-{setgid}-{backend}';cwd.mkdir();parent=cwd/'parent';parent.mkdir()
                subprocess.run(['setfacl','-b','-k',parent],check=True,capture_output=True)
                if setgid:os.chown(parent,-1,different)
                os.chmod(parent,0o2775 if setgid else 0o775)
                if acl:subprocess.run(['setfacl','-m','d:u::rwx,d:g::rwx,d:o::---',parent],check=True,capture_output=True)
                before=metadata(parent);acl_before=subprocess.check_output(['getfacl','-cp',parent])
                assert bool(before[2]&stat.S_ISGID)==setgid
                assert (b'default:' in acl_before)==acl
                if setgid:assert before[1]==different and before[1]!=os.getegid()
                command=[ROOT/'bin/mgn','run',manifest] if backend=='host' else [image]
                trace=cwd/'trace'
                suite.command(['strace','-f','-qq','-e','trace=mkdir,mkdirat,chmod,fchmod,fchmodat,chown,fchown,umask','-o',trace,*command],cwd=cwd,umask=0o077)
                child=metadata(parent/'child')
                assert child[0]==os.geteuid()
                assert child[1]==(before[1] if setgid else os.getegid())
                assert child[2]==((0o770 if acl else 0o700)|(stat.S_ISGID if setgid else 0))
                assert metadata(parent)==before and subprocess.check_output(['getfacl','-cp',parent])==acl_before
                lines=trace.read_text().splitlines()
                start=next(i for i,line in enumerate(lines) if 'mkdirat(' in line and 'parent/child' in line)
                assert not any(any(call in line for call in ['chmod(','chown(','umask(']) for line in lines[start:])
                suite.command(command,cwd=cwd,umask=0o022)
                assert metadata(parent/'child')==child and metadata(parent)==before
                # A host mkdir in the same mount is the no-setgid control.
                if not setgid:
                    (parent/'control').mkdir()
                    assert (parent/'control').stat().st_gid==child[1]
    print(f'v0.13 inheritance checks={suite.checks} different_group=true acl=true failures=0')
