#!/usr/bin/env python3
"""Retain the four original v1.1 improvement guarantees in the current compiler."""
import argparse,importlib.util,json
from pathlib import Path
HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location("measure",HERE/"v11-measure.py")
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)

def main():
 p=argparse.ArgumentParser()
 for name in ("baseline","candidate","evidence"):p.add_argument("--"+name,type=Path,required=True)
 args=p.parse_args();args.evidence.mkdir(parents=True,exist_ok=False)
 roots={side:getattr(args,side).resolve() for side in ("baseline","candidate")}
 identities={side:json.loads((root/"identity.json").read_text()) for side,root in roots.items()}
 assert identities["baseline"]["source_files"]==identities["candidate"]["source_files"]
 for side,identity in identities.items():
  for name,details in identity["images"].items():assert m.digest(roots[side]/name)==details["sha256"]
 environment=m.environments.capture(args.evidence);eid=environment["environment_id"]
 record={"identities":identities,"environment":environment,"tools":{name:m.digest(HERE/name) for name in ("v120-improvements.py","v11-measure.py","v11-measure-profile.py","v11-measure-environment.py","v11-workloads.py")},"cells":[]}
 for cell in (c for c in m.profile.matrix() if c["improvement"]):
  folder=args.evidence/cell["id"];folder.mkdir()
  (folder/"input").write_text(cell["text"]);(folder/"queries").write_text("\n".join(cell.get("queries",[])))
  entry={"cell":cell,"batches":[]};record["cells"].append(entry)
  for batch in range(3):
   rows={"samples":{"baseline":[],"candidate":[]},"warmups":{},"environment_id":eid}
   entry["batches"].append(rows)
   for sample in range(-1,5):
    for side in (("baseline","candidate") if sample%2 else ("candidate","baseline")):
     m.environments.require_current(args.evidence,eid)
     image=roots[side]/("workloads" if cell["family"]=="workload" else cell["mode"])
     observation=m.observe(image,cell,folder,f"{batch}-{side}-{sample}")
     m.environments.require_current(args.evidence,eid)
     if sample<0:rows["warmups"][side]=observation
     else:rows["samples"][side].append(observation)
   decision=m.profile.decide(cell,**rows["samples"]);rows["decision"]=decision
   for old in entry["batches"]:
    for observation in [old["warmups"]["candidate"],*old["samples"]["candidate"]]:
     if not observation["verified"] or observation["outcome"]!="completed" or observation["elapsed_seconds"]>cell["timeout"] or observation["peak_rss_kib"]>32768:
      decision["status"]="fail";decision["reasons"].append("retained candidate failure")
   entry["decision"]=decision
   m.save(args.evidence/"results.json",record)
   if not any("noise" in reason for reason in decision["reasons"]):break
  print(cell["id"],entry["decision"]["status"],flush=True)
 record["status"]="pass" if all(row["decision"]["status"]=="pass" for row in record["cells"]) else "not-passed"
 m.save(args.evidence/"results.json",record)
 return 0 if record["status"]=="pass" else 1
if __name__=="__main__":raise SystemExit(main())
