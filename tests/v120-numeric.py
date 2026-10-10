#!/usr/bin/env python3
"""Numeric scalar identities, width constraints, arithmetic, and native parity."""
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "bin/mgn"
checks = 0

def run(args, code=0, input=None):
    global checks
    result = subprocess.run(list(map(str, args)), input=input, capture_output=True, timeout=60)
    checks += 1
    assert result.returncode == code, (args, code, result.returncode, result.stdout, result.stderr)
    if code == 0:
        assert result.stderr == b"", result.stderr
    return result

with tempfile.TemporaryDirectory(prefix="mgn-numeric-") as temporary:
    root = Path(temporary)
    (root / "src").mkdir()
    manifest = '[project]\nname="app"\nroot_namespace="App"\n'
    (root / "mognitio.toml").write_text(manifest)
    path = root / "src/app.mgn"
    prefix = "namespace App;\nuse Std\\Numeric\\{Signed, Unsigned, Bits, IntegerConversionError, BitShiftError};\n"

    def program(body, declarations=""):
        return prefix + declarations + "\nlet main:Function(List<String>):Int=function(args:List<String>):Int{" + body + "};\n"

    def execute(body, declarations="", code=0, message=None):
        path.write_text(program(body, declarations))
        a = run([CLI, "run", root / "mognitio.toml"], code)
        run([CLI, "build", root / "mognitio.toml", "-o", root / "program"])
        b = run([root / "program"], code)
        assert a.stdout == b.stdout == b""
        if message:
            assert a.stderr == b.stderr == message

    for start in range(1, 65, 8):
        assertions = []
        for width in range(start, start + 8):
            for signed in (False, True):
                kind = f"Int<{width},{'Signed' if signed else 'Unsigned'}>"
                lo = -(1 << (width - 1)) if signed else 0
                hi = (1 << (width - (1 if signed else 0))) - 1
                lit = lambda n: f"{kind}{{{n}}}"
                assertions += [
                    f"assert {lit(lo)} == {lit(lo)};",
                    f"assert {lit(hi)} == {lit(hi)};",
                    f"assert {lit(lo)} <= {lit(hi)};",
                    f"assert {lit(hi)} >= {lit(lo)};",
                    f"assert {lit(lo)} + {lit(0)} == {lit(lo)};",
                    f"assert {lit(hi)} - {lit(0)} == {lit(hi)};",
                    f"assert {lit(hi)} * {lit(0)} == {lit(0)};",
                ]
                if hi >= 1:
                    assertions += [f"assert {lit(hi)} / {lit(1)} == {lit(hi)};",
                                   f"assert {lit(hi)} % {lit(1)} == {lit(0)};"]
                if signed:
                    assertions += [f"assert {lit(lo)} % {lit(-1)} == {lit(0)};"]
            bits = f"Bits<{width}>"
            assertions.append(f"assert {bits}{{{(1 << width)-1}}} == {bits}{{{(1 << width)-1}}};")
        execute("".join(assertions) + "0")

    decl = """alias Pattern<N:Int>=Bits<N>;
template makePattern<N:Int>=function():Pattern<N>{Pattern<N>{255}};
template forward<M:Int>=function():Pattern<M>{makePattern<M>()};
template relay<K:Int>=function():Pattern<K>{forward<K>()};
template capture<N:Int>=function(x:Bits<N>):Function():Bits<N>{function():Bits<N>{x}};
"""
    execute("assert relay<8>() == Bits<8>{255};assert capture<64>(Bits<64>{18446744073709551615})() == Bits<64>{18446744073709551615};0", decl)
    execute("let x:List<Int<64,Unsigned>>=List<Int<64,Unsigned>>[Int<64,Unsigned>{18446744073709551615}];assert x->length()==1;0")
    execute("assert Int<64,Unsigned>{18446744073709551615} / Int<64,Unsigned>{9223372036854775808} == Int<64,Unsigned>{1};assert Int<64,Unsigned>{18446744073709551615} % Int<64,Unsigned>{9223372036854775808} == Int<64,Unsigned>{9223372036854775807};0")
    execute("assert Int<64,Unsigned>{9223372036854775808} > Int<64,Unsigned>{9223372036854775807};assert Int<64,Unsigned>{4294967295} * Int<64,Unsigned>{4294967295} == Int<64,Unsigned>{18446744065119617025};0")

    overflow = b"runtime error: integer overflow\n"
    for expression in (
        "Int<8,Signed>{127}+Int<8,Signed>{1}",
        "Int<8,Signed>{-128}-Int<8,Signed>{1}",
        "Int<8,Signed>{64}*Int<8,Signed>{2}",
        "Int<8,Signed>{-128}/Int<8,Signed>{-1}",
        "-Int<8,Signed>{-128}",
        "Int<64,Signed>{-9223372036854775808}/Int<64,Signed>{-1}",
        "Int<64,Unsigned>{18446744073709551615}+Int<64,Unsigned>{1}",
        "Int<64,Unsigned>{0}-Int<64,Unsigned>{1}",
        "Int<64,Unsigned>{9223372036854775808}*Int<64,Unsigned>{2}",
        "-Int<64,Unsigned>{1}",
        "Int<1,Signed>{-1}/Int<1,Signed>{-1}",
        "Int<1,Unsigned>{1}+Int<1,Unsigned>{1}",
    ):
        execute("discard " + expression + ";0", code=4, message=overflow)
    execute("assert -Int<64,Unsigned>{0} == Int<64,Unsigned>{0};0")
    execute("branch when { false => {discard Int<8,Signed>{127}+Int<8,Signed>{1};0}, else => 0 }")

    execute("assert Int<8,Signed>{-1}->toBits()==Bits<8>{255};assert Bits<8>{255}->asInteger<Signed>()==Int<8,Signed>{-1};assert Bits<64>{18446744073709551615}->asInteger<Unsigned>()==Int<64,Unsigned>{18446744073709551615};0")
    execute("assert Bits<8>{170}->and(Bits<8>{15})==Bits<8>{10};assert Bits<8>{170}->or(Bits<8>{15})==Bits<8>{175};assert Bits<8>{170}->xor(Bits<8>{15})==Bits<8>{165};assert Bits<8>{170}->not()==Bits<8>{85};assert Bits<64>{0}->not()==Bits<64>{18446744073709551615};assert Bits<13>{0}->length()==13;0")
    def result_case(expression, value_type, error_type, yes, no):
        result=f"Result<{value_type},{error_type}>"
        return f"assert branch on {expression} {{{result}::Ok(x:{value_type})=>{yes},{result}::Err(e:{error_type})=>{no}}};"
    body=result_case("Int<64,Unsigned>{18446744073709551615}->convertTo<Int>()","Int","IntegerConversionError","false","true")
    body+=result_case("Int<8,Signed>{-1}->convertTo<Int<64,Unsigned>>()","Int<64,Unsigned>","IntegerConversionError","false","true")
    body+=result_case("Int<64,Unsigned>{18446744073709551615}->convertTo<Int<64,Unsigned>>()","Int<64,Unsigned>","IntegerConversionError","x==Int<64,Unsigned>{18446744073709551615}","false")
    body+=result_case("Int<8,Signed>{-128}->convertTo<Int>()","Int","IntegerConversionError","x == -128","false")
    body+=result_case("Bits<8>{255}->shiftLeft(1)","Bits<8>","BitShiftError","x==Bits<8>{254}","false")
    body+=result_case("Bits<64>{18446744073709551615}->shiftRight(63)","Bits<64>","BitShiftError","x==Bits<64>{1}","false")
    body+=result_case("Bits<8>{255}->shiftLeft(-1)","Bits<8>","BitShiftError","false","e->count == -1 && e->width == 8")
    body+=result_case("Bits<8>{128}->at(7)","Bool","IndexError","x","false")
    body+=result_case("Bits<8>{128}->at(8)","Bool","IndexError","false","e->index == 8 && e->length == 8")
    execute(body+"0")

    execute("let x:Box=Box{value:1};assert x->value < 2;0", "type Box=product{value:Int;};")

    execute("assert branch on (-1)->convertTo<Int<8,Signed>>() {Result<Int<8,Signed>,IntegerConversionError>::Ok(x:Int<8,Signed>)=>x==Int<8,Signed>{-1},Result<Int<8,Signed>,IntegerConversionError>::Err(e:IntegerConversionError)=>false};assert (-1)->toBits()==Bits<64>{18446744073709551615};0")
    execute("assert Int<8,Marker>{127}==Narrow{127};0", "alias Marker=Signed;alias Narrow=Int<8,Marker>;")
    execute("assert branch on once()->convertTo<Int<8,Unsigned>>(){Result<Int<8,Unsigned>,IntegerConversionError>::Ok(x:Int<8,Unsigned>)=>x==Int<8,Unsigned>{1},Result<Int<8,Unsigned>,IntegerConversionError>::Err=>false};0",
            'let once:Function():Int=function():Int{1};')
    for kind in ("Int<8,Signed>","Int<64,Unsigned>"):
        for op in ("/","%"):
            execute(f"discard {kind}{{1}}{op}{kind}{{0}};0",code=4,message=b"runtime error: division by zero\n")
    execute("assert branch on Bits<8>{255}->shiftRight(0){Result<Bits<8>,BitShiftError>::Ok(x:Bits<8>)=>x==Bits<8>{255},Result<Bits<8>,BitShiftError>::Err=>false};assert branch on Bits<8>{255}->shiftLeft(8){Result<Bits<8>,BitShiftError>::Ok=>false,Result<Bits<8>,BitShiftError>::Err=>true};0")
    invalid = [
        ("discard Int<8,Signed>{1};0", "type Signed=product{};"),
        ("let x:Int<8,Signed>=1;0",""),
        ("discard Bits<64>{18446744073709551616};0",""),
        ("discard Bits<8>{1}->asInteger;0",""),

        ("discard Bits<8>{1}->length<Int>();0", ""),
        ("discard Bits<8>{1}->asInteger<Int>();0", ""),
        ("discard Int<8,Signed>{1}->convertTo<String>();0", ""),
        ("discard Int<8,Signed>{1}->convertTo();0", ""),
        ("discard Int<8,Signed>{1}->toBits<Int>();0", ""),
        ("discard Bits<8>{1}->and(Bits<16>{1});0", ""),
        ("discard Int<8,Signed>{1}->convertTo<T>();0", "type T=product{};"),
        ("discard Bits<8>{1}->shiftRight(Int<8,Signed>{1});0", ""),

        ("0", "alias Bad=Bits<0>;"), ("0", "alias Bad=Bits<65>;"),
        ("0", "alias Bad=Int<8,Int>;"), ("0", "alias Bad=Int<8>;"),
        ("0", "alias Bad=Bits<-1>;"), ("0", "alias Bad<T>=Int<8,T>;"),
        ("0", "type Box<N:Int>=product{x:Bits<N>;};alias Bad=Box<0>;"),
        ("discard Int<64,Unsigned>{18446744073709551616};0", ""),
        ("discard Int<64,Unsigned>{-1};0", ""),
        ("discard Int<64,Signed>{9223372036854775808};0", ""),
        ("discard Int<64,Signed>{-9223372036854775809};0", ""),
        ("discard Bits<8>{256};0", ""), ("discard Bits<8>{-1};0", ""),
        ("discard Int{1};0", ""), ("discard Int<8,Signed>{1+2};0", ""),
        ("discard Int<8,Signed>{1,2};0", ""),
        ("discard Int<8,Signed>{1}+1;0", ""),
        ("discard Int<8,Signed>{1}+Int<8,Unsigned>{1};0", ""),
        ("discard Bits<8>{1}+Bits<8>{1};0", ""),
        ("discard Bits<8>{1}<Bits<8>{1};0", ""),
        ("discard Bits<8>{1}==Bits<16>{1};0", ""),
        ("discard relay<7>();0", decl),
        ("0", decl + "template unused<N:Int>=function():Bits<8>{makePattern<7>()};"),
        ("0", "template impossible<N:Int>=function():Bits<N>{Bits<N>{18446744073709551616}};"),
    ]
    for body, declarations in invalid:
        text = program(body, declarations)
        path.write_text(text)
        run([CLI, "run", root / "mognitio.toml"], 1)
        previous = (root / "program").read_bytes()
        run([CLI, "build", root / "mognitio.toml", "-o", root / "program"], 1)
        assert (root / "program").read_bytes() == previous
        run([CLI, "test", root / "mognitio.toml"], 1)
        snapshot = {"root": str(root), "manifest": manifest, "sources": {"src/app.mgn": text}}
        result = run(["sbcl", "--noinform", "--script", ROOT / "scripts/analysis-entry.lisp"],
                     input=json.dumps(snapshot).encode() + b"\n")
        assert json.loads(result.stdout)["complete"] is False

print(f"NUMERIC_SCALARS_OK checks={checks}")
