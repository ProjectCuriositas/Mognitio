#!/bin/sh
set -eu
command -v flock >/dev/null 2>&1 || { echo 'flock is required' >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo 'Python 3 is required' >&2; exit 1; }
bundle=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P) || exit 1
exec python3 -I "$bundle/install.py" "$@"
