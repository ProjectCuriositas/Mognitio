"""Check real mmap/munmap lifetimes independently through syscall tracing."""
from pathlib import Path
import re
import shutil
import subprocess
import sys

image = Path(sys.argv[1]).resolve()
assert shutil.which("strace"), "strace is required for the workspace lifetime gate"
trace = image.with_suffix(".maps")
run = subprocess.run(["strace", "-qq", "-e", "trace=mmap,munmap", "-o", str(trace), str(image)],
                     capture_output=True, timeout=30)
assert run.returncode == 0 and run.stdout == b"true\n" and run.stderr == b"", run
active = {}
released = 0
for line in trace.read_text().splitlines():
    mapped = re.fullmatch(r"mmap\(NULL, ([0-9]+), PROT_READ\|PROT_WRITE, MAP_PRIVATE\|MAP_ANONYMOUS, -1, 0\) = (0x[0-9a-f]+)", line)
    unmapped = re.fullmatch(r"munmap\((0x[0-9a-f]+), ([0-9]+)\)\s*= 0", line)
    if mapped:
        size, address = int(mapped[1]), int(mapped[2], 16)
        assert address not in active
        active[address] = size
    elif unmapped:
        address, size = int(unmapped[1], 16), int(unmapped[2])
        assert active.pop(address) == size
        released += 1
    else:
        raise AssertionError(line)
assert released >= 127, released
assert list(active.values()) == [4096], active
print("WORKSPACE_MAPS_OK", released, "released; one managed arena retained")
