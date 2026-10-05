"""Run in a dedicated delegated scope; the oom case must be killed by its cgroup."""
import argparse,os,subprocess,sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent.parent/"tools/lsp"))
from budget import MemoryBudget,LIMIT
parser=argparse.ArgumentParser();parser.add_argument("--oom",action="store_true");args=parser.parse_args()
before=Path("/proc/self/cgroup").read_text()
budget=MemoryBudget()
if not budget.group:
 print("SKIP: no exclusive delegated memory scope",flush=True);raise SystemExit(77)
group=budget.group
assert int((group/"memory.max").read_text())==LIMIT
assert (group/"memory.oom.group").read_text().strip()=="1"
print("HARD LIMIT "+str(LIMIT),flush=True)
if args.oom:
 # A descendant allocation must terminate the entire owned group, including this coordinator.
 subprocess.run([sys.executable,"-c","value=bytearray(1200*1024*1024); print(len(value))"],check=True)
 raise AssertionError("Allocation exceeded the enforced session budget")
budget.close()
assert not group.exists()
assert Path("/proc/self/cgroup").read_text()==before
print("PASS delegated setup, exact limit, group ownership, controller restoration and cleanup")
