import os,subprocess,json,tempfile
from pathlib import Path
import argparse
parser=argparse.ArgumentParser()
parser.add_argument("--bundle",type=Path,required=True)
bundle=parser.parse_args().bundle.resolve()
def run(prefix,*args,env=None,code=0):
 p=subprocess.run(["sh",str(bundle/"install.sh"),"--prefix",str(prefix),*args],env=dict(os.environ,**(env or {})),capture_output=True,text=True)
 assert p.returncode==code,(p.returncode,code,p.stdout,p.stderr)
 return p
with tempfile.TemporaryDirectory(prefix="installation test ") as temp:
 root=Path(temp)
 prefix=root/"prefix 日本語 with spaces"
 run(prefix)
 for tool in ("mgn","mognitio-lsp"):
  p=subprocess.run([str(prefix/"bin"/tool),"--version"],capture_output=True,text=True)
  assert p.returncode==0 and "0.15.0" in p.stdout,p
 run(prefix)
 (prefix/"keep.txt").write_text("user data")
 run(prefix,"--uninstall")
 assert (prefix/"keep.txt").read_text()=="user data"
 assert not (prefix/"bin/mgn").exists()
 for phase in ("prepared","entries","switched","cleaned"):
  prefix=root/("fault-"+phase)
  run(prefix,env={"MOGNITIO_INSTALL_FAULT":phase},code=2)
  run(prefix)
  assert subprocess.run([str(prefix/"bin/mgn"),"--version"],capture_output=True).returncode==0
  run(prefix,"--uninstall")
 prefix=root/"modified"
 run(prefix)
 (prefix/"bin/mgn").write_text("modified")
 run(prefix,"--uninstall",code=2)
 assert (prefix/"bin/mgn").read_text()=="modified"
 prefix=root/"conflict";(prefix/"bin").mkdir(parents=True)
 (prefix/"bin/mgn").write_text("existing")
 run(prefix,code=1)
 assert (prefix/"bin/mgn").read_text()=="existing"
 prefix=root/"link";prefix.symlink_to(root/"conflict")
 run(prefix,code=1)
 print("PASS install, repeat, executable runtime, spaces, four transaction recovery points, uninstall ownership, conflict, symlink")
