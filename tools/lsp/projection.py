"""Cooperative diagnostic projection; no protocol I/O or mutable session state."""
from pathlib import Path
from snapshot import position_steps, uri_from_path

def diagnostics_steps(snapshot, result):
    texts = dict(snapshot["sources"])
    if "manifest" in snapshot:
        texts["mognitio.toml"] = snapshot["manifest"]
    selected, offsets, counts, messages = [], {}, {}, []
    truncated = len(result["diagnostics"]) > 2000 or result.get("truncated", False)
    for diagnostic in result["diagnostics"][:2000]:
        path = diagnostic.get("path")
        if path not in texts or diagnostic.get("start") is None:
            messages.append(diagnostic["message"])
            yield
            continue
        if counts.get(path, 0) >= 200:
            truncated = True
            continue
        counts[path] = counts.get(path, 0) + 1
        related = [item for item in diagnostic.get("related", [])
                   if item.get("path") in texts and item.get("start") is not None]
        selected.append((diagnostic, related))
        for item in [diagnostic, *related]:
            offsets.setdefault(item["path"], set()).update(
                (item["start"], item["end"] if item.get("end") is not None else item["start"]))
        yield
    positions = {}
    for path, needed in offsets.items():
        positions[path] = yield from position_steps(texts[path], needed)
    def uri(path):
        return uri_from_path(Path(snapshot["root"]) / path) if snapshot["root"] else path
    def span(item):
        index = positions[item["path"]]
        return {"start": index[item["start"]],
                "end": index[item["end"] if item.get("end") is not None else item["start"]]}
    grouped = {}
    for diagnostic, related in selected:
        row = {"range": span(diagnostic), "severity": 1, "source": "Mognitio",
               "code": diagnostic["phase"], "message": diagnostic["message"]}
        if related:
            row["relatedInformation"] = [
                {"location": {"uri": uri(item["path"]), "range": span(item)}, "message": item["message"]}
                for item in related]
        grouped.setdefault(uri(diagnostic["path"]), []).append(row)
        yield
    if truncated:
        messages.append("Diagnostic limit reached; analysis is incomplete")
    return grouped, messages
