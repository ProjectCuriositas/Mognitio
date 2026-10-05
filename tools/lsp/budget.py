"""Owned session memory accounting, with an optional delegated cgroup."""
import os
from pathlib import Path
import secrets

LIMIT = 1024 ** 3
class MemoryBudget:
    def __init__(self):
        self.group = None
        self.parent = None
        try:
            record = next(line.split(":", 2)[2] for line in Path("/proc/self/cgroup").read_text().splitlines()
                          if line.startswith("0::"))
            parent = Path("/sys/fs/cgroup") / record.lstrip("/")
            if os.access(parent / "cgroup.procs", os.W_OK) and "memory" in (parent / "cgroup.subtree_control").read_text().split():
                group = parent / ("mognitio-" + str(os.getpid()) + "-" + secrets.token_hex(4))
                group.mkdir()
                try:
                    (group / "memory.max").write_text(str(LIMIT))
                    (group / "cgroup.procs").write_text(str(os.getpid()))
                    self.parent, self.group = parent, group
                except OSError:
                    group.rmdir()
        except (OSError, StopIteration):
            pass

    def check(self):
        if self.group:
            # Kernel-enforced hard ceiling applies to all descendants in this group.
            return
        # Follow only children recorded in procfs. No PID is signaled from this list.
        pending, seen, total = [os.getpid()], set(), 0
        while pending:
            pid = pending.pop()
            if pid in seen:
                continue
            seen.add(pid)
            try:
                total += int(Path(f"/proc/{pid}/statm").read_text().split()[1]) * os.sysconf("SC_PAGE_SIZE")
                for task in Path(f"/proc/{pid}/task").iterdir():
                    pending.extend(int(value) for value in (task / "children").read_text().split())
            except (OSError, ValueError, IndexError):
                continue
        if total > LIMIT:
            raise RuntimeError("Session memory budget exceeded (best-effort RSS observer)")

    def close(self):
        if self.group:
            try:
                (self.parent / "cgroup.procs").write_text(str(os.getpid()))
                self.group.rmdir()
            except OSError:
                pass
