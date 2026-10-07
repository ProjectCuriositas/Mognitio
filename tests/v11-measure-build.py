"""Build immutable comparison images and record their compiler/source identities."""
from pathlib import Path
import argparse
import hashlib
import json
import shutil
import subprocess


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--compiler", type=Path, required=True)
    parser.add_argument("--levi", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    compiler, levi, output = (p.resolve() for p in (args.compiler, args.levi, args.output))
    output.mkdir(parents=True, exist_ok=False)
    sources = output / "sources"
    sources.mkdir()
    workload = compiler / "examples/compiler-workloads"
    shutil.copytree(workload, sources / "workloads")
    project = sources / "levi"
    (project / "src/Core").mkdir(parents=True)
    (project / "mognitio.toml").write_text('[project]\nname="levi"\nroot_namespace="Levi"\n')
    for name in ("model.mgn", "text.mgn"):
        shutil.copy2(levi / "src/Core" / name, project / "src/Core" / name)
    manifests = {"workloads": sources / "workloads/mognitio.toml"}
    entries = {}
    for kind in ("scan-control", "scan", "join-control", "join", "stress"):
        repeats = 32 if kind == "stress" else 4
        setup = "let parts:List<String>=text->scalars();" if kind.startswith("join") else ""
        operation = {"scan-control": "assert text->length()==expected;",
                     "scan": "assert validTitle(text);", "stress": "assert validTitle(text);",
                     "join-control": "assert parts->length()==expected;",
                     "join": "assert assembleFragments(parts)==text;"}[kind]
        source = r"""namespace Levi;
use Std\Io\{readTextFile,IoError};
use Levi\Core\{validTitle,assembleFragments};
let main:Function(List<String>):Int=function(args:List<String>):Int{
    let text:String=branch on readTextFile("input"){Result<String,IoError>::Ok(value:String)=>value,Result<String,IoError>::Err=>panic{"input"}};
    let expected:Int=text->length();
""" + setup + f"var n:Int=0;loop while(n<{repeats}){{{operation}n=n+1;}};0\n}};\n"
        target = sources / ("levi-" + kind)
        shutil.copytree(project, target)
        (target / "src/levi.mgn").write_text(source)
        entries[kind] = hashlib.sha256(source.encode()).hexdigest()
        manifests[kind] = target / "mognitio.toml"
    counts_source = output / "count-objects.lisp"
    counts_source.write_text(r"""(require :asdf)
(asdf:load-asd (truename "mognitio.asd"))
(asdf:load-system "mognitio")
(let* ((manifest (first (uiop:command-line-arguments)))
       (checked (mognitio.driver::checked-project (mognitio.project::load-project manifest)))
       (ir (mognitio.ir:lower-program checked))
       (mognitio.native.runtime::*runtime-module* ir))
  (format t "~D ~D~%" (length (mognitio.ir:module-literal-pool ir))
          (length (mognitio.native.runtime::static-objects))))
""")
    images = {}
    for kind, manifest in manifests.items():
        image = output / kind
        command = [str(compiler / "bin/mgn"), "build", str(manifest), "-o", str(image)]
        built = subprocess.run(command, cwd=compiler, capture_output=True, timeout=240)
        (output / (kind + ".build.stdout")).write_bytes(built.stdout)
        (output / (kind + ".build.stderr")).write_bytes(built.stderr)
        assert built.returncode == 0 and built.stdout == built.stderr == b"", built
        counted = subprocess.check_output(["sbcl", "--noinform", "--script", str(counts_source), str(manifest)],
                                          cwd=compiler, timeout=120, text=True).split()
        images[kind] = dict(sha256=digest(image), literal_count=int(counted[-2]),
                            static_object_count=int(counted[-1]), build_command=command)
    def revision(root):
        return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    record = dict(compiler_commit=revision(compiler), compiler_version=(compiler / "VERSION").read_text().strip(),
                  consumer_commit=revision(levi), images=images, entries=entries,
                  source_files={p.relative_to(sources).as_posix(): digest(p)
                                for p in sorted(sources.rglob("*")) if p.is_file()})
    (output / "identity.json").write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps(dict(compiler=record["compiler_commit"], images=len(images))))


if __name__ == "__main__":
    main()
