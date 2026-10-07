#!/usr/bin/env python3
"""Exercise resume through main with real OS conditions and synthetic timings."""
from pathlib import Path
import copy
import importlib.util
import json
import os
import resource
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent


def load_measurement():
    spec = importlib.util.spec_from_file_location("measurement", HERE / "v11-measure.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def fixture_run():
    m = load_measurement()
    original = m.profile.matrix()
    ids = [f"{mode}-ascii-4096{suffix}" for mode in ("scalars", "scan", "combined")
           for suffix in ("", "-repeat-32")]
    cells = [dict(next(c for c in original if c["id"] == name), improvement=False)
             for name in ids]
    m.profile.matrix = lambda: cells
    count = 0
    def observe(image, cell, folder, prefix):
        nonlocal count
        count += 1
        if os.environ.get("STOP_AFTER") == str(count - 1):
            raise KeyboardInterrupt
        return dict(outcome="completed", verified=True, elapsed_seconds=1.0,
                    peak_rss_kib=1024, exit=0)
    m.observe = observe
    if os.environ.get("CHANGE_AFFINITY"):
        os.sched_setaffinity(0, {min(os.sched_getaffinity(0))})
    if os.environ.get("CHANGE_LIMIT"):
        soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
        resource.setrlimit(resource.RLIMIT_NOFILE, (soft - 1, hard))
    sys.argv = [sys.argv[0], *sys.argv[2:]]
    return m.main()


def main():
    m = load_measurement()
    with tempfile.TemporaryDirectory(prefix="mognitio-resume-") as temporary:
        root = Path(temporary)
        images = root / "images"
        images.mkdir()
        (images / "identity.json").write_text(json.dumps(dict(source_files={}, images={})))
        evidence = root / "evidence"
        def run(*, resume=False, **changes):
            command = [sys.executable, __file__, "--fixture", "--baseline", str(images),
                       "--candidate", str(images), "--evidence", str(evidence)]
            if resume:
                command.append("--resume")
            env = dict(os.environ)
            for key in ("STOP_AFTER", "CHANGE_AFFINITY", "CHANGE_LIMIT"):
                env.pop(key, None)
            env.update(changes)
            return subprocess.run(command, env=env, capture_output=True, text=True)
        initial = run(STOP_AFTER="7")
        assert initial.returncode != 0, initial.stdout
        checkpoint = evidence / "results.json"
        saved = checkpoint.read_bytes()
        record = json.loads(saved)
        batch = record["cells"][0]["batches"][0]
        # Interrupted immediately after baseline sample 3, with candidate at 2.
        assert len(batch["samples"]["baseline"]) == 3
        assert len(batch["samples"]["candidate"]) == 2
        def rejected(result, message, expected):
            assert result.returncode != 0 and message in result.stderr, result.stderr
            assert checkpoint.read_bytes() == expected
            assert sorted(p.name for p in evidence.iterdir()) == [
                "results.json", "scalars-ascii-4096"]
        assert len(os.sched_getaffinity(0)) >= 2, "resume control requires two allowed CPUs"
        rejected(run(resume=True, CHANGE_AFFINITY="1"), "resume environment mismatch", saved)
        rejected(run(resume=True, CHANGE_LIMIT="1"), "resume environment mismatch", saved)
        for target in ("warmup", "sample", "batch", "environment", "legacy", "completed"):
            broken = copy.deepcopy(record)
            b = broken["cells"][0]["batches"][0]
            if target == "warmup":
                b["warmups"]["candidate"]["environment_id"] = "different"
            elif target in ("sample", "completed"):
                b["samples"]["candidate"][0]["environment_id"] = "different"
                if target == "completed":
                    broken["cells"][0]["decision"] = {"status": "pass"}
            elif target == "batch":
                b["environment_id"] = "different"
            elif target == "environment":
                broken["environments"][0]["comparison"]["affinity"] = []
            else:
                del broken["environment_id"]
            checkpoint.write_text(json.dumps(broken))
            rejected(run(resume=True), "environment mismatch", checkpoint.read_bytes())
        # Dynamic diagnostics can change without replacing comparison identity.
        dynamic = copy.deepcopy(record)
        dynamic["environments"][0].update(load=[999, 999, 999], memory="historical",
                                          cpu="historical", start_utc="historical")
        checkpoint.write_text(json.dumps(dynamic))
        positive = run(resume=True)
        assert positive.returncode == 0, positive.stderr
        completed = json.loads(checkpoint.read_text())
        assert completed["status"] == "pass" and len(completed["environments"]) == 2
        assert completed["cells"][0]["batches"][0]["samples"]["baseline"][:3] == batch["samples"]["baseline"]
        assert len(completed["cells"]) == 6
        assert sum(len(b["warmups"]) + sum(map(len, b["samples"].values()))
                   for c in completed["cells"] for b in c["batches"]) == 72
        completed_bytes = checkpoint.read_bytes()
        rejected_complete = run(resume=True, CHANGE_LIMIT="1")
        assert rejected_complete.returncode != 0 and checkpoint.read_bytes() == completed_bytes
        # A change detected around an observation is rejected before aggregation.
        environment = m.environments.capture(evidence)
        limits = resource.getrlimit(resource.RLIMIT_NOFILE)
        try:
            resource.setrlimit(resource.RLIMIT_NOFILE, (limits[0] - 1, limits[1]))
            try:
                m.environments.require_current(evidence, environment["environment_id"])
            except ValueError as error:
                assert "changed during measurement" in str(error)
            else:
                raise AssertionError("mid-run limit change accepted")
        finally:
            resource.setrlimit(resource.RLIMIT_NOFILE, limits)
        # Reproduce the numerical counterexample; provenance must reject it.
        synthetic = copy.deepcopy(batch)
        for side, values in (("baseline", [10, 10, 10, 9, 9]),
                             ("candidate", [10, 10, 9, 9, 9])):
            synthetic["samples"][side] = [
                dict(outcome="completed", verified=True, peak_rss_kib=1024,
                     elapsed_seconds=value, environment_id="A" if value == 10 else "B")
                for value in values]
        assert m.profile.decide(dict(timeout=30, improvement=False),
                                **synthetic["samples"])["status"] == "pass"
        try:
            m.environments.check_batch(synthetic, synthetic["environment_id"])
        except ValueError as error:
            assert "sample environment mismatch" in str(error)
        else:
            raise AssertionError("mixed timing counterexample accepted")
    print("RESUME_CHECK_OK negative_controls=11 positive_resume=1 observations=72 synthetic_counterexample=1")


if __name__ == "__main__":
    if not __debug__:
        raise SystemExit("Do not disable verification assertions")
    if len(sys.argv) > 1 and sys.argv[1] == "--fixture":
        raise SystemExit(fixture_run())
    main()
