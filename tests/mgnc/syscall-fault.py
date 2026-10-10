#!/usr/bin/env python3
"""Inject one Linux AMD64 syscall failure into an otherwise unchanged executable."""
import argparse,ctypes,errno,os,signal,sys
class Registers(ctypes.Structure):
    _fields_=[(name,ctypes.c_ulonglong) for name in
              "r15 r14 r13 r12 rbp rbx r11 r10 r9 r8 rax rcx rdx rsi rdi orig_rax rip cs eflags rsp ss fs_base gs_base ds es fs gs".split()]
libc=ctypes.CDLL(None,use_errno=True)
libc.ptrace.restype=ctypes.c_long
def ptrace(request,pid,address=0,data=0):
    result=libc.ptrace(ctypes.c_ulong(request),ctypes.c_ulong(pid),ctypes.c_void_p(address),data)
    if result==-1:raise OSError(ctypes.get_errno(),os.strerror(ctypes.get_errno()))
    return result
def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--syscall",type=int,required=True);parser.add_argument("--ordinal",type=int,default=1)
    parser.add_argument("--errno",type=int,default=errno.EIO);parser.add_argument("--after",action="store_true")
    parser.add_argument("command",nargs=argparse.REMAINDER);args=parser.parse_args()
    command=args.command[1:] if args.command[0]=="--" else args.command
    pid=os.fork()
    if pid==0:
        ptrace(0,0);os.kill(os.getpid(),signal.SIGSTOP);os.execv(command[0],command)
    os.waitpid(pid,0);ptrace(0x4200,pid,0,ctypes.c_void_p(1))
    entering=True;seen=0;inject=False;injected=False
    try:
        while True:
            ptrace(24,pid,0,ctypes.c_void_p(0));_,status=os.waitpid(pid,0)
            if os.WIFEXITED(status):
                assert injected,"fault site was not reached"
                return os.WEXITSTATUS(status)
            if os.WIFSIGNALED(status):
                raise AssertionError(f"child signal {os.WTERMSIG(status)}")
            stop=os.WSTOPSIG(status)
            if stop==signal.SIGTRAP:continue
            assert stop==signal.SIGTRAP|0x80,stop
            registers=Registers();ptrace(12,pid,0,ctypes.byref(registers))
            if entering:
                inject=False
                if registers.orig_rax==args.syscall:
                    seen+=1;inject=seen==args.ordinal
                    if inject and not args.after:
                        registers.orig_rax=2**64-1;ptrace(13,pid,0,ctypes.byref(registers))
            elif inject:
                if args.after:assert registers.rax < 2**63,"underlying operation did not succeed"
                registers.rax=(-args.errno)%(2**64)
                ptrace(13,pid,0,ctypes.byref(registers));injected=True
            entering=not entering
    finally:
        try:os.kill(pid,signal.SIGKILL)
        except ProcessLookupError:pass
if __name__=="__main__":sys.exit(main())
