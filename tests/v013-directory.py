"""Directory contracts through the real host command and standalone native ELF."""
from pathlib import Path
import os
import socket
import stat
import tempfile
from v013_support import Suite,ROOT,IMPORTS,KINDS,OPERATIONS,quoted,error_assert,arms

def empty(cwd):
    assert not list(cwd.iterdir())

def evaluated(cwd):
    assert (cwd/'evaluated').read_bytes()==b'yes'

with tempfile.TemporaryDirectory(prefix='mgn-v013-directory-') as temporary:
    suite=Suite(temporary)
    # Paths are lexical, and validation follows argument evaluation.
    for left,right,expected in [('a','b','a/b'),('a/','b','a/b'),('/','x','/x'),('./a//','../b/','./a//../b/'),('日本','語','日本/語'),('missing','a\\b','missing/a\\b')]:
        suite.pair(f'assert branch on joinPath({quoted(left)},{quoted(right)}){{Result<String,IoError>::Ok(s:String)=>s=={quoted(expected)},Result<String,IoError>::Err=>false}};0',verify=empty)
    for left,right,subject in [('', '/', ''),('a\0','b','a\0'),('a','',''),('a','b\0','b\0'),('a','/b','/b')]:
        suite.pair(error_assert(f'joinPath({quoted(left)},{quoted(right)})','String','JoinPath','InvalidPath',subject)+'0')
    suite.pair('discard joinPath("",{discard writeTextFile("evaluated","yes");"/bad"});0',verify=evaluated)
    suite.pair('discard joinPath("",{discard writeTextFile("evaluated","yes");fail()});0',extra='let fail:Function():String=function():String{panic{"argument panic"}};',verify=evaluated,code=4,err=None)
    # One function travels through a product field, List and parameter.
    extra='type Holder=product{f:Function(String,String):Result<String,IoError>;};let apply:Function(Function(String,String):Result<String,IoError>):Result<String,IoError>=function(f:Function(String,String):Result<String,IoError>):Result<String,IoError>{f("a","b")};'
    suite.pair('let h:Holder=Holder{f:joinPath};let functions:List<Function(String,String):Result<String,IoError>>=List<Function(String,String):Result<String,IoError>>[h->f];let f:Function(String,String):Result<String,IoError>=branch on functions->at(0){Result<Function(String,String):Result<String,IoError>,IndexError>::Ok(value:Function(String,String):Result<String,IoError>)=>value,Result<Function(String,String):Result<String,IoError>,IndexError>::Err=>panic{"index"}};assert branch on apply(f){Result<String,IoError>::Ok(s:String)=>s=="a/b",Result<String,IoError>::Err=>false};0',extra=extra)

    names=['.dot','a','aa','é','é','日','😀','line\r\nname','back\\slash']
    expected=sorted(names+['a-hard','directory','link-directory','link-file','link-missing','pipe','socket'])
    def tree(cwd):
        root=cwd/'tree';root.mkdir()
        for name in reversed(names):(root/name).write_bytes(b'x')
        os.link(root/'a',root/'a-hard')
        (root/'directory').mkdir();(root/'directory/hidden').write_bytes(b'x')
        for name,target in [('link-directory','directory'),('link-file','a'),('link-missing','missing')]:os.symlink(target,root/name)
        os.mkfifo(root/'pipe');sock=socket.socket(socket.AF_UNIX);sock.bind(os.fspath(root/'socket'));sock.close()
        os.symlink('tree',cwd/'root-link')
    kind_expectations={'directory':'Directory','pipe':'Other','socket':'Other',**{name:'Symlink' for name in ['link-directory','link-file','link-missing']}}
    checks=''.join(f'branch when{{entry->name=={quoted(name)}=>{{assert branch on entry->kind{{{arms("DirectoryEntryKind",["File","Directory","Symlink","Other"],kind_expectations.get(name,"File"))}}};}},else=>unit}};' for name in expected)
    body=f'''let expected:List<String>=List<String>[{','.join(map(quoted,expected))}];branch on readDirectory("root-link"){{Result<List<DirectoryEntry>,IoError>::Err=>panic{{"read"}},Result<List<DirectoryEntry>,IoError>::Ok(entries:List<DirectoryEntry>)=>{{assert entries->length()=={len(expected)};var i:Int=0;loop over(entries as entry:DirectoryEntry){{assert branch on expected->at(i){{Result<String,IndexError>::Ok(name:String)=>name==entry->name,Result<String,IndexError>::Err=>false}};{checks}i=i+1;}};}}}};0'''
    for locale in ['C','C.UTF-8']:
        suite.pair(body,tree,env={**os.environ,'LC_ALL':locale})
    for call,result,operation,path,kind in [('readDirectory','List<DirectoryEntry>','ReadDirectory','missing','NotFound'),('readDirectory','List<DirectoryEntry>','ReadDirectory','tree/a','UnsupportedTarget'),('createDirectory','Unit','CreateDirectory','missing/child','NotFound'),('createDirectory','Unit','CreateDirectory','tree/a/child','UnsupportedTarget'),('createDirectory','Unit','CreateDirectory','tree/link-missing','UnsupportedTarget'),('createDirectory','Unit','CreateDirectory','tree/link-missing/','NotFound'),('createDirectory','Unit','CreateDirectory','tree/link-file','UnsupportedTarget'),('readDirectory','List<DirectoryEntry>','ReadDirectory','x'*256,'InvalidPath')]:
        suite.pair(error_assert(f'{call}({quoted(path)})',result,operation,kind,path)+'0',tree)
    def invalid(cwd):
        (cwd/'bad').mkdir();(cwd/'bad/a').write_bytes(b'x')
        fd=os.open(os.fsencode(cwd/'bad')+b'/\xff',os.O_CREAT|os.O_WRONLY,0o600);os.close(fd)
    suite.pair(error_assert('readDirectory("bad")','List<DirectoryEntry>','ReadDirectory','InvalidEncoding','bad')+'0',invalid)
    def denied(cwd):
        (cwd/'blocked').mkdir();(cwd/'blocked/child').mkdir();os.chmod(cwd/'blocked',0)
    def restore(cwd):os.chmod(cwd/'blocked',0o700)
    assert os.geteuid()!=0,'Permission fixtures require a non-root process'
    suite.pair(error_assert('readDirectory("blocked")','List<DirectoryEntry>','ReadDirectory','PermissionDenied','blocked')+'0',denied,restore)
    suite.pair(error_assert('createDirectory("blocked/child")','Unit','CreateDirectory','PermissionDenied','blocked/child')+'0',denied,restore)
    def loop_link(cwd):os.symlink('loop',cwd/'loop')
    suite.pair(error_assert('readDirectory("loop")','List<DirectoryEntry>','ReadDirectory','Other','loop')+'0',loop_link)
    # Existing directory without write permission is still accepted unchanged.
    def readonly(cwd):(cwd/'existing').mkdir(mode=0o500)
    def check_readonly(cwd):
        assert stat.S_IMODE((cwd/'existing').stat().st_mode)==0o500
        os.chmod(cwd/'existing',0o700)
    suite.pair('assert branch on createDirectory("existing"){Result<Unit,IoError>::Ok=>true,Result<Unit,IoError>::Err=>false};0',readonly,check_readonly)
    for mask,mode in [(0o022,0o755),(0o077,0o700)]:
        def verify_mode(cwd,mode=mode):assert stat.S_IMODE((cwd/'new').stat().st_mode)==mode
        suite.pair('discard createDirectory("new");discard createDirectory("new");0',verify=verify_mode,umask=mask)
    # A retained value does not change when subsequent operations mutate the tree.
    suite.pair('let kept:List<DirectoryEntry>=branch on readDirectory("tree"){Result<List<DirectoryEntry>,IoError>::Ok(xs:List<DirectoryEntry>)=>xs,Result<List<DirectoryEntry>,IoError>::Err=>panic{"read"}};discard createDirectory("tree/new");assert kept->length()==16;assert branch on readDirectory("tree"){Result<List<DirectoryEntry>,IoError>::Ok(xs:List<DirectoryEntry>)=>xs->length()==17,Result<List<DirectoryEntry>,IoError>::Err=>false};0',tree)
    # A real listing spanning several 64 KiB getdents buffers.
    many=[f'{i:04d}-'+('long-name-'*6) for i in range(1700)]
    def large(cwd):
        (cwd/'large').mkdir()
        for name in reversed(many):(cwd/'large'/name).touch()
    suite.pair('assert branch on readDirectory("large"){Result<List<DirectoryEntry>,IoError>::Ok(xs:List<DirectoryEntry>)=>xs->length()==1700,Result<List<DirectoryEntry>,IoError>::Err=>false};0',large)
    # Main's ordinary 123 is unrelated to the private test-child status.
    suite.pair('123',code=123)
    print(f'v0.13 directory checks={suite.checks} failures=0')
