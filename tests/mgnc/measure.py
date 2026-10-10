#!/usr/bin/env python3
"""Per-process wall time and wait4 peak RSS; failed samples remain in the record."""
import argparse,hashlib,json,os,signal,statistics,subprocess,tempfile,time
from pathlib import Path
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
    parser=argparse.ArgumentParser();parser.add_argument("--compiler",required=True,type=Path)
    parser.add_argument("--fixtures",required=True,type=Path);parser.add_argument("--evidence",required=True,type=Path)
    parser.add_argument("--cell",action="append");parser.add_argument("--warmups",type=int,default=1)
    parser.add_argument("--repeats",type=int,default=5);args=parser.parse_args()
    manifest=json.loads((args.fixtures/"manifest.json").read_text())
    rows=[row for row in manifest if not args.cell or row["name"] in args.cell]
    evidence=dict(compiler_sha256=digest(args.compiler),fixture_manifest_sha256=digest(args.fixtures/"manifest.json"),
                  kernel=os.uname().release,uid_nonzero=os.getuid()!=0,warmups=args.warmups,repeats=args.repeats,cells=[])
    with tempfile.TemporaryDirectory(prefix="mgnc-measure-") as temporary:
        work=Path(temporary)
        for row in rows:
            path=args.fixtures/(row["name"]+".mgn");assert digest(path)==row["sha256"]
            record=dict(fixture=row,samples=[]);evidence["cells"].append(record)
            for iteration in range(args.warmups+args.repeats):
                output=work/f"{row['name']}-{iteration}";stdout=work/"stdout";stderr=work/"stderr"
                with stdout.open("wb") as out,stderr.open("wb") as err:
                    started=time.monotonic()
                    process=subprocess.Popen([args.compiler.resolve(),"build",path.resolve(),"-o",output],
                                             stdout=out,stderr=err,umask=0o022)
                    timed_out=False
                    while True:
                        pid,status,usage=os.wait4(process.pid,os.WNOHANG)
                        if pid:break
                        if time.monotonic()-started>=120:
                            process.kill();pid,status,usage=os.wait4(process.pid,0);timed_out=True;break
                        time.sleep(.005)
                    elapsed=time.monotonic()-started;process.returncode=os.waitstatus_to_exitcode(status)
                sample=dict(warmup=iteration<args.warmups,wall_seconds=elapsed,peak_rss_bytes=usage.ru_maxrss*1024,
                            exit=process.returncode,timeout=timed_out,stdout_hex=stdout.read_bytes().hex(),stderr_hex=stderr.read_bytes().hex())
                valid=(process.returncode,stdout.read_bytes(),stderr.read_bytes())==(0,b"",b"") and not timed_out
                if valid:
                    sample.update(artifact_sha256=digest(output),artifact_bytes=output.stat().st_size,mode=oct(output.stat().st_mode&0o777))
                    results=[]
                    for count,want in zip(row["argv_counts"],row["expected"]):
                        run=subprocess.run([output]+["x"]*count,capture_output=True,timeout=5)
                        results.append(dict(argv_count=count,exit=run.returncode,stdout_hex=run.stdout.hex(),stderr_hex=run.stderr.hex()))
                        valid=valid and (run.returncode,run.stdout,run.stderr)==(want,b"",b"")
                    sample["runtime"]=results
                sample["correct"]=valid;record["samples"].append(sample)
                args.evidence.write_text(json.dumps(evidence,indent=2)+"\n")
                print(row["name"],iteration,round(elapsed,3),sample["peak_rss_bytes"],"correct",valid,flush=True)
            samples=[sample for sample in record["samples"] if not sample["warmup"]]
            record["median_seconds"]=statistics.median(sample["wall_seconds"] for sample in samples)
            record["max_rss_bytes"]=max(sample["peak_rss_bytes"] for sample in samples)
            record["pass"]=all(sample["correct"] for sample in record["samples"]) and record["median_seconds"]<=30 and record["max_rss_bytes"]<=256*2**20
            args.evidence.write_text(json.dumps(evidence,indent=2)+"\n")
    assert all(row["pass"] for row in evidence["cells"]),"resource profile did not pass"
    print(f"MGNC_MEASUREMENT_OK cells={len(rows)}")
if __name__=="__main__":main()
