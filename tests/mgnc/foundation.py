#!/usr/bin/env python3
"""Build the foundation with an explicit seed; check persistent table boundaries."""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--seed", required=True, type=Path)
    args = parser.parse_args()
    seed = args.seed.resolve()
    with tempfile.TemporaryDirectory(prefix="mgnc-foundation-") as temporary:
        work = Path(temporary)
        project = work / "project"
        shutil.copytree(ROOT / "compiler/mgnc", project)
        (project / "src/mgnc.mgn").write_text(r"""namespace Mgnc;
use Mgnc\Data\{Paged, empty, push, item, lookup, Diagnostic, number};
let main: Function(List<String>): Int = function(args: List<String>): Int {
    var table: Paged<Int> = empty<Int>();
    var index: Int = 0;
    loop while (index < 1000) {
        table = push<Int>(table, index * 3);
        index = index + 1;
    };
    let snapshot: Paged<Int> = table;
    table = push<Int>(table, 7777);
    assert snapshot->count == 1000 && table->count == 1001;
    index = 0;
    loop while (index < 1000) {
        branch on lookup<Int>(snapshot, index) {
            Result<Int, Diagnostic>::Ok(value: Int) => { assert value == index * 3; },
            Result<Int, Diagnostic>::Err(error: Diagnostic) => { assert false; },
        };
        index = index + 1;
    };
    loop over (List<Int>[-1, 1000, 1001] as invalid: Int) {
        branch on item<Int>(snapshot, invalid) {
            Result<Int, IndexError>::Ok(value: Int) => { assert false; },
            Result<Int, IndexError>::Err(error: IndexError) => unit,
        };
    };
    assert number(0) == "0" && number(9223372036854775807) == "9223372036854775807";
    0
};
""")
        image = work / "foundation-test"
        built = subprocess.run([seed, "build", project / "mognitio.toml", "-o", image],
                               capture_output=True, timeout=120)
        assert (built.returncode, built.stdout, built.stderr) == (0, b"", b""), built.stderr
        ran = subprocess.run([image], capture_output=True, timeout=30)
        assert (ran.returncode, ran.stdout, ran.stderr) == (0, b"", b""), ran.stderr
    print("MGNC_FOUNDATION_OK elements=1000 snapshot=True bounds=3")
if __name__ == "__main__":
    main()
