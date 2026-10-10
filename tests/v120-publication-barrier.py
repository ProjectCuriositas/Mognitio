"""Synchronize real publishers after close and before no-replace commit."""
import fcntl
import os
from pathlib import Path
import select
import subprocess
import sys

image,path,mode=sys.argv[1:]
path=Path(path)
owned=[]
def high(fd):
    out=fcntl.fcntl(fd,fcntl.F_DUPFD_CLOEXEC,20)
    os.close(fd);owned.append(out);return out
def pipe():
    a,b=os.pipe();return high(a),high(b)
children=[]
try:
    for _ in range(2 if mode=="race" else 1):
        ready_r,ready_w=pipe();gate_r,gate_w=pipe()
        actions=[(os.POSIX_SPAWN_DUP2,ready_w,6),(os.POSIX_SPAWN_DUP2,gate_r,7)]
        pid=os.posix_spawn(image,[image],os.environ,file_actions=actions)
        children.append((pid,ready_r,gate_w))
        os.close(ready_w);owned.remove(ready_w)
        os.close(gate_r);owned.remove(gate_r)
    for _,ready,_ in children:
        assert select.select([ready],[],[],10)[0],"publisher did not reach commit barrier"
        assert os.read(ready,1)==b"\x01"
    assert not os.path.lexists(path),"destination visible before commit"
    if mode=="directory":path.mkdir()
    if mode=="file":path.write_bytes(b"winner")
    for _,_,gate in children:os.write(gate,b"\x01")
    statuses=[os.waitstatus_to_exitcode(os.waitpid(pid,0)[1]) for pid,_,_ in children]
    children=[]
    if mode=="race":
        assert sorted(statuses)==[0,11],statuses
        assert path.read_bytes()==bytes([0,128,255])
    else:
        assert statuses==[0],statuses
        if mode=="file":assert path.read_bytes()==b"winner"
        else:assert path.is_dir() and list(path.iterdir())==[]
    print("PUBLICATION_BARRIER_OK")
finally:
    for pid,_,_ in children:
        try:os.kill(pid,9);os.waitpid(pid,0)
        except ProcessLookupError:pass
    for fd in owned:os.close(fd)
