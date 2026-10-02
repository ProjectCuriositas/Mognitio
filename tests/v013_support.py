"""Independent public observations shared by the directory CLI suites."""
from pathlib import Path
import os
import subprocess

ROOT = Path(__file__).resolve().parents[1]
IMPORTS = r"use Std\Io\{joinPath,readDirectory,createDirectory,DirectoryEntry,DirectoryEntryKind,IoError,IoErrorKind,IoOperation,readTextFile,writeTextFile,writeStdout,writeStderr};"
KINDS = "InvalidPath InvalidEncoding NotFound PermissionDenied UnsupportedTarget BrokenPipe ResourceExhausted Other".split()
OPERATIONS = "ReadTextFile WriteTextFile ReadStdin WriteStdout WriteStderr JoinPath ReadDirectory CreateDirectory".split()

def quoted(text):
    return '"'+text.replace('\\','\\\\').replace('"','\\"').replace('\0','\\0').replace('\n','\\n').replace('\r','\\r').replace('\t','\\t')+'"'

def arms(type_name, names, expected):
    return ','.join(f'{type_name}::{name}=>'+('true' if name==expected else 'false') for name in names)

def error_assert(call, success, operation, kind, subject):
    return ('assert branch on '+call+'{Result<'+success+',IoError>::Ok=>false,Result<'+success+',IoError>::Err(e:IoError)=>{'
      +'assert e->subject=='+quoted(subject)+';assert branch on e->operation{'+arms('IoOperation',OPERATIONS,operation)+'};'
      +'branch on e->kind{'+arms('IoErrorKind',KINDS,kind)+'}}};')

class Suite:
    def __init__(self, base):
        self.base=Path(base); self.checks=0; self.serial=0
    def command(self, args, code=0, out=b'', err=b'', **kwargs):
        p=subprocess.run([os.fspath(a) for a in args],capture_output=True,timeout=45,**kwargs)
        assert p.returncode==code and p.stdout==out and (err is None or p.stderr==err),(args,p.returncode,p.stdout,p.stderr)
        self.checks+=1
        return p
    def project(self, body, extra='', imports=IMPORTS, source=None):
        self.serial+=1; project=self.base/f'project-{self.serial}';(project/'src').mkdir(parents=True)
        manifest=project/'mognitio.toml';manifest.write_text('[project]\nname="app"\nroot_namespace="App"\n')
        (project/'src/app.mgn').write_text(source or f'namespace App;{imports}{extra}let main:Function(List<String>):Int=function(args:List<String>):Int{{{body}}};\n',encoding='utf-8')
        return project,manifest
    def pair(self, body, prepare=lambda cwd:None, verify=lambda cwd:None, extra='', code=0, out=b'', err=b'', env=None, umask=-1):
        project,manifest=self.project(body,extra)
        image=project/'app'; self.command([ROOT/'bin/mgn','build',manifest,'-o',image])
        for backend in ('host','native'):
            cwd=project/backend;cwd.mkdir();prepare(cwd)
            args=[ROOT/'bin/mgn','run',manifest] if backend=='host' else [image]
            self.command(args,code,out,err,cwd=cwd,env=env,umask=umask)
            verify(cwd)
        return project,manifest,image
