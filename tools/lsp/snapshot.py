"""Snapshot discovery and coordinates; no compiler rules live here."""
import os
from pathlib import Path
import stat
import time
from urllib.parse import urlsplit, unquote, quote

SOURCE_BYTES = 4 * 1024 * 1024
PROJECT_BYTES = 64 * 1024 * 1024
SOURCE_COUNT = 4096

class InputError(Exception):
    pass

def path_from_uri(uri):
    if not isinstance(uri, str):
        raise InputError("Expected a file URI")
    parsed = urlsplit(uri)
    if parsed.scheme != "file" or parsed.netloc not in ("", "localhost") or parsed.query or parsed.fragment:
        raise InputError("Only local file URIs are supported")
    path = unquote(parsed.path, encoding="utf-8", errors="strict")
    if "\0" in path or not os.path.isabs(path):
        raise InputError("Invalid file URI")
    return os.path.normpath(path)

def uri_from_path(path):
    return "file://" + quote(str(path), safe="/")

def valid_text(text):
    if not isinstance(text, str):
        raise InputError("Full synchronization requires text")
    try:
        size = len(text.encode("utf-8"))
    except UnicodeError as error:
        raise InputError("Source contains an isolated surrogate") from error
    if size > SOURCE_BYTES:
        raise InputError("Source exceeds 4 MiB")
    return text

def disk_text(path):
    try:
        with open(path, "rb") as stream:
            data = stream.read(SOURCE_BYTES + 1)
        return valid_text(data.decode("utf-8"))
    except (OSError, UnicodeError) as error:
        raise InputError("Source cannot be read as UTF-8") from error

def discover(root, documents):
    if root is None:
        sources = {}
        for uri, doc in sorted(documents.items()):
            if doc["text"] is None:
                raise InputError("Open document is unavailable")
            sources[uri] = doc["text"]
        return {"root": None, "sources": sources}
    base = Path(root)
    manifest = base / "mognitio.toml"
    try:
        if not stat.S_ISREG(manifest.lstat().st_mode):
            raise InputError("Expected a regular mognitio.toml")
    except OSError as error:
        raise InputError("Workspace folder needs its own mognitio.toml") from error
    sources, ids = {}, set()
    deadline = time.monotonic() + 5
    entries = 0

    def walk(path, depth):
        nonlocal entries
        entries += 1
        if entries > 65536 or depth > 64 or time.monotonic() >= deadline:
            raise InputError("Directory exploration budget exceeded")
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode):
            raise InputError("Symlink input is forbidden")
        if stat.S_ISDIR(info.st_mode):
            children = []
            with os.scandir(path) as iterator:
                for entry in iterator:
                    children.append(entry.name)
                    if entries + len(children) > 65536 or time.monotonic() >= deadline:
                        raise InputError("Directory exploration budget exceeded")
            for name in sorted(children):
                walk(path / name, depth + 1)
        elif path.suffix == ".mgn":
            if not stat.S_ISREG(info.st_mode):
                raise InputError("Source must be a regular file")
            identity = (info.st_dev, info.st_ino)
            if identity in ids:
                raise InputError("Duplicate physical input")
            ids.add(identity)
            uri = uri_from_path(path)
            doc = documents.get(uri)
            if doc is not None:
                if doc["text"] is None:
                    raise InputError("Open document is unavailable")
                text = doc["text"]
            else:
                text = disk_text(path)
            sources[path.relative_to(base).as_posix()] = text
            if len(sources) > SOURCE_COUNT:
                raise InputError("Project source count exceeded")

    try:
        walk(base / "src", 0)
    except OSError as error:
        raise InputError("Cannot discover project inputs") from error
    if sum(len(text.encode("utf-8")) for text in sources.values()) > PROJECT_BYTES:
        raise InputError("Project source bytes exceeded")
    return {"root": root, "manifest": disk_text(manifest), "sources": sources}

def position(text, byte):
    data = text.encode("utf-8")
    byte = max(0, min(len(data), byte))
    prefix = data[:byte].decode("utf-8", errors="strict")
    line = 0
    start = 0
    i = 0
    while i < len(prefix):
        if prefix[i] == "\r":
            line += 1
            i += 1
            if i < len(prefix) and prefix[i] == "\n":
                i += 1
            start = i
        elif prefix[i] == "\n":
            line += 1
            i += 1
            start = i
        else:
            i += 1
    return {"line": line, "character": len(prefix[start:].encode("utf-16-le")) // 2}

def token_data(text, rows, mapping):
    result = []
    last_line = last_column = 0
    for start, end, kind, modifiers in rows:
        first, final = position(text, start), position(text, end)
        if first["line"] != final["line"] or final["character"] <= first["character"]:
            continue
        target = mapping.get(kind)
        if target is None:
            continue
        line, column = first["line"], first["character"]
        result.extend([line - last_line, column - last_column if line == last_line else column,
                       final["character"] - column, target, modifiers])
        last_line, last_column = line, column
    return result
