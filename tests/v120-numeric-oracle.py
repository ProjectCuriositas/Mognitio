#!/usr/bin/env python3
"""Exhaustive small-width arithmetic and seeded wide-width mathematical oracle."""
import random,subprocess,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
checks=0; pairs=0; vectors=0; SEED=1202026
def run(args):
 global checks
 p=subprocess.run(list(map(str,args)),capture_output=True,timeout=180)
 checks+=1
 assert (p.returncode,p.stdout,p.stderr)==(0,b"",b""),(p.returncode,p.stdout,p.stderr)
def trunc(a,b):return (abs(a)//abs(b))*(-1 if (a<0)!=(b<0) else 1)
def bounds(n,s):return (-(1<<(n-1)),(1<<(n-1))-1) if s else (0,(1<<n)-1)
def lit(t,n):return f"{t}{{{n}}}"
def unwrap(expr,t,error="IntegerConversionError"):return f'branch on {expr}{{Result<{t},{error}>::Ok(converted:{t})=>converted,Result<{t},{error}>::Err(e:{error})=>panic{{"oracle conversion"}}}}'
def execute(body,root):
 extra=""
 if body.startswith("assert "):
  parts=[part for part in body.split(";") if part];chunks=[parts[i:i+24] for i in range(0,len(parts),24)]
  extra="".join(f"let case{i}:Function():Unit=function():Unit{{"+";".join(chunk)+";unit};" for i,chunk in enumerate(chunks))
  body="".join(f"case{i}();" for i in range(len(chunks)))
 (root/"src/app.mgn").write_text("namespace App;use Std\\Numeric\\{Bits,Signed,Unsigned,IntegerConversionError,BitShiftError};"+extra+"let main:Function(List<String>):Int=function(args:List<String>):Int{"+body+"0};")
 run([ROOT/"bin/mgn","run",root/"mognitio.toml"])
 run([ROOT/"bin/mgn","build",root/"mognitio.toml","-o",root/"program"])
 run([root/"program"])
with tempfile.TemporaryDirectory(prefix="mgn-oracle-") as tmp:
 root=Path(tmp);(root/"src").mkdir();(root/"mognitio.toml").write_text('[project]\nname="app"\nroot_namespace="App"\n')
 for n in range(1,9):
  for signed in (False,True):
   lo,hi=bounds(n,signed);t=f"Int<{n},{'Signed' if signed else 'Unsigned'}>"
   count=total=0
   for a in range(lo,hi+1):
    for b in range(lo,hi+1):
     pairs+=1
     values=[a+b,a-b,a*b]
     if b:values += [trunc(a,b),a-trunc(a,b)*b]
     for value in values:
      if lo<=value<=hi:count+=1;total+=value
   bits=f"Bits<{n}>"
   unary=f"let pattern:Int=branch when{{a<0=>a+{1<<n},else=>a}};"
   unary+="assert "+unwrap("x->toBits()->not()->asInteger<Unsigned>()->convertTo<Int>()","Int")+f"=={(1<<n)-1}-pattern;"
   unary+=f"branch when{{(-a)>={lo} && (-a)<={hi}=>{{assert "+unwrap("(-x)->convertTo<Int>()","Int")+"==(-a);},else=>{}};"
   unary+=f"var bitIndex:Int=0;var factor:Int=1;loop while(bitIndex<{n}){{"
   for method,expected in (("shiftLeft",f"(pattern*factor)%{1<<n}"),("shiftRight","pattern/factor")):
    shifted=unwrap(f"x->toBits()->{method}(bitIndex)",bits,"BitShiftError")
    unary+="assert "+unwrap(f"({shifted})->asInteger<Unsigned>()->convertTo<Int>()","Int")+f"==({expected});"
   unary+="assert "+unwrap("x->toBits()->at(bitIndex)","Bool","IndexError")+"==((pattern/factor)%2==1);bitIndex=bitIndex+1;factor=factor*2;};"
   body=f"var count:Int=0;var total:Int=0;var a:Int={lo};loop while(a<={hi}){{let x:{t}="+unwrap(f"a->convertTo<{t}>()",t)+f";assert x->toBits()->asInteger<{'Signed' if signed else 'Unsigned'}>()==x;{unary}var b:Int={lo};loop while(b<={hi}){{let y:{t}="+unwrap(f"b->convertTo<{t}>()",t)+";"
   body+="assert (x<y)==(a<b);assert (x==y)==(a==b);"
   for op in ("+","-","*","/","%"):
    expr=f"a{op}b"
    guard="true" if op not in ("/","%") else "b!=0"
    body+=f"branch when{{{guard}=>{{let expected:Int={expr};branch when{{expected>={lo} && expected<={hi}=>{{let actual:Int="+unwrap(f"(x{op}y)->convertTo<Int>()","Int")+";assert actual==expected;count=count+1;total=total+actual;},else=>{}};},else=>{}};"
   bits=f"Bits<{n}>";unsigned=f"Int<{n},Unsigned>"
   body+=f"var av:Int=branch when{{a<0=>a+{1<<n},else=>a}};var bv:Int=branch when{{b<0=>b+{1<<n},else=>b}};var mask:Int=1;var both:Int=0;var either:Int=0;var different:Int=0;loop while(mask<{1<<n}){{let abit:Int=av%2;let bbit:Int=bv%2;branch when{{abit==1 && bbit==1=>{{both=both+mask;}},else=>{{}}}};branch when{{abit==1 || bbit==1=>{{either=either+mask;}},else=>{{}}}};branch when{{abit!=bbit=>{{different=different+mask;}},else=>{{}}}};av=av/2;bv=bv/2;mask=mask*2;}};"
   for method,expected in (("and","both"),("or","either"),("xor","different")):
    body+="assert "+unwrap(f"x->toBits()->{method}(y->toBits())->asInteger<Unsigned>()->convertTo<Int>()","Int")+f"=={expected};"
   body+=f"b=b+1;}};a=a+1;}};assert count=={count};assert total=={total};"
   execute(body,root)
 rng=random.Random(SEED)
 for start in range(9,65,4):
  body=""
  for n in range(start,min(65,start+4)):
   for signed in (False,True):
    lo,hi=bounds(n,signed);t=f"Int<{n},{'Signed' if signed else 'Unsigned'}>"
    values=sorted(set([lo,lo+1,hi-1,hi,0,1]+([-1] if signed else [(1<<(n-1))-1,1<<(n-1),(1<<(n-1))+1])+[rng.randint(lo,hi) for _ in range(12)]))
    for a in values:
     vectors+=1
     body+=f"assert {lit(t,a)}->toBits()->asInteger<{'Signed' if signed else 'Unsigned'}>()=={lit(t,a)};"
     b=rng.choice(values)
     for op,value in (("+",a+b),("-",a-b),("*",a*b)):
      if lo<=value<=hi:body+=f"assert {lit(t,a)}{op}{lit(t,b)}=={lit(t,value)};"
     if b:
      q=trunc(a,b);r=a-q*b
      if lo<=q<=hi:body+=f"assert {lit(t,a)}/{lit(t,b)}=={lit(t,q)};"
      body+=f"assert {lit(t,a)}%{lit(t,b)}=={lit(t,r)};"
     mask=(1<<n)-1
     for method,value in (("and",(a&mask)&(b&mask)),("or",(a&mask)|(b&mask)),("xor",(a&mask)^(b&mask))):
      body+=f"assert {lit(t,a)}->toBits()->{method}({lit(t,b)}->toBits())==Bits<{n}>{{{value}}};"
     body+=f"assert ({lit(t,a)}<{lit(t,b)})=={'true' if a<b else 'false'};"
  execute(body,root)
print(f"NUMERIC_ORACLE_OK checks={checks} pairs={pairs} wide_vectors={vectors} seed={SEED}")
