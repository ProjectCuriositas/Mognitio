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

def regular_input(path):
    """Inspect input kinds without opening special files or following directory links."""
    try:
        for component in [path, *path.parents]:
            info = component.lstat()
            if stat.S_ISLNK(info.st_mode):
                raise InputError("Symlink input is forbidden")
            if component == path and not stat.S_ISREG(info.st_mode):
                raise InputError("Source must be a regular file")
        return path.lstat()
    except OSError as error:
        raise InputError("Cannot inspect source input") from error

def syntax_snapshot(documents):
    sources, unavailable = {}, {}
    total = 0
    for uri, doc in sorted(documents.items()):
        try:
            regular_input(Path(path_from_uri(uri)))
            if doc["text"] is None:
                raise InputError("Open document is unavailable")
            text = valid_text(doc["text"])
        except InputError as error:
            unavailable[uri] = str(error)
            continue
        total += len(text.encode("utf-8"))
        if len(sources) >= SOURCE_COUNT or total > PROJECT_BYTES:
            raise InputError("Standalone source budget exceeded")
        sources[uri] = text
    return {"root": None, "sources": sources, "unavailable": unavailable}

def discover(root, documents):
    if root is None:
        return syntax_snapshot(documents)
    base = Path(root)
    manifest = base / "mognitio.toml"
    try:
        if not stat.S_ISREG(manifest.lstat().st_mode):
            raise InputError("Expected a regular mognitio.toml")
    except FileNotFoundError:
        source_root = base / "src"
        return syntax_snapshot({uri: doc for uri, doc in documents.items()
                                if Path(path_from_uri(uri)).is_relative_to(source_root)})
    except OSError as error:
        raise InputError("Cannot inspect workspace mognitio.toml") from error
    sources, ids = {}, set()
    deadline = time.monotonic() + 5
    entries = 0
    total = 0

    def walk(path, depth):
        nonlocal entries, total
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
            info = regular_input(path)
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
            total += len(text.encode("utf-8"))
            if total > PROJECT_BYTES:
                raise InputError("Project source bytes exceeded")
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

def position_steps(text, offsets):
    """Visit requested UTF-8 boundaries once, yielding at most every 4096 scalars."""
    needed = set(offsets)
    positions = {}
    byte = line = column = 0
    previous_cr = False
    for index, char in enumerate(text):
        if byte in needed:
            positions[byte] = {"line": line, "character": column}
            if len(positions) == len(needed):
                return positions
        code = ord(char)
        byte += 1 if code < 0x80 else 2 if code < 0x800 else 3 if code < 0x10000 else 4
        if char == "\r":
            line += 1
            column = 0
        elif char == "\n":
            if not previous_cr:
                line += 1
            column = 0
        else:
            column += 2 if code > 0xffff else 1
        previous_cr = char == "\r"
        if index % 4096 == 4095:
            yield
    if byte in needed:
        positions[byte] = {"line": line, "character": column}
    if positions.keys() != needed:
        raise ValueError("Diagnostic offset is not a UTF-8 source boundary")
    return positions

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
    if not rows:
        return []
    endpoints = {offset for row in rows for offset in row[:2]}
    positions = {}
    byte = line = column = 0
    previous_cr = False
    for char in text:
        if byte in endpoints:
            positions[byte] = {"line": line, "character": column}
        byte += len(char.encode("utf-8"))
        if char == "\r":
            line += 1
            column = 0
        elif char == "\n":
            if not previous_cr:
                line += 1
            column = 0
        else:
            column += 2 if ord(char) > 0xffff else 1
        previous_cr = char == "\r"
    positions[byte] = {"line": line, "character": column}
    result = []
    last_line = last_column = 0
    for start, end, kind, modifiers in rows:
        first, final = positions[start], positions[end]
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
