#!/usr/bin/env python3
"""Reject misleading performance records and exercise the real timeout observer."""
from pathlib import Path
import copy
import importlib.util
import tempfile
import os
import signal
import threading
import time

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("measurement", HERE / "v11-measure.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def samples(seconds=1.0, peak=1024, outcome="completed"):
    return [dict(elapsed_seconds=seconds, peak_rss_kib=peak, outcome=outcome,
                 verified=outcome == "completed") for _ in range(5)]


def main():
    if not __debug__:
        raise SystemExit("Do not disable verification assertions")
    cell = dict(timeout=30, improvement=True)
    baseline, candidate = samples(), samples(0.5)
    assert m.profile.decide(cell, baseline, candidate)["status"] == "pass"
    assert "improvement" in m.profile.decide(cell, baseline, samples(0.8))["reasons"]
    overlapping = samples(0.5)
    overlapping[0]["elapsed_seconds"] = 1.0
    assert "improvement" in m.profile.decide(cell, baseline, overlapping)["reasons"]
    ordinary = dict(cell, improvement=False)
    assert "time regression" in m.profile.decide(ordinary, baseline, samples(1.306))["reasons"]
    assert "RSS regression" in m.profile.decide(ordinary, baseline, samples(1, 2305))["reasons"]
    assert "absolute budget" in m.profile.decide(ordinary, samples(40, 40000), samples(31, 33000))["reasons"]
    timeout = samples(outcome="timeout")
    result = m.profile.decide(ordinary, timeout, candidate)
    assert result["status"] == "pass" and not result["relative_comparison"]
    assert m.profile.decide(cell, timeout, candidate)["status"] == "unresolved"
    mixed = copy.deepcopy(baseline)
    mixed[0] = timeout[0]
    assert m.profile.decide(ordinary, mixed, candidate)["status"] == "unresolved"
    incorrect = copy.deepcopy(candidate)
    incorrect[2]["verified"] = False
    assert m.profile.decide(ordinary, baseline, incorrect)["status"] == "fail"
    assert m.profile.decide(ordinary, incorrect, candidate)["status"] == "fail"
    noisy = samples()
    noisy[0]["elapsed_seconds"] = 1.5
    assert m.profile.decide(ordinary, noisy, candidate)["status"] == "unresolved"
    assert len(m.profile.matrix()) == 74
    with tempfile.TemporaryDirectory(prefix="mognitio-observer-") as temporary:
        root = Path(temporary)
        cell = dict(family="levi", timeout=2)
        row = m.observe(Path("/usr/bin/true"), cell, root, "normal")
        assert row["verified"] and row["outcome"] == "completed"
        image = root / "delayed"
        image.write_text("#!/usr/bin/python3\nimport time\ntime.sleep(2)\n")
        image.chmod(0o700)
        row = m.observe(image, dict(cell, timeout=0.03), root, "timeout")
        assert row["outcome"] == "timeout" and not row["verified"]
        assert 0.025 <= row["elapsed_seconds"] < 1.0
        image.write_text("#!/usr/bin/python3\nprint('unexpected')\n")
        row = m.observe(image, cell, root, "wrong-output")
        assert not row["verified"] and row["validation_error"] == "unexpected consumer stdout"
        image.write_text("#!/usr/bin/python3\nimport os,time\nfrom pathlib import Path\nPath('child-pid').write_text(str(os.getpid()))\ntime.sleep(5)\n")
        alarm = threading.Timer(0.1, lambda: os.kill(os.getpid(), signal.SIGINT))
        alarm.start()
        interrupted = False
        try:
            m.observe(image, dict(cell, timeout=10), root, "interrupted")
        except KeyboardInterrupt:
            interrupted = True
        finally:
            alarm.cancel()
            alarm.join()
        child_status = Path("/proc/" + (root / "child-pid").read_text() + "/stat")
        def terminated():
            try:
                return child_status.read_text().split()[2] == "Z"
            except FileNotFoundError:
                return True
        deadline = time.monotonic() + 1
        while not terminated() and time.monotonic() < deadline:
            time.sleep(0.01)
        assert interrupted and terminated()
        # The direct time-wrapper child was reaped. Its killed native child may
        # briefly be a terminated zombie awaiting the system reaper.
        try:
            os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            pass
        else:
            raise AssertionError("observer left an unreaped direct child")
        original = (root / "interrupted.out").read_bytes()
        row = m.observe(Path("/usr/bin/true"), cell, root, "interrupted")
        assert row["verified"] and row["stdout_file"] != "interrupted.out"
        assert "interrupted.out" in row["earlier_attempt_files"]
        assert (root / "interrupted.out").read_bytes() == original
    print("MEASUREMENT_CHECK_OK threshold_controls=12 matrix_cells=74 process_controls=5")


if __name__ == "__main__":
    main()
