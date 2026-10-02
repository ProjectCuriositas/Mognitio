"""Static API boundaries, module initialization and ordinary result composition."""
from pathlib import Path
import tempfile
from v013_support import Suite,ROOT,IMPORTS,OPERATIONS,error_assert,arms

with tempfile.TemporaryDirectory(prefix='mgn-v013-integration-') as temporary:
    suite=Suite(temporary)
    old=','.join('IoOperation::'+name+'=>unit' for name in OPERATIONS[:5])
    negative=[
        ('discard readDirectory(".");0','', ''),
        ('0',r'use Std\Io\{missing};',''),
        ('0',IMPORTS,'let readDirectory:Int=1;'),
        ('let e:DirectoryEntry=DirectoryEntry{name:"a",kind:DirectoryEntryKind::File};discard joinPath(e,"a");0',IMPORTS,''),
        ('let op:IoOperation=IoOperation::ReadDirectory;branch on op{'+old+'};0',IMPORTS,''),
        ('let f:Function(String):Result<List<String>,IoError>=readDirectory;0',IMPORTS,''),
    ]
    for body,imports,extra in negative:
        project,manifest=suite.project(body,imports=imports,extra=extra)
        suite.command([ROOT/'bin/mgn','run',manifest],code=1,err=None)
        suite.command([ROOT/'bin/mgn','build',manifest,'-o',project/'app'],code=1,err=None)
        assert not (project/'app').exists()
    # The full operation match is exhaustive, and Err is an ordinary value.
    suite.pair('let op:IoOperation=IoOperation::ReadDirectory;assert branch on op{'+arms('IoOperation',OPERATIONS,'ReadDirectory')+'};discard readDirectory("absent");0')
    extra='let helper:Function(String):Result<String,IoError>=function(path:String):Result<String,IoError>{let xs:List<DirectoryEntry>=try readDirectory(path);try createDirectory("created");joinPath("base","child")};'
    suite.pair(error_assert('helper("absent")','String','ReadDirectory','NotFound','absent')+'0',extra=extra)
    # Initializers call APIs at execution, and the user re-export edge retains order.
    project,manifest=suite.project('discard readDirectory(".");0')
    (project/'src/app.mgn').write_text('namespace App;use App\\Alias\\{make};let init:Unit={discard make("created");unit};let main:Function(List<String>):Int=function(args:List<String>):Int{0};')
    (project/'src/Alias').mkdir()
    (project/'src/Alias/alias.mgn').write_text('namespace App\\Alias;use Std\\Io\\{createDirectory,IoError,writeTextFile};let init:Unit={discard writeTextFile("ordered","before");unit};public let make:Function(String):Result<Unit,IoError>=createDirectory;')
    image=project/'app';suite.command([ROOT/'bin/mgn','build',manifest,'-o',image],cwd=project)
    assert not (project/'created').exists() and not (project/'ordered').exists()
    for backend in ('host','native'):
        cwd=project/backend;cwd.mkdir()
        suite.command([ROOT/'bin/mgn','run',manifest] if backend=='host' else [image],cwd=cwd)
        assert (cwd/'created').is_dir() and (cwd/'ordered').read_bytes()==b'before'
    # A successful create is not rolled back when the later body panics.
    def retained(cwd):assert (cwd/'created').is_dir()
    suite.pair('discard createDirectory("created");panic{"later"}',code=4,err=None,verify=retained)
    # An accepted Err can be explicitly asserted; tests share external state.
    source='namespace App;'+IMPORTS+'@test let a:Function():Unit=function():Unit{discard createDirectory("shared");unit};@test let b:Function():Unit=function():Unit{assert branch on readDirectory("shared"){Result<List<DirectoryEntry>,IoError>::Ok(xs:List<DirectoryEntry>)=>xs->length()==0,Result<List<DirectoryEntry>,IoError>::Err=>false};'+error_assert('readDirectory("missing")','List<DirectoryEntry>','ReadDirectory','NotFound','missing')+'unit};'
    project,manifest=suite.project('',source=source)
    import subprocess
    p=subprocess.run([ROOT/'bin/mgn','test',manifest],capture_output=True,timeout=45,cwd=project)
    assert p.returncode==0 and not p.stderr and b'total=2 passed=2' in p.stdout,(p.returncode,p.stdout,p.stderr)
    assert (project/'shared').is_dir();suite.checks+=1
    print(f'v0.13 integration checks={suite.checks} failures=0')
