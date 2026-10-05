import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from payload import payload_identity
try:
    payload_identity(Path(__file__).resolve().parent.parent)
except Exception as error:
    print("mgn: inconsistent toolchain: " + str(error), file=sys.stderr)
    sys.exit(3)
