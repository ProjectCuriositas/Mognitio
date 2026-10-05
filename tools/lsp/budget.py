"""Owned session memory accounting, with an optional delegated cgroup."""
import os
from pathlib import Path
import secrets

LIMIT = 1024 ** 3
class MemoryBudget:
    def __init__(self):
        self.group = None
        self.parent = None
        self.enabled_controller = False
        group = parent = None
        moved = enabled = False
        try:
            record = next(line.split(":", 2)[2] for line in Path("/proc/self/cgroup").read_text().splitlines()
                          if line.startswith("0::"))
            parent = Path("/sys/fs/cgroup") / record.lstrip("/")
            if not os.access(parent / "cgroup.procs", os.W_OK):
                return
            active = "memory" in (parent / "cgroup.subtree_control").read_text().split()
            if not active:
                # Activate a delegated controller only in a scope exclusively owned by this process.
                # cgroup v2 forbids enabling domain controllers while the parent contains processes.
                owners = (parent / "cgroup.procs").read_text().split()
                if (owners != [str(os.getpid())] or any(path.is_dir() for path in parent.iterdir())
                        or "memory" not in (parent / "cgroup.controllers").read_text().split()):
                    return
            group = parent / ("mognitio-" + str(os.getpid()) + "-" + secrets.token_hex(4))
            group.mkdir()
            if not active:
                (group / "cgroup.procs").write_text(str(os.getpid()))
                moved = True
                (parent / "cgroup.subtree_control").write_text("+memory")
                enabled = True
            (group / "memory.max").write_text(str(LIMIT))
            if (group / "memory.swap.max").exists():
                (group / "memory.swap.max").write_text("0")
            (group / "memory.oom.group").write_text("1")
            if not moved:
                (group / "cgroup.procs").write_text(str(os.getpid()))
                moved = True
            self.parent, self.group, self.enabled_controller = parent, group, enabled
        except (OSError, StopIteration):
            if enabled:
                try:
                    (parent / "cgroup.subtree_control").write_text("-memory")
                except OSError:
                    pass
            if moved:
                try:
                    (parent / "cgroup.procs").write_text(str(os.getpid()))
                except OSError:
                    pass
            if group:
                try:
                    group.rmdir()
                except OSError:
                    pass

    def check(self):
        if self.group:
            return  # Kernel-enforced ceiling covers this process and all descendants.
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
                if self.enabled_controller:
                    (self.parent / "cgroup.subtree_control").write_text("-memory")
                (self.parent / "cgroup.procs").write_text(str(os.getpid()))
                self.group.rmdir()
            except OSError:
                pass
