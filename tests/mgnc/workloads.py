#!/usr/bin/env python3
"""Frozen dynamic branch and summation programs with independent argv oracles."""
import argparse,hashlib,json,stat,subprocess,tempfile
from pathlib import Path
CHOOSE="""namespace App;
let choose: Function(Int): Int = function(count: Int): Int {
    branch when { count == 0 => 7, else => 11, }
};
let main: Function(List<String>): Int = function(args: List<String>): Int {
    choose(args->length())
};
"""
TOTAL="""namespace App;
let total: Function(Int): Int = function(limit: Int): Int {
    var index: Int = 0;
    var accumulated: Int = 0;
    loop while (index < limit) {
        index = index + 1;
        accumulated = accumulated + index;
    };
    accumulated
};
let main: Function(List<String>): Int = function(args: List<String>): Int {
    total(args->length())
};
"""
def fixtures():
    return [("dynamic-branch",CHOOSE,11,b""),("dynamic-total",TOTAL,6,b""),
            ("grouped-branch",CHOOSE.replace("choose(args->length())","(choose)((args)->length())"),11,b"")]
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
    parser=argparse.ArgumentParser();parser.add_argument("--compiler",required=True,type=Path)
    parser.add_argument("--seed",required=True,type=Path);parser.add_argument("--evidence",required=True,type=Path);args=parser.parse_args()
    records=[]
    with tempfile.TemporaryDirectory(prefix="mgnc-workloads-") as temporary:
        root=Path(temporary)
        for name,source,_,_ in fixtures():
            path=root/(name+".mgn");path.write_text(source);image=root/name
            result=subprocess.run([args.compiler.resolve(),"build",path,"-o",image],capture_output=True,timeout=120)
            assert (result.returncode,result.stdout,result.stderr)==(0,b"",b""),result
            identity=digest(image)
            project=root/(name+"-project");(project/"src").mkdir(parents=True)
            (project/"mognitio.toml").write_text('[project]\nname="app"\nroot_namespace="App"\n')
            (project/"src/app.mgn").write_text(source);old=root/(name+"-old")
            result=subprocess.run([args.seed.resolve(),"build",project/"mognitio.toml","-o",old],capture_output=True,timeout=120)
            assert (result.returncode,result.stdout,result.stderr)==(0,b"",b""),result
            for argv in [[],["x"],["x","y","z"],[""],["a b"],["日本語"],["--"],["","日本語","--"]]:
                want=len(argv)*(len(argv)+1)//2 if name=="dynamic-total" else 7 if not argv else 11
                for executable in [image,old]:
                    result=subprocess.run([executable,*argv],capture_output=True,timeout=3)
                    assert (result.returncode,result.stdout,result.stderr)==(want,b"",b""),(name,argv,result)
                assert digest(image)==identity
                records.append(dict(fixture=name,source_sha256=digest(path),artifact_sha256=identity,
                                    mode=oct(stat.S_IMODE(image.stat().st_mode)),argv=argv,exit=want,
                                    stdout_hex="",stderr_hex="",seed_equal=True))
    args.evidence.write_text(json.dumps(dict(compiler_sha256=digest(args.compiler),records=records),indent=2)+"\n")
    print(f"MGNC_WORKLOADS_OK observations={len(records)} differential=True")
if __name__=="__main__":main()
