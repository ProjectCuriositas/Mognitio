"""Public CLI, standalone, source migration, and old/new consumer-text evidence."""
from pathlib import Path
import shutil
import subprocess
import tempfile
from v013_support import Suite, ROOT, IMPORTS, quoted, arms

PHASES = ['Input', 'Target', 'Body', 'Cleanup']
imports = IMPORTS + r'use Std\Io\{IoErrorPhase};'
escape = ('let encode:Function(String):String=function(s:String):String{branch when{'
          's=="&"=>"&amp;",s=="<"=>"&lt;",s==">"=>"&gt;",s=="\\\""=>"&quot;",else=>s}};')
old = ('let old:Function(String):String=function(s:String):String{var out:String="";var i:Int=0;'
       'loop while(i<s->length()){let scalar:String=branch on s->slice(i,i+1){'
       'Result<String,SliceError>::Ok(value:String)=>value,Result<String,SliceError>::Err=>panic{"bounds"}};'
       'out=out+encode(scalar);i=i+1;};out};')
new = ('let modern:Function(String):String=function(s:String):String{var parts:List<String>=List<String>[];'
       'loop over(s->scalars() as scalar:String){parts=parts->append(encode(scalar));};parts->join("")};')

with tempfile.TemporaryDirectory(prefix='mgn-v014-') as temporary:
    suite = Suite(temporary)
    checks = []
    for n in (64, 128, 256):
        for sample in ('plain', '<&>"', '日😀e\u0301\0\r\n\ufeff'):
            text = (sample * (n // len(sample) + 1))[:n]
            expected = ''.join({'&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;'}.get(c, c) for c in text)
            checks.append(f'assert old({quoted(text)})==modern({quoted(text)});assert modern({quoted(text)})=={quoted(expected)};')
    project, manifest = suite.project(''.join(checks) + '0', extra=escape+old+new, imports=imports)
    image = project/'app'
    suite.command([ROOT/'bin/mgn', 'run', manifest])
    suite.command([ROOT/'bin/mgn', 'build', manifest, '-o', image])
    # Execute a copied artifact outside the source/manifest/compiler tree.
    standalone = Path(temporary)/'standalone'; standalone.mkdir()
    copied = standalone/'app'; shutil.copy2(image, copied)
    suite.command([copied], cwd=standalone, env={'PATH':'/usr/bin:/bin', 'LANG':'C'})
    # Evaluation order is visible even for an empty receiver; no fold may erase it.
    body = ('let left:Function():List<String>=function():List<String>{discard writeStdout("L");List<String>[]};'
            'let right:Function():String=function():String{discard writeStdout("R");"|"};'
            'discard left()->join(right());0')
    suite.pair(body, out=b'LR')
    # Receiver noncompletion prevents the separator; separator noncompletion
    # preserves earlier receiver effects and prevents any helper result.
    for receiver_panics in (True, False):
        left = 'panic{"left"}' if receiver_panics else 'discard writeStdout("L");List<String>[]'
        right = 'discard writeStdout("R");"|"' if receiver_panics else 'panic{"right"}'
        body = ('let left:Function():List<String>=function():List<String>{'+left+'};'
                'let right:Function():String=function():String{'+right+'};'
                'discard left()->join(right());99')
        suite.pair(body, code=4, out=b'' if receiver_panics else b'L',
                   err=b'panic: left\n' if receiver_panics else b'panic: right\n')
    # The standard phase is an ordinary first-class nominal value in aliases and captures.
    extra = ('alias Phase=IoErrorPhase;let identity:Function(Phase):Function():Phase='
             'function(p:Phase):Function():Phase{function():Phase{p}};')
    body = 'let values:List<Phase>=List<Phase>[identity(Phase::Body)()];loop over(values as p:Phase){assert branch on p{'+arms('Phase',PHASES,'Body')+'};};0'
    project2, manifest2 = suite.project(body, extra=extra, imports=imports)
    suite.command([ROOT/'bin/mgn','run',manifest2]); suite.command([ROOT/'bin/mgn','build',manifest2,'-o',project2/'app'])
    suite.command([project2/'app'])
    bad, bad_manifest = suite.project('discard IoError{operation:IoOperation::ReadStdin,kind:IoErrorKind::Other,subject:"stdin",phase:Other::Body};0',extra='type Other=sum{Body;};',imports=imports)
    for command in ('run','build'):
        suite.command([ROOT/'bin/mgn',command,bad_manifest] + (['-o',bad/'app'] if command == 'build' else []),code=1,err=None)
    # Built-in tests execute the same method/capture/GC and phase APIs.
    source = ('namespace App;'+imports+escape+old+new+
              '@test let text:Function():Unit=function():Unit{'+''.join(checks)+'unit};'
              '@test let phase:Function():Unit=function():Unit{assert branch on readDirectory("missing"){'
              'Result<List<DirectoryEntry>,IoError>::Ok=>false,Result<List<DirectoryEntry>,IoError>::Err(e:IoError)=>'
              'branch on e->phase{'+arms('IoErrorPhase',PHASES,'Target')+'}};unit};')
    tests, tests_manifest = suite.project('',source=source)
    result = subprocess.run([ROOT/'bin/mgn','test',tests_manifest],capture_output=True,timeout=60,cwd=tests)
    assert result.returncode == 0 and not result.stderr and b'total=2 passed=2' in result.stdout, (result.returncode,result.stdout,result.stderr)
    suite.checks += 1
    print(f'v0.14 integration checks={suite.checks} consumer_text_cases={len(checks)} standalone=true builtin_tests=2 failures=0')
