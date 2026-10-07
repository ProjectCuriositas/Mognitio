"""Run private snapshot artifacts with isolated FD 6 and real test handshakes."""
from pathlib import Path
import fcntl
import hashlib
import importlib.util
import json
import os
import select
import signal
import sys
import time

spec = importlib.util.spec_from_file_location("heap_check", Path(__file__).with_name("v11-heap-check.py"))
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


def capture(image, profile, fail_fd=None):
    image = Path(image).resolve()
    snapshot = image.with_suffix(".snapshot")
    stdout, stderr = image.with_suffix(".stdout"), image.with_suffix(".stderr")
    owned = []
    def high(fd):
        copy = fcntl.fcntl(fd, fcntl.F_DUPFD_CLOEXEC, 20)
        owned.append(copy)
        return copy
    def opened(path):
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        try:
            return high(fd)
        finally:
            os.close(fd)
    def pipe():
        left, right = os.pipe()
        try:
            return high(left), high(right)
        finally:
            os.close(left)
            os.close(right)
    actions = [(os.POSIX_SPAWN_DUP2, opened(stdout), 1),
               (os.POSIX_SPAWN_DUP2, opened(stderr), 2),
               (os.POSIX_SPAWN_DUP2, opened(snapshot), 6)]
    if fail_fd == "closed":
        actions.append((os.POSIX_SPAWN_CLOSE, 6))
    elif fail_fd == "full":
        actions.append((os.POSIX_SPAWN_DUP2, opened("/dev/full"), 6))
    event_read = event_write = gate_read = gate_write = None
    if profile:
        event_read, event_write = pipe()
        gate_read, gate_write = pipe()
        actions += [(os.POSIX_SPAWN_DUP2, event_write, 3),
                    (os.POSIX_SPAWN_DUP2, gate_read, 4),
                    (os.POSIX_SPAWN_DUP2, opened(image.with_suffix(".failure")), 5)]
    pid = None
    status = None
    try:
        pid = os.posix_spawn(str(image), [str(image)], os.environ, file_actions=actions)
        if profile:
            os.close(event_write); owned.remove(event_write)
            os.close(gate_read); owned.remove(gate_read)
            ready = b""
            deadline = time.monotonic() + 5
            while len(ready) < 40:
                remaining = deadline - time.monotonic()
                assert remaining > 0 and select.select([event_read], [], [], remaining)[0], "ready timeout"
                part = os.read(event_read, 40 - len(ready))
                assert part, "ready EOF"
                ready += part
            assert ready[:8] == bytes.fromhex("4d474e5403000100"), ready
            assert ready[8:32] == bytes(24) and ready[32:] == bytes([255])*8
            os.write(gate_write, b"\x01")
            os.close(gate_write); owned.remove(gate_write)
        deadline = time.monotonic() + 15
        while status is None:
            found, result = os.waitpid(pid, os.WNOHANG)
            if found:
                status = result
                break
            assert time.monotonic() < deadline, "snapshot timeout"
            time.sleep(0.005)
        assert os.waitstatus_to_exitcode(status) == (97 if fail_fd else 0), (status, stderr.read_bytes())
        assert stdout.read_bytes() == stderr.read_bytes() == b"", "public output contamination"
        return b"" if fail_fd else snapshot.read_bytes()
    finally:
        if pid is not None and status is None:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
        for fd in owned:
            os.close(fd)


def main():
    image, profile, point, ordinal = sys.argv[1:5]
    profile, point, ordinal = map(int, (profile, point, ordinal))
    data = capture(image, profile)
    good = checker.read_snapshot(data, profile, point, ordinal)
    negatives = checker.negative_controls(data, profile, point, ordinal)
    writer_negatives = 0
    if (point, ordinal) == (3, 1):
        for failure in ("closed", "full"):
            capture(image, profile, fail_fd=failure)
            writer_negatives += 1
    faults = []
    for fault_image in sys.argv[5:]:
        bad = capture(fault_image, profile)
        actual = checker.read_snapshot(bad, profile, point, ordinal, check_links=False)
        assert actual["geometry"] == good["geometry"] and actual["links"] == good["links"]
        assert actual["arena_sizes"] == good["arena_sizes"]
        assert len(good["free"]) >= 2
        try:
            checker.read_snapshot(bad, profile, point, ordinal)
        except ValueError:
            pass
        else:
            raise AssertionError("runtime head corruption escaped")
        faults.append(dict(artifact_sha256=hashlib.sha256(Path(fault_image).read_bytes()).hexdigest(),
                           snapshot_sha256=hashlib.sha256(bad).hexdigest()))
    manifest = dict(profile=profile, point=point, ordinal=ordinal, mapped=good["mapped"],
                    blocks=len(good["blocks"]), free=len(good["free"]),
                    artifact_sha256=hashlib.sha256(Path(image).read_bytes()).hexdigest(),
                    snapshot_sha256=hashlib.sha256(data).hexdigest(), faults=faults,
                    reader_negatives=negatives, writer_negatives=writer_negatives)
    Path(image).with_suffix(".snapshot.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print("HEAP_SNAPSHOT_OK", json.dumps(manifest))


if __name__ == "__main__":
    main()
