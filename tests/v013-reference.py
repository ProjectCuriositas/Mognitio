"""Distributed breadth-first converter: outputs, partial effects and test usage."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
from v013_support import Suite,ROOT

def prepare(cwd):
    root=cwd/'input';root.mkdir();(root/'a.txt').write_bytes(b'hello')
    (root/'empty').mkdir();(root/'nested').mkdir();(root/'nested/b.txt').write_bytes(b'world')
    (root/'link').symlink_to('nested');os.mkfifo(root/'pipe')

def verify(cwd):
    assert (cwd/'output/a.txt').read_bytes()==b'# Converted\nhello'
    assert (cwd/'output/nested/b.txt').read_bytes()==b'# Converted\nworld'
    assert not list((cwd/'output/empty').iterdir())
    assert sorted(p.name for p in (cwd/'output').iterdir())==['a.txt','empty','nested']
    assert (cwd/'input/a.txt').read_bytes()==b'hello' and (cwd/'input/nested/b.txt').read_bytes()==b'world'

with tempfile.TemporaryDirectory(prefix='mgn-v013-reference-') as temporary:
    suite=Suite(temporary);base=Path(temporary);project=base/'project'
    shutil.copytree(ROOT/'examples/directory-converter',project)
    manifest=project/'mognitio.toml';image=base/'converter'
    suite.command([ROOT/'bin/mgn','build',manifest,'-o',image])
    assert not (project/'input').exists() and not (project/'output').exists()
    for backend in ('host','native'):
        for initial in ('new','empty'):
            cwd=base/f'{backend}-{initial}';cwd.mkdir();prepare(cwd)
            if initial=='empty':(cwd/'output').mkdir()
            command=[ROOT/'bin/mgn','run',manifest,'--'] if backend=='host' else [image]
            suite.command([*command,'input','output'],cwd=cwd);verify(cwd)
            suite.command([*command,'input','output'],cwd=cwd);verify(cwd)
        for fault in ('args','root','parent','decode','read','create','write','enumerate'):
            cwd=base/f'{backend}-{fault}';cwd.mkdir();prepare(cwd)
            args=['input','output'];code=1;err=b'conversion failed\n'
            if fault=='args':args=[];code=2;err=b'usage: convert-tree INPUT OUTPUT\n'
            elif fault=='root':args[0]='absent'
            elif fault=='parent':args[1]='missing/output'
            elif fault=='decode':(cwd/'input/nested/b.txt').write_bytes(b'\xff')
            elif fault=='read':os.chmod(cwd/'input/nested/b.txt',0)
            elif fault=='enumerate':
                fd=os.open(os.fsencode(cwd/'input/nested')+b'/\xff',os.O_CREAT|os.O_WRONLY,0o600);os.close(fd)
            else:
                (cwd/'output').mkdir()
                if fault=='create':(cwd/'output/nested').write_bytes(b'collision')
                elif fault=='write':(cwd/'output/nested').mkdir();(cwd/'output/nested/b.txt').mkdir()
            suite.command([*command,*args],code=code,err=err,cwd=cwd)
            if fault in ('args','root','parent'):assert not (cwd/'output').exists()
            else:assert (cwd/'output/a.txt').read_bytes()==b'# Converted\nhello'
            if fault=='read':os.chmod(cwd/'input/nested/b.txt',0o600)
    # Tests call the same converter in its defining module and retain side effects.
    source_path=project/'src/app.mgn'
    source_path.write_text(source_path.read_text().replace('namespace App;','namespace App;\nuse Std\\Io\\{IoErrorKind};',1))
    with (project/'src/app.mgn').open('a') as source:
        source.write(r'''
@test let convert:Function():Unit=function():Unit{
  assert branch on convertTree("input","output"){Result<Unit,IoError>::Ok=>true,Result<Unit,IoError>::Err=>false};
  assert branch on readTextFile("output/a.txt"){Result<String,IoError>::Ok(s:String)=>s=="# Converted\nhello",Result<String,IoError>::Err=>false};
  assert branch on readTextFile("output/nested/b.txt"){Result<String,IoError>::Ok(s:String)=>s=="# Converted\nworld",Result<String,IoError>::Err=>false};
  assert branch on readDirectory("output/empty"){Result<List<DirectoryEntry>,IoError>::Ok(xs:List<DirectoryEntry>)=>xs->length()==0,Result<List<DirectoryEntry>,IoError>::Err=>false};
};
@test let observe:Function():Unit=function():Unit{
  let names:List<String>=List<String>["a.txt","empty","nested"];
  branch on readDirectory("output"){Result<List<DirectoryEntry>,IoError>::Err=>panic{"read"},Result<List<DirectoryEntry>,IoError>::Ok(xs:List<DirectoryEntry>)=>{
    assert xs->length()==3;var i:Int=0;loop over(xs as entry:DirectoryEntry){
      assert branch on names->at(i){Result<String,IndexError>::Ok(name:String)=>name==entry->name,Result<String,IndexError>::Err=>false};
      assert branch on entry->kind{DirectoryEntryKind::File=>i==0,DirectoryEntryKind::Directory=>i>0,DirectoryEntryKind::Symlink=>false,DirectoryEntryKind::Other=>false};i=i+1;
    };
  }};
};
@test let failures:Function():Unit=function():Unit{
  assert branch on convertTree("bad","bad-output"){Result<Unit,IoError>::Ok=>false,Result<Unit,IoError>::Err(e:IoError)=>branch on e->kind{
    IoErrorKind::InvalidEncoding=>true,IoErrorKind::InvalidPath=>false,IoErrorKind::NotFound=>false,IoErrorKind::PermissionDenied=>false,IoErrorKind::UnsupportedTarget=>false,IoErrorKind::BrokenPipe=>false,IoErrorKind::ResourceExhausted=>false,IoErrorKind::Other=>false}};
  assert branch on convertTree("input","collision"){Result<Unit,IoError>::Ok=>false,Result<Unit,IoError>::Err(e:IoError)=>branch on e->kind{
    IoErrorKind::InvalidEncoding=>false,IoErrorKind::InvalidPath=>false,IoErrorKind::NotFound=>false,IoErrorKind::PermissionDenied=>false,IoErrorKind::UnsupportedTarget=>true,IoErrorKind::BrokenPipe=>false,IoErrorKind::ResourceExhausted=>false,IoErrorKind::Other=>false}};
};
''')
    prepare(project)
    (project/'bad').mkdir();fd=os.open(os.fsencode(project/'bad')+b'/\xff',os.O_CREAT|os.O_WRONLY,0o600);os.close(fd)
    (project/'collision').write_bytes(b'file')
    result=subprocess.run([ROOT/'bin/mgn','test',manifest],capture_output=True,timeout=45,cwd=project)
    assert result.returncode==0 and result.stderr==b'' and b'total=3 passed=3' in result.stdout,(result.returncode,result.stdout,result.stderr)
    suite.checks+=1;verify(project)
    shutil.rmtree(project)
    cwd=base/'standalone';cwd.mkdir();prepare(cwd)
    suite.command([image,'input','output'],cwd=cwd,env={'PATH':'/not-present'});verify(cwd)
    print(f'v0.13 reference checks={suite.checks} failures=0')
