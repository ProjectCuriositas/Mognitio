#!/usr/bin/env python3
"""Offline, ownership-recorded user installation. Verify the bundle externally first."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
import sys
import tempfile

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def write_json(path, value):
    fd, name = tempfile.mkstemp(prefix=path.name + ".tmp-", dir=path.parent)
    temporary = Path(name)
    with os.fdopen(fd, "w") as stream:
        json.dump(value, stream, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)

def load(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError("Expected regular metadata")
    return json.loads(path.read_text())

def record(path):
    if path.is_symlink():
        return {"kind": "link", "target": os.readlink(path)}
    if not path.is_file():
        raise ValueError("Not a regular owned file: " + str(path))
    return {"kind": "file", "digest": sha(path), "mode": path.stat().st_mode & 0o777}

def matches(path, value):
    try:
        return record(path) == value
    except (OSError, ValueError):
        return False

def member(prefix, name):
    relative = Path(name)
    if relative.is_absolute() or ".." in relative.parts:
        raise ValueError("Unsafe ownership path")
    target = prefix / relative
    # Do not traverse changed directory links, including within old payloads.
    for parent in target.parents:
        if parent == prefix:
            break
        if parent.is_symlink():
            raise ValueError("Managed directory was replaced by a symlink")
    return target

def version_tuple(value):
    import re
    if not re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", value):
        raise ValueError("Expected a formal release version")
    return tuple(map(int, value.split(".")))

def verify_payload(payload):
    manifest = load(payload / "payload.json")
    expected = manifest["files"]
    actual = {str(p.relative_to(payload)) for p in payload.rglob("*") if p.is_file()}
    if actual != set(expected) | {"payload.json"}:
        raise ValueError("Unexpected or missing payload file")
    for name, item in expected.items():
        path = member(payload, name)
        if path.is_symlink() or not path.is_file() or sha(path) != item["sha256"] or path.stat().st_size != item["size"]:
            raise ValueError("Payload digest mismatch: " + name)
    identity = load(payload / "identity.json")
    if identity != manifest["identity"]:
        raise ValueError("Payload identity mismatch")
    if identity["inputs"]["target"] != "linux-amd64":
        raise ValueError("Wrong payload target")
    return identity

def switch(current, target):
    temporary = current.with_name("current.next")
    if temporary.exists() or temporary.is_symlink():
        temporary.unlink()
    temporary.symlink_to(target)
    temporary.replace(current)

def recover(management):
    journal = management / "journal.json"
    if not journal.exists():
        return
    entry = load(journal)
    current = management / "current"
    selected = os.readlink(current) if current.is_symlink() else None
    if selected == entry["new"]:
        identity = verify_payload(management / selected)
        if identity["build"] != entry["state"]["build"]:
            raise ValueError("Interrupted transaction identity mismatch")
        write_json(management / "install-state.json", entry["state"])
    elif selected == entry["old"]:
        # Restore only the exact paths recorded before replacing managed entries.
        import base64
        prefix = management.parent.parent
        for name, previous in entry.get("previous", {}).items():
            path = member(prefix, name)
            if previous is None:
                path.unlink(missing_ok=True)
            else:
                path.write_bytes(base64.b64decode(previous["bytes"], validate=True))
                path.chmod(previous["mode"])
    else:
        raise ValueError("Interrupted transaction has an unknown current selector")
    journal.unlink()

def fault(stage):
    if os.environ.get("MOGNITIO_INSTALL_FAULT") == stage:
        raise RuntimeError("Injected interruption at " + stage)

def uninstall(prefix, management, state):
    if not state:
        raise ValueError("Ownership record is missing")
    retained = []
    late = {"lib/mognitio/uninstall.sh", "lib/mognitio/install.py"}
    for name, value in state["files"].items():
        if name in late:
            continue
        path = member(prefix, name)
        if not path.exists() and not path.is_symlink():
            continue
        if matches(path, value):
            path.unlink()
        else:
            retained.append(name)
    if retained:
        print("Retained modified files: " + ", ".join(retained), file=sys.stderr)
        return 2
    for name in late:
        path = member(prefix, name)
        if path.exists() and not matches(path, state["files"][name]):
            print("Retained modified management file: " + name, file=sys.stderr)
            return 2
    for name in late:
        member(prefix, name).unlink(missing_ok=True)
    (management / "install-state.json").unlink()
    (management / "journal.json").unlink(missing_ok=True)
    # Remove only empty directories. Unknown user files are always retained.
    for directory in sorted(management.rglob("*"), key=lambda p: len(p.parts), reverse=True):
        if directory.is_dir() and not directory.is_symlink():
            try:
                directory.rmdir()
            except OSError:
                pass
    print("Mognitio uninstalled; unrelated files were retained.")
    return 0

def run(args):
    prefix = Path(args.prefix).expanduser().absolute()
    if prefix != prefix.resolve() or str(prefix) in ("/", "/usr", "/usr/local", "/opt", "/bin", "/sbin"):
        raise ValueError("Choose a non-symlink user prefix outside system package locations")
    if os.geteuid() == 0:
        raise ValueError("Run the user installer without sudo")
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        raise ValueError("Only Linux amd64 is supported")
    management = prefix / "lib/mognitio"
    bundle = Path(__file__).resolve().parent
    identity = None if args.uninstall else verify_payload(bundle / "payload")
    if identity and args.version and args.version != identity["version"]:
        raise ValueError("The bundle does not contain the requested version")
    if identity:
        version_tuple(identity["version"])
        required = sum(p.stat().st_size for p in (bundle / "payload").rglob("*") if p.is_file())
        existing = prefix
        while not existing.exists():
            existing = existing.parent
        if shutil.disk_usage(existing).free < required * 2 + 1024 * 1024:
            raise ValueError("Insufficient free space")
    for parent in [management, *management.parents]:
        if parent == prefix:
            break
        if parent.is_symlink():
            raise ValueError("Management path contains a symlink")
    management.mkdir(parents=True, exist_ok=True)
    if management.is_symlink():
        raise ValueError("Management directory is a symlink")
    lock_fd = os.open(management / "lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(lock_fd, "a+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ValueError("Another installer operation holds the lock") from error
        recover(management)
        state_file = management / "install-state.json"
        state = load(state_file) if state_file.exists() else None
        if state and (state.get("schema") != 1 or state.get("prefix") != str(prefix)):
            raise ValueError("Ownership record does not match this prefix")
        if args.uninstall:
            return uninstall(prefix, management, state)
        assert identity is not None
        if state and version_tuple(identity["version"]) < version_tuple(state["version"]):
            raise ValueError("Downgrades are not supported")
        if state and identity["version"] == state["version"]:
            if identity["build"] != state["build"]:
                raise ValueError("The same version has different build contents")
            for name, value in state["files"].items():
                if not matches(member(prefix, name), value):
                    raise ValueError("Owned contents changed: " + name)
            print("The same verified version is already installed.")
            return 0
        destinations = ["bin/mgn", "bin/mognitio-lsp", "lib/mognitio/current",
                        "lib/mognitio/uninstall.sh", "lib/mognitio/install.py"]
        for name in destinations:
            target = member(prefix, name)
            if target.exists() or target.is_symlink():
                if not state or name not in state["files"] or not matches(target, state["files"][name]):
                    raise ValueError("Installation path conflict: " + name)
        versions = management / "versions"
        versions.mkdir(exist_ok=True)
        destination = versions / identity["build"]
        if destination.exists():
            if verify_payload(destination) != identity:
                raise ValueError("Immutable payload path conflict")
        else:
            with tempfile.TemporaryDirectory(prefix=".staging-", dir=management) as temp:
                staged = Path(temp) / "payload"
                shutil.copytree(bundle / "payload", staged)
                verify_payload(staged)
                subprocess.run([str(staged / "bin/mgn"), "--version"], check=True, capture_output=True, timeout=10)
                staged.rename(destination)
        import base64
        previous = {}
        for name in destinations:
            if name == "lib/mognitio/current":
                continue
            path = member(prefix, name)
            previous[name] = ({"bytes": base64.b64encode(path.read_bytes()).decode(),
                               "mode": path.stat().st_mode & 0o777} if path.exists() else None)
        owned = dict(state["files"]) if state else {}
        current = management / "current"
        old = os.readlink(current) if current.is_symlink() else None
        target = "versions/" + identity["build"]
        journal = {"phase": "prepared", "old": old, "new": target, "state": None, "previous": previous}
        write_json(management / "journal.json", journal)
        fault("prepared")
        (prefix / "bin").mkdir(exist_ok=True)
        for tool in ["mgn", "mognitio-lsp"]:
            target = prefix / "bin" / tool
            text = "#!/bin/sh\nexec " + shlex.quote(str(management / "current/bin" / tool)) + ' "$@"\n'
            target.write_text(text)
            target.chmod(0o755)
        shutil.copy2(bundle / "install.py", management / "install.py")
        uninstall_script = management / "uninstall.sh"
        uninstall_script.write_text("#!/bin/sh\nexec python3 -I " + shlex.quote(str(management / "install.py")) +
                                   " --prefix " + shlex.quote(str(prefix)) + ' --uninstall "$@"\n')
        uninstall_script.chmod(0o755)
        for path in destination.rglob("*"):
            if path.is_file():
                owned[str(path.relative_to(prefix))] = record(path)
        for name in destinations:
            if name != "lib/mognitio/current":
                owned[name] = record(member(prefix, name))
        target = "versions/" + identity["build"]
        owned["lib/mognitio/current"] = {"kind": "link", "target": target}
        new = {"schema": 1, "prefix": str(prefix), "version": identity["version"],
               "build": identity["build"], "files": owned}
        current = management / "current"
        old = os.readlink(current) if current.is_symlink() else None
        journal["state"] = new
        write_json(management / "journal.json", journal)
        fault("entries")
        switch(current, target)
        journal["phase"] = "switched"
        write_json(management / "journal.json", journal)
        fault("switched")
        write_json(state_file, new)
        journal["phase"] = "cleaned"
        write_json(management / "journal.json", journal)
        fault("cleaned")
        (management / "journal.json").unlink()
        # Retain old generations; live sessions may still need their runtime.
        print("Installed " + identity["version"] + " in " + str(prefix))
        print("Add " + shlex.quote(str(prefix / "bin")) + " to PATH.")
        print("Uninstall: sh " + shlex.quote(str(uninstall_script)))
        return 0

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--prefix", default="~/.local")
    parser.add_argument("--version")
    parser.add_argument("--uninstall", action="store_true")
    try:
        sys.exit(run(parser.parse_args()))
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        print("Mognitio installer: " + str(error), file=sys.stderr)
        sys.exit(2 if isinstance(error, RuntimeError) else 1)
