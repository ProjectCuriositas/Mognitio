#!/usr/bin/env python3
"""Independent result oracle and process observations for compiler workloads."""
from pathlib import Path
import argparse
import hashlib
import itertools
import json
import re
import subprocess
import tempfile
import threading
import shutil
import time

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "examples/compiler-workloads/mognitio.toml"
MODES = ("scalars", "join", "scan", "symbols", "combined")


def tokens(text):
    for match in re.finditer(r"[^ \t\r\n()=,;]+|[()=,;]", text):
        word = match.group()
        yield ("W" if word not in "()=,;" else "P", word, match.start(), match.end())


def oracle(mode, text, queries, repeats):
    for iteration in range(repeats):
        yield ("ITER", iteration)
        names = []
        if mode == "scalars":
            yield ("SCALARS", len(text))
            yield from (("STRING", char) for char in text)
        elif mode == "join":
            yield ("TEXT", 1)
            yield ("STRING", "|".join(text.split("\n")))
        elif mode in ("scan", "combined"):
            scanned = list(tokens(text))
            yield ("TOKENS", len(scanned))
            yield from scanned
            names = [row[1] for row in scanned if row[0] == "W"]
        elif mode == "symbols":
            names = text.split("\n") if text else []
        else:
            raise ValueError(mode)
        if mode in ("symbols", "combined"):
            table = {}
            ids = []
            for name in names:
                if not name:
                    raise ValueError("empty symbol name")
                if name not in table:
                    table[name] = len(table)
                ids.append(table[name])
            yield ("IDS", len(ids))
            yield from (("ID", value) for value in ids)
            yield ("SYMBOLS", len(table))
            yield from ((value, key) for key, value in table.items())
            yield ("LOOKUPS", len(queries))
            yield from ((query, table.get(query)) for query in queries)
            if mode == "combined":
                yield ("TEXT", 1)
                yield ("STRING", "|".join(names))
    yield ("END",)


def observed(path):
    # Decode once, preserving CR/LF, BOM and NUL. Cursor operations are forward-only.
    text = Path(path).read_bytes().decode("utf-8", errors="strict")
    cursor = 0

    def line():
        nonlocal cursor
        end = text.find("\n", cursor)
        if end < 0:
            raise ValueError("truncated line")
        value = text[cursor:end]
        cursor = end + 1
        return value

    def natural():
        value = line()
        if not re.fullmatch(r"0|[1-9][0-9]{0,18}", value):
            raise ValueError("invalid natural")
        return int(value)

    def string():
        nonlocal cursor
        end = text.find(":", cursor)
        if end < 0 or not re.fullmatch(r"0|[1-9][0-9]{0,18}", text[cursor:end]):
            raise ValueError("invalid string length")
        size = int(text[cursor:end])
        cursor = end + 1
        value = text[cursor:cursor + size]
        cursor += size
        if cursor >= len(text) or text[cursor] != "\n":
            raise ValueError("truncated string")
        cursor += 1
        return value

    if line() != "MGN11R1":
        raise ValueError("invalid magic")
    while cursor < len(text):
        tag = line()
        if tag == "END":
            if cursor != len(text):
                raise ValueError("trailing output")
            yield ("END",)
            return
        if tag == "ITER":
            yield (tag, natural())
            continue
        if tag not in ("SCALARS", "TOKENS", "IDS", "SYMBOLS", "LOOKUPS", "TEXT"):
            raise ValueError("unknown section")
        count = natural()
        yield (tag, count)
        for _ in range(count):
            if tag in ("SCALARS", "TEXT"):
                yield ("STRING", string())
            elif tag == "TOKENS":
                kind = line()
                if kind not in ("W", "P"):
                    raise ValueError("invalid token kind")
                yield (kind, string(), natural(), natural())
            elif tag == "IDS":
                yield ("ID", natural())
            elif tag == "SYMBOLS":
                yield (natural(), string())
            else:
                query, kind = string(), line()
                if kind not in ("F", "N"):
                    raise ValueError("invalid lookup kind")
                yield (query, natural() if kind == "F" else None)
    raise ValueError("missing END")


def check(path, mode, text, queries, repeats):
    missing = object()
    for index, (actual, expected) in enumerate(itertools.zip_longest(
            observed(path), oracle(mode, text, queries, repeats), fillvalue=missing)):
        if actual != expected:
            raise AssertionError(f"record {index}: expected {expected!r}, got {actual!r}")


def run(image, mode, text, queries, repeats, folder, prefix, timeout=30, host=False, cwd=None, env=None):
    folder = Path(folder)
    input_file, query_file = folder / "input", folder / "queries"
    input_file.write_bytes(text.encode())
    query_file.write_bytes("\n".join(queries).encode())
    output, error, timer = (folder / (prefix + suffix) for suffix in (".out", ".err", ".time"))
    command = ([str(image), "run", str(PROJECT), "--"] if host else [str(image)])
    command += [mode, str(input_file), str(repeats), str(query_file)]
    started = time.monotonic()
    with output.open("wb") as out, error.open("wb") as err:
        process = subprocess.Popen(["/usr/bin/time", "-f", "%M", "-o", str(timer), *command],
                                   stdout=out, stderr=err, start_new_session=True, cwd=cwd, env=env)
        outcome = "completed"
        result = {}
        done = threading.Event()

        def reap():
            result["code"] = process.wait()
            result["elapsed"] = time.monotonic() - started
            done.set()

        waiter = threading.Thread(target=reap)
        waiter.start()
        if not done.wait(timeout):
            import os
            import signal
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            outcome = "timeout"
        waiter.join()
        code = result["code"] if outcome == "completed" else None
    elapsed = result["elapsed"]
    row = dict(outcome=outcome, exit=code, elapsed_seconds=elapsed, timeout_seconds=timeout,
               input_sha256=hashlib.sha256(input_file.read_bytes()).hexdigest(),
               output_sha256=hashlib.sha256(output.read_bytes()).hexdigest(),
               output_bytes=output.stat().st_size, output_file=output.name, stderr_file=error.name)
    rss = timer.read_text().strip().splitlines() if timer.exists() else []
    row["peak_rss_kib"] = int(rss[-1]) if rss and rss[-1].isdigit() else None
    if code == 0:
        check(output, mode, text, queries, repeats)
        if error.read_bytes():
            raise AssertionError("unexpected stderr")
        row["verified"] = True
    else:
        row["verified"] = False
    return row


def verify(image, folder):
    cases = ["", "a=あ;a A", " \t\r\n", "((a));", "e\u0301=😀",
             "\ufeffa\0", " a\r\nあ ", "hello", "a|:b\nline"]
    serial = 0
    for mode in MODES:
        for text in cases:
            if mode == "symbols" and any(not n for n in text.split("\n")) and text:
                continue
            queries = ["a", "あ", "A", "missing", "=", ";"]
            for host in (False, True):
                row = run(ROOT / "bin/mgn" if host else image, mode, text, queries, 2,
                          folder, f"correct-{serial}", host=host)
                assert row["verified"], row
                serial += 1
    # Corrupt valid output: changing an interior field, truncating, duplication, trailing data.
    good = run(image, "combined", "a=あ;a A", ["a", "missing"], 1, folder, "control")
    source = (Path(folder) / good["output_file"]).read_bytes()
    mutations = [source.replace(b"1:a\n", b"1:z\n", 1), source[:-1], source + source,
                 source.replace(b"TOKENS\n6\n", b"TOKENS\n5\n"), source + b"x",
                 source.replace(b"TEXT\n1\n", b"TEXT\n0\n"),
                 source.replace(b"7:a|", b"7:z|"),
                 source.replace(b"IDS\n4\n0\n1\n0\n2\n", b"IDS\n4\n0\n1\n0\n3\n")]
    for index, data in enumerate(mutations):
        path = Path(folder) / f"negative-{index}.out"
        path.write_bytes(data)
        try:
            check(path, "combined", "a=あ;a A", ["a", "missing"], 1)
        except (AssertionError, ValueError, UnicodeError):
            continue
        raise AssertionError("observer accepted corruption")
    with tempfile.TemporaryDirectory(prefix="mognitio-workloads-tests-") as temporary:
        standalone = Path(temporary) / "standalone"
        standalone.mkdir()
        copied = standalone / "app"
        shutil.copy2(image, copied)
        isolated = run(copied, "combined", "a=あ;a A", ["a", "missing"], 1,
                       folder, "standalone", cwd=standalone, env={"PATH": "/usr/bin:/bin", "LANG": "C"})
        assert isolated["verified"], isolated
        serial += 1
        invalid = Path(folder) / "invalid-utf8"
        for index, data in enumerate(map(bytes.fromhex, ("c0af", "eda080", "f09f"))):
            invalid.write_bytes(data)
            for host in (False, True):
                command = ([str(ROOT / "bin/mgn"), "run", str(PROJECT), "--"] if host else [str(image)])
                command += ["scan", str(invalid), "1", str(Path(folder) / "queries")]
                bad = subprocess.run(command, capture_output=True, timeout=30)
                assert bad.returncode == 4 and bad.stdout == b"" and bad.stderr == b"panic: input failure" + bytes([10]), bad
                serial += 1

        project = Path(temporary) / "project"
        shutil.copytree(PROJECT.parent, project)
        shutil.copy2(ROOT / "tests/fixtures/v11-checks.mgn", project / "src/checks.mgn")
        checked = subprocess.run([str(ROOT / "bin/mgn"), "test", str(project / "mognitio.toml")],
                                 capture_output=True, timeout=180)
        (Path(folder) / "builtin.stdout").write_bytes(checked.stdout)
        (Path(folder) / "builtin.stderr").write_bytes(checked.stderr)
        assert checked.returncode == 0, checked.stderr.decode(errors="replace")
    print(f"WORKLOADS_OK processes={serial + 2} observer_negatives={len(mutations)} builtin_tests=5")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("verify", "measure"), nargs="?", default="verify")
    parser.add_argument("--image", type=Path)
    parser.add_argument("--evidence", type=Path)
    parser.add_argument("--samples", type=int, default=3)
    parser.add_argument("--warmups", type=int, default=1)
    parser.add_argument("--timeout", type=float, default=15)
    args = parser.parse_args()
    if args.evidence is None:
        with tempfile.TemporaryDirectory(prefix="mognitio-workloads-") as temporary:
            folder = Path(temporary)
            image = folder / "app"
            subprocess.run([str(ROOT / "bin/mgn"), "build", str(PROJECT), "-o", str(image)], check=True)
            verify(image, folder)
        return
    if args.image is None:
        parser.error("--image is required with --evidence")
    args.evidence.mkdir(parents=True, exist_ok=False)
    if args.action == "verify":
        verify(args.image.resolve(), args.evidence)
        return
    rows = []
    for mode in MODES:
        for shape, pattern in (("ascii", "abc;d=ef "), ("unicode", "あ😀;e\u0301=x ")):
            for size in (256, 1024, 4096, 16384):
                text = (pattern * ((size + len(pattern) - 1) // len(pattern)))[:size]
                if mode == "symbols":
                    name = "name" if shape == "ascii" else "名前😀"
                    text = "\n".join(f"{name}{n}" for n in range(size // 16))
                if mode == "join":
                    text = text.replace(";", "\n")
                name = "name" if shape == "ascii" else "名前😀"
                queries = ["abc", "あ😀", f"{name}0", f"{name}{max(0, size // 32)}", "missing"]
                warmups = []
                for warmup in range(args.warmups):
                    warmups.append(run(args.image.resolve(), mode, text, queries, 1, args.evidence,
                                       f"{mode}-{shape}-{size}-warmup-{warmup}", args.timeout))
                samples = []
                for sample in range(args.samples):
                    prefix = f"{mode}-{shape}-{size}-{sample}"
                    row = run(args.image.resolve(), mode, text, queries, 1, args.evidence,
                              prefix, args.timeout)
                    samples.append(row)
                cell = dict(mode=mode, shape=shape, size=size, scalars=len(text),
                            utf8_bytes=len(text.encode()), repeats=1, warmups=warmups, samples=samples)
                rows.append(cell)
                (args.evidence / "samples.json").write_text(json.dumps(rows, indent=2) + "\n")
                print(mode, shape, size, samples[-1]["outcome"],
                      round(samples[-1]["elapsed_seconds"], 4), flush=True)


if __name__ == "__main__":
    main()
