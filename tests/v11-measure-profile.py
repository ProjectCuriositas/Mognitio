"""Fixed input matrix and acceptance rules for the native workload comparison."""
import statistics


def matrix():
    cells = []
    for mode in ("scalars", "join", "scan", "symbols", "combined"):
        for shape, pattern in (("ascii", "abc;d=ef "), ("unicode", "あ😀;e\u0301=x ")):
            for size in (256, 1024, 4096, 16384):
                text = (pattern * ((size + len(pattern) - 1) // len(pattern)))[:size]
                name = "name" if shape == "ascii" else "名前😀"
                if mode == "symbols":
                    text = "\n".join(f"{name}{n}" for n in range(size // 16))
                if mode == "join":
                    text = text.replace(";", "\n")
                queries = ["abc", "あ😀", f"{name}0", f"{name}{size // 32}", "missing"]
                cells.append(dict(id=f"{mode}-{shape}-{size}", family="workload", mode=mode,
                                  shape=shape, size=size, text=text, queries=queries, repeats=1,
                                  timeout=30, improvement=mode == "scalars" and size == 4096))
    for kind in ("scan-control", "scan", "join-control", "join"):
        for shape, pattern in (("ascii", "abcdef09"), ("unicode", "日😀e\u0301<&>\"")):
            for size in (256, 1024, 4096):
                text = (pattern * ((size + len(pattern) - 1) // len(pattern)))[:size]
                cells.append(dict(id=f"levi-{kind}-{shape}-{size}", family="levi", mode=kind,
                                  shape=shape, size=size, text=text, repeats=4, timeout=30,
                                  improvement=kind == "scan" and size == 4096))
    cells.append(dict(id="levi-stress-16384-32", family="levi", mode="stress", shape="ascii",
                      size=16384, text="abcdef09" * 2048, repeats=32, timeout=120, improvement=False))
    # One repetition is the matching normal ASCII cell; the retention series
    # uses that exact input and query set rather than changing the workload.
    for mode in ("scalars", "scan", "combined"):
        normal = next(c for c in cells if c["id"] == f"{mode}-ascii-4096")
        for repeats in (4, 16, 32):
            cells.append(dict(normal, id=f"{mode}-ascii-4096-repeat-{repeats}",
                              repeats=repeats, timeout=120, improvement=False))
    return cells


def summary(samples):
    complete = [s for s in samples if s["outcome"] == "completed" and s["verified"]]
    if len(complete) != len(samples):
        if all(s["outcome"] == "timeout" for s in samples):
            return dict(status="timeout")
        return dict(status="incomplete")
    values = [s["elapsed_seconds"] for s in complete]
    median = statistics.median(values)
    return dict(status="complete", median=median, minimum=min(values), maximum=max(values),
                peak=max(s["peak_rss_kib"] for s in complete),
                noisy=max(values)-min(values) > max(median*0.30, 0.005))


def decide(cell, baseline, candidate):
    before, after = summary(baseline), summary(candidate)
    reasons = []
    if after["status"] != "complete":
        reasons.append("candidate did not complete with verified results")
    else:
        if after["noisy"]:
            reasons.append("candidate noise")
        if after["maximum"] > cell["timeout"] or after["peak"] > 32768:
            reasons.append("absolute budget")
    if before["status"] == "complete":
        if before["noisy"]:
            reasons.append("baseline noise")
        if after["status"] == "complete":
            if after["median"] > before["median"] * 1.30 + 0.005:
                reasons.append("time regression")
            if after["peak"] > before["peak"] * 1.25 + 1024:
                reasons.append("RSS regression")
            if cell["improvement"] and not (
                    after["median"] <= before["median"] * 0.70 and after["maximum"] < before["minimum"]):
                reasons.append("improvement")
    elif before["status"] != "timeout" or cell["improvement"]:
        reasons.append("baseline comparison unavailable")
    return dict(status="pass" if not reasons else "unresolved" if all("noise" in r for r in reasons) else "fail",
                reasons=reasons, baseline=before, candidate=after,
                relative_comparison=before["status"] == "complete")
