"""Stable comparison identity and provenance checks for resumable measurements."""
from pathlib import Path
import hashlib
import json
import os
import platform
import resource
import subprocess
import time


def identity(conditions):
    payload = json.dumps(conditions, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(payload.encode()).hexdigest()


def capture(folder):
    cpu = Path("/proc/cpuinfo").read_text()
    # Frequency, load, available memory and timestamps are observations, not
    # equality gates. Keep per-processor topology, model and capabilities.
    fields = {"processor", "vendor_id", "cpu family", "model", "model name",
              "stepping", "microcode", "physical id", "siblings", "core id",
              "cpu cores", "flags"}
    processors = []
    for block in cpu.strip().split("\n\n"):
        values = {}
        for line in block.splitlines():
            key, separator, value = line.partition(":")
            if separator and key.strip() in fields:
                values[key.strip()] = value.strip()
        processors.append(values)
    conditions = dict(
        schema=1, machine=hashlib.sha256(Path("/etc/machine-id").read_bytes()).hexdigest(),
        architecture=platform.machine(), kernel=list(platform.uname()[2:4]),
        os_release=Path("/etc/os-release").read_text(), processors=processors,
        python=dict(version=platform.python_version(), implementation=platform.python_implementation()),
        time_version=subprocess.check_output(["/usr/bin/time", "--version"], text=True),
        time_sha256=hashlib.sha256(Path("/usr/bin/time").read_bytes()).hexdigest(),
        clock="monotonic; before Popen through blocking wait return; oracle after timer",
        rss_scope="GNU time maximum resident set size of the native child; KiB",
        cache="one warm-up per batch; no cache eviction",
        filesystem=subprocess.check_output(
            ["findmnt", "-T", str(folder), "-n", "-o", "SOURCE,TARGET,FSTYPE,OPTIONS"],
            text=True).strip(),
        resource_limits={name: list(resource.getrlimit(getattr(resource, name)))
                         for name in sorted(dir(resource)) if name.startswith("RLIMIT_")},
        affinity=sorted(os.sched_getaffinity(0)))
    return dict(environment_id=identity(conditions), comparison=conditions, cpu=cpu,
                memory=Path("/proc/meminfo").read_text(), load=os.getloadavg(),
                start_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))


def reject(reason):
    raise ValueError(reason + "; preserve this evidence and use a fresh --evidence directory")


def check_batch(batch, expected):
    if batch.get("environment_id") != expected:
        reject("batch environment mismatch")
    rows = list(batch["warmups"].values())
    rows += [row for side in ("baseline", "candidate") for row in batch["samples"][side]]
    if any(row.get("environment_id") != expected for row in rows):
        reject("sample environment mismatch")


def validate(record, current):
    expected = current["environment_id"]
    if record.get("environment_id") != expected:
        reject("resume environment mismatch or legacy checkpoint")
    for environment in record["environments"]:
        if (environment.get("environment_id") != expected
                or identity(environment.get("comparison")) != expected):
            reject("recorded environment mismatch")
    # Check completed cells too, before the caller can skip their decisions.
    for entry in record["cells"]:
        for batch in entry["batches"]:
            check_batch(batch, expected)


def require_current(folder, expected):
    if capture(folder)["environment_id"] != expected:
        reject("execution environment changed during measurement")
