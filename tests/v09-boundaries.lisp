(in-package #:mognitio.tests)
(setf *v09-positive-fixtures* (append *v09-positive-fixtures* '(("page-collection" "type Page=product{title:String;score:Int;};type Parsed=sum{Valid(Page);Invalid(String);};let parse:Function(String,Int):Parsed=function(title:String,score:Int):Parsed{Parsed::Valid(Page{title:title,score:score})};var pages:List<Page>=List<Page>[];loop over(List<Parsed>[parse(\"one\",2),Parsed::Invalid(\"skip\"),parse(\"two\",3)] as result:Parsed){branch on result{Parsed::Valid(p:Page)=>{pages=pages->append(p);},Parsed::Invalid=>unit};};var text:String=\"\";var score:Int=0;loop over(pages as p:Page){text=text+p.title;score=score+p.score;};pages->length()==2&&text==\"onetwo\"&&score==5")
("callee-argument-order" "var n:Int=0;let value:Int=({n=n*10+1;function(a:Int,b:Int):Int{a+b}})({n=n*10+2;2},{n=n*10+3;3});n==123&&value==5")
("field-source-order" "type P=product{a:Int;b:Int;};var n:Int=0;let p:P=P{b:{n=n*10+1;20},a:{n=n*10+2;10}};n==12&&p.a==10&&p.b==20")
("list-element-order" "var n:Int=0;let xs:List<Int>=List<Int>[{n=n*10+1;1},{n=n*10+2;2},];n==12&&xs->length()==2")
("branch-target-once" "type S=sum{A;};var n:Int=0;let ok:Bool=branch on {n=n+1;S::A}{S::A=>true};ok&&n==1")
("branch-first-match" "var n:Int=0;let x:Int=branch when{{n=n*10+1;false}=>0,{n=n*10+2;true}=>42,{n=n*10+3;true}=>0,else=>0};n==12&&x==42")
("loop-empty-order" "var n:Int=0;loop over(List<Int>[] as x:Int){n=n+x;};loop over(List<Int>[2,2,1] as y:Int){n=n*10+y;};n==221")
("unit-empty-product" "type Empty=product{};let e:Empty=Empty{};discard e;let f:Function():Unit=function():Unit{};f();{}==unit")
("alias-identity" "type P=product{x:Int;};alias Same=P;let p:P=Same{x:42};p.x==42")
("lowercase-alias" "alias int=Int;let n:int=42;n==42")
("qualified-member" "type P=product{length:Int;};let length:Int=42;P{length:length}.length==List<Int>[1]->length()+41")
("isolated-template-before" "template identity<T>=function(value:T):T{value};let value:Int=1;identity<Int>(value)==1")
("isolated-template-local" "let local:Int=0;template identity<T>=function(value:T):T{let local:T=value;local};identity<Int>(42)==42")
("isolated-implementation-before" "contract Add{add(self:Self,x:Int):Int;}implement Int against Add{add(self:Self,x:Int):Int{let local:Int=self+x;local}}let self:Int=1;let x:Int=2;let local:Int=99;Add(self)->add(x)==3")
("self-explicit-alias" "type P=product{x:Int;};alias Page=P;contract Read{read(self:Self):Int;}implement P against Read{read(page:Page):Int{page.x}}Read(P{x:42})->read()==42")
("package-snapshot" "contract Read{read(self:Self):Int;}implement Int against Read{read(x:Self):Int{x}}var n:Int=1;let p:Read=Read(n);n=2;p->read()==1")
("contract-two-types" "type P=product{x:Int;};contract Read{read(self:Self):Int;}implement Int against Read{read(x:Self):Int{x}}implement P against Read{read(p:Self):Int{p.x}}Read(20)->read()+Read(P{x:22})->read()==42")
("generic-discard-closed-shapes" "template drop<T,E>=function(x:List<T>,r:Result<T,E>,f:Function():T):Unit{discard x;discard r;discard f;};drop<Unit,Unit>(List<Unit>[],Result<Unit,Unit>::Ok(unit),function():Unit{});true")
("try-unit" "let f:Function():Result<Unit,String>=function():Result<Unit,String>{try Result<Unit,String>::Ok(unit);Result<Unit,String>::Ok(unit)};branch on f(){Result<Unit,String>::Ok(u:Unit)=>u==unit,Result<Unit,String>::Err=>false}")
("panic-loop-controls" "var n:Int=0;loop while(n<3){n=n+1;panic{continue;};};loop while(true){panic{break;};};n==3")
("list-field-return-unchanged" "type Box=product{items:List<Int>;};let f:Function(List<Int>):List<Int>=function(xs:List<Int>):List<Int>{xs->append(3)};let old:List<Int>=List<Int>[1,2];let b:Box=Box{items:old};let next:List<Int>=f(old);discard next->append(4);old->length()==2&&b.items->length()==2&&next->length()==3")
("closure-shared-containers" "type Both=product{a:Function():Int;b:Function():Int;};var n:Int=1;let f:Function():Int=function():Int{n};let p:Both=Both{a:f,b:f};let xs:List<Function():Int>=List<Function():Int>[f];n=2;var value:Int=0;loop over(xs as g:Function():Int){value=g();};p.a()==1&&p.b()==1&&value==1")
("over-body-return" "let f:Function():Int=function():Int{loop over(List<Int>[42] as x:Int){return x;};0};f()==42")
("method-try" "contract Go{go(self:Self):Result<Int,String>;}implement Int against Go{go(self:Self):Result<Int,String>{let n:Int=try Result<Int,String>::Err(\"bad\");Result<Int,String>::Ok(n)}}branch on Go(1)->go(){Result<Int,String>::Ok=>false,Result<Int,String>::Err(s:String)=>s==\"bad\"}"))))
(deftest v09-boundary-rejection-matrix
 (dolist (source '("type A<T>=product{b:B;};type B=product{x:T;};true"
"type Int=product{};true"
"let Bool:Int=1;true"
"let Function:Int=1;true"
"alias Self=Int;true"
"alias T=Int;template f<T>=function(x:T):T{x};true"
"type P=Int;true"
"type P=product{x:Int;};P{} .x==1"
"type P=product{x:Int;};P{x:1,x:2}.x==1"
"type P=product{x:Int;};let p:P=P{x:1};p.x=2;true"
"type S=sum{A(Int,String);};true"
"let xs:List=List<Int>[];true"
"let xs:List<Int,Bool>=List<Int>[];true"
"let xs:List<Int>=List<Int>[true];true"
"List<Int>[]==List<Int>[]"
"let x:Int=x;true"
"let x:Int=y;let y:Int=1;true"
"{type P=product{};true}"
"let f:Function(Int):Int=function(n:Int):Int{n=2;n};true"
"type S=sum{A(Int);};branch on S::A(1){S::A(x:Int)=>{x=2;true}}"
"loop over(List<Int>[1] as n:Int){n=2;};true"
"loop over({let n:Int=1;List<Int>[n]} as n:Int){unit};true"
"loop while(true){let f:Function():Unit=function():Unit{break;};break;};true"
"loop while(true){break 1;};true"
"loop while(true){1};true"
"template f<T>=function(x:T):T{x+x};discard f<Int>(1);true"
"template f<T>=function(x:T):Unit{x;};true"
"template f<T>=function(x:T):Unit{discard x;};f<Int>(1);true"
"template f<T>=function(x:T):T{branch when{false=>f<List<T>>(List<T>[x]),else=>x}};true"
"template a<T>=function(x:T):T{function():T{a<T>(x)}()};true"
"let f:Function(Int):Int=function(x:Int):Int{x};f<Int>(1)==1"
"let f:Function():Function(Int):Int=function():Function(Int):Int{function(x:Int):Int{x}};f()<Int>(1)==1"
"contract C{f(self:Self):Self;}true"
"contract C{f(self:Self,x:Function(Self):Int):Int;}true"
"contract C{f(self:Self):Int;}implement Int against C{f(self:Bool):Int{1}}true"
"contract C{f(self:Self):Int;}implement Int against C{}true"
"contract C{f(self:Self):Int;}implement Int against C{f(self:Self):Int{1}g(self:Self):Int{2}}true"
"contract C{f(self:Self):Int;}implement Int against C{f(self:Self):Int{1}f(self:Self):Int{2}}true"
"contract C{f(self:Self):Int;}implement Int against C{f(self:Self):Int{1}}implement Int against C{f(self:Self):Int{1}}true"
"contract C{f(self:Self):Int;}C(1)->f()==1"
"contract C{f(self:Self):Int;}implement Int against C{f(self:Self):Int{self}}let c:C=1;true"
"contract C{f(self:Self):Int;}implement Int against C{f(self:Self):Int{self}}1->f()==1"
"contract C{f(self:Self):Int;}implement Int against C{f(self:Self):Int{self}}discard C(1)->f;true"
"let outer:Int=1;contract C{f(self:Self):Int;}implement Int against C{f(self:Self):Int{outer}}true"
"alias A=List<A>;true"
"contract C{f(self:Self):P;}type P=product{c:C;};true"
"type A=product{r:Result<Int,A>;};true"
"9223372036854775808==0"
"-9223372036854775809==0"
"-(9223372036854775808+0)==0"
"List<Int>[1]->append(2);true"
"List<Int>[]->at(0);true"
"discard unit;true"
"(false&&panic{\"x\"});true"
"discard (panic{\"x\"}&&true);true"
"1+panic{\"x\"};true"
"branch on true{else=>false}"
"type S=sum{A;B;};branch on S::A{S::A=>true}"
"type S=sum{A;};alias Same=S;branch on S::A{S::A=>true,Same::A=>false}"
"type S=sum{A;};branch on S::A{S::A(x:Int)=>true}"
"branch when{else=>true,true=>false}"
"branch when{true=>true,else=>true,else=>false}"
"branch when{true=>{true}else=>{false}}"
"let f:Function():Int=function():Int{};true"
"let f:Function():Unit=function():Unit{};f(,);true"
"template f<T>=function():Int{1};f<>()==1"
"panic(\"x\")"
"panic{\"x\"}->length()==1"
"branch on panic{\"x\"}{else=>true}"
"let f:Function():Result<Int,String>=function():Result<Int,String>{Result<Int,String>::Ok(try panic{\"x\"})};true"
"let f:Function(Int,Bool):Int=function(n:Int,b:Bool):Int{n};f(panic{\"x\"},1)==0"
"type P=product{a:Int;b:Bool;};let p:P=P{a:panic{\"x\"},b:1};"
"template bad<T>=function():Int{1+(branch when{true=>List<Int>[panic{\"x\"}],else=>List<Int>[panic{\"y\"}]})};true"
"template bad<T>=function():Int{1+(branch when{true=>List<T>[panic{\"x\"}],else=>List<T>[panic{\"y\"}]})};true"))
  (is (handler-case (progn (check-program (parse-text source)) nil) (compiler-failure () t))
      (format nil "Unexpectedly accepted: ~A" source))))
