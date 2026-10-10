"""Validate coverage references without treating the manifest as execution evidence."""
import json
from pathlib import Path
root=Path(__file__).resolve().parents[1]
data=json.loads((root/"verification/v1.2.0-conformance.json").read_text())
expected={f"C120-{group}{i:02}" for group,count in {"T":11,"I":8,"V":5,"Y":6,"B":5,"N":8,"P":8,"M":3,"E":10,"A":4,"K":4,"G":3}.items() for i in range(1,count+1)}
assert len(data["cases"])==75 and {r["id"] for r in data["cases"]}==expected
assert sum(row["gate"]=="1.2.0" for row in data["cases"])==72
for row in data["cases"]:
    if row["gate"]=="2.0-alpha":
        assert row["disposition"]=="future" and row["evidence"]==[]
    else:
        assert row["evidence"]
        for path in row["evidence"]:assert (root/path).is_file(),(row["id"],path)
    if row["disposition"]=="structural-na":
        assert row["id"]=="C120-E06" and (root/row["basis"]).is_file()
print("CONFORMANCE_MANIFEST_OK current=72 future=3")
