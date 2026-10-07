#!/usr/bin/env python3
"""Compare immutable native images under the fixed v1.1 acceptance profile."""
from pathlib import Path
import argparse
import hashlib
import importlib.util
import json
import os
import signal
import subprocess
import threading
import time

HERE = Path(__file__).resolve().parent


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


profile = load("profile", HERE / "v11-measure-profile.py")
oracle = load("oracle", HERE / "v11-workloads.py")
environments = load("environments", HERE / "v11-measure-environment.py")


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def observe(image, cell, folder, prefix):
    original_prefix, attempt, earlier = prefix, 0, []
    while True:
        outpath, errpath, timer = [folder / (prefix + suffix) for suffix in (".out", ".err", ".time")]
        existing = [p.name for p in (outpath, errpath, timer) if p.exists()]
        if not existing:
            break
        earlier.extend(existing)
        attempt += 1
        prefix = f"{original_prefix}-retry-{attempt}"
    command = [str(image)]
    if cell["family"] == "workload":
        command += [cell["mode"], str(folder / "input"), str(cell["repeats"]), str(folder / "queries")]
    finished = threading.Event()
    result = {}
    with outpath.open("xb") as out, errpath.open("xb") as err:
        start = time.monotonic()
        process = subprocess.Popen(["/usr/bin/time", "-f", "%M", "-o", str(timer), *command],
                                   stdout=out, stderr=err, cwd=folder, start_new_session=True,
                                   env={"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8"})
        def reap():
            result["exit"] = process.wait()
            result["elapsed_seconds"] = time.monotonic() - start
            finished.set()
        waiter = threading.Thread(target=reap)
        waiter.start()
        outcome = "completed"
        def terminate():
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            waiter.join()
        try:
            if not finished.wait(cell["timeout"]):
                outcome = "timeout"
                terminate()
            else:
                waiter.join()
        except BaseException:
            terminate()
            raise
    lines = timer.read_text().splitlines() if timer.exists() else []
    result.update(outcome=outcome, verified=False, peak_rss_kib=int(lines[-1]) if lines and lines[-1].isdigit() else None,
                  command=command, cwd=str(folder), image_sha256=digest(image),
                  stdout_sha256=digest(outpath), stderr_sha256=digest(errpath),
                  stdout_bytes=outpath.stat().st_size, stdout_file=outpath.name, stderr_file=errpath.name,
                  earlier_attempt_files=earlier)
    if outcome == "completed" and result["exit"] == 0:
        try:
            if errpath.stat().st_size:
                raise ValueError("unexpected stderr")
            if result["peak_rss_kib"] is None:
                raise ValueError("missing peak RSS")
            if cell["family"] == "workload":
                oracle.check(outpath, cell["mode"], cell["text"], cell["queries"], cell["repeats"])
            elif outpath.stat().st_size:
                raise ValueError("unexpected consumer stdout")
            result["verified"] = True
        except (AssertionError, ValueError, UnicodeError) as error:
            result["validation_error"] = str(error)
    return result


def save(path, value):
    temporary = path.with_suffix(".pending")
    temporary.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")
    temporary.replace(path)


def main():
    if not __debug__:
        raise SystemExit("Do not disable verification assertions")
    def interrupted(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--resume", action="store_true")
    args = parser.parse_args()
    roots = {name: getattr(args, name).resolve() for name in ("baseline", "candidate")}
    identities = {name: json.loads((root / "identity.json").read_text()) for name, root in roots.items()}
    assert identities["baseline"]["source_files"] == identities["candidate"]["source_files"], "source mismatch"
    for side, identity in identities.items():
        for name, image in identity["images"].items():
            assert digest(roots[side] / name) == image["sha256"], "image changed"
    tools = {p.name: digest(p) for p in (Path(__file__), HERE / "v11-measure-profile.py", HERE / "v11-workloads.py", HERE / "v11-measure-environment.py")}
    args.evidence = args.evidence.resolve()
    args.evidence.mkdir(parents=True, exist_ok=args.resume)
    checkpoint = args.evidence / "results.json"
    environment = environments.capture(args.evidence)
    environment_id = environment["environment_id"]
    available = int(next(line.split()[1] for line in environment["memory"].splitlines() if line.startswith("MemAvailable:")))
    assert available >= 8 * 1024 * 1024, "less than 8 GiB available"
    record = json.loads(checkpoint.read_text()) if args.resume else dict(identities=identities, tools=tools, environment_id=environment_id, environments=[], cells=[])
    environments.validate(record, environment)
    assert record["identities"] == identities and record["tools"] == tools, "resume identity mismatch"
    record["environments"].append(environment)
    save(checkpoint, record)
    cells = profile.matrix()
    for index, cell in enumerate(cells):
        if index < len(record["cells"]):
            entry = record["cells"][index]
            assert entry["cell"] == cell
            if "decision" in entry:
                continue
        else:
            entry = dict(cell=cell, batches=[])
            record["cells"].append(entry)
        folder = args.evidence / cell["id"]
        folder.mkdir(exist_ok=True)
        (folder / "input").write_bytes(cell["text"].encode())
        (folder / "queries").write_bytes("\n".join(cell.get("queries", [])).encode())
        entry["input_sha256"] = digest(folder / "input")
        entry["queries_sha256"] = digest(folder / "queries")
        for batch_index in range(3):
            if batch_index < len(entry["batches"]):
                batch = entry["batches"][batch_index]
                if "decision" in batch:
                    continue
            else:
                batch = dict(environment_id=environment_id, warmups={}, samples={"baseline": [], "candidate": []}, order=[])
                entry["batches"].append(batch)
            for sample in range(-1, 5):
                sides = ("baseline", "candidate") if (index + batch_index + sample) % 2 == 0 else ("candidate", "baseline")
                for side in sides:
                    if sample == -1 and side in batch["warmups"]:
                        continue
                    if sample >= 0 and len(batch["samples"][side]) > sample:
                        continue
                    image = roots[side] / ("workloads" if cell["family"] == "workload" else cell["mode"])
                    prefix = f"batch-{batch_index}-{side}-" + ("warmup" if sample == -1 else str(sample))
                    environments.require_current(args.evidence, environment_id)
                    row = observe(image, cell, folder, prefix)
                    environments.require_current(args.evidence, environment_id)
                    row["environment_id"] = environment_id
                    if sample == -1:
                        batch["warmups"][side] = row
                    else:
                        batch["samples"][side].append(row)
                    batch["order"].append(dict(side=side, sample=sample))
                    save(checkpoint, record)
                    print(cell["id"], batch_index, side, sample, row["outcome"], round(row["elapsed_seconds"], 6), flush=True)
            environments.check_batch(batch, environment_id)
            decision = profile.decide(cell, **batch["samples"])
            warmup = batch["warmups"]["candidate"]
            if not warmup["verified"] or warmup["elapsed_seconds"] > cell["timeout"] or (warmup["peak_rss_kib"] or 0) > 32768:
                decision["status"] = "fail"
                decision["reasons"].append("candidate warmup failed")
            batch["decision"] = decision
            if any("noise" in reason for reason in decision["reasons"]) and batch_index < 2:
                save(checkpoint, record)
                continue
            # A later quiet batch cannot erase an observed wrong result or a
            # candidate budget failure from an earlier noisy batch.
            for previous in entry["batches"]:
                for side in ("baseline", "candidate"):
                    rows = [previous["warmups"][side], *previous["samples"][side]]
                    if any(r["outcome"] == "completed" and not r["verified"] for r in rows):
                        decision["status"] = "fail"
                        decision["reasons"].append(side + " failed result in retained batch")
                    if side == "candidate" and any(
                            r["outcome"] != "completed" or r["elapsed_seconds"] > cell["timeout"]
                            or (r["peak_rss_kib"] or 0) > 32768 for r in rows):
                        decision["status"] = "fail"
                        decision["reasons"].append("candidate budget failure in retained batch")
            entry["decision"] = decision
            save(checkpoint, record)
            print("CELL", cell["id"], json.dumps(decision), flush=True)
            break
    environments.validate(record, environment)
    retention = []
    by_id = {entry["cell"]["id"]: entry for entry in record["cells"]}
    for mode in ("scalars", "scan", "combined"):
        initial = by_id[f"{mode}-ascii-4096"]["decision"]["candidate"]
        final = by_id[f"{mode}-ascii-4096-repeat-32"]["decision"]["candidate"]
        growth = final["peak"] - initial["peak"] if initial["status"] == final["status"] == "complete" else None
        retention.append(dict(mode=mode, growth_kib=growth, status="pass" if growth is not None and growth <= 1024 else "fail"))
    record["retention"] = retention
    record["status"] = "pass" if all(e["decision"]["status"] == "pass" for e in record["cells"]) and all(r["status"] == "pass" for r in retention) else "not-passed"
    save(checkpoint, record)
    print("RESULT", record["status"], flush=True)
    return 0 if record["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
