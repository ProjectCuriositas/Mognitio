(in-package #:mognitio.tests)

(defparameter *v08-conformance-cases*
  '(
    ("C08-01"
     ("type Box<T> =struct{value:T;};let x:Box<int> =Box<int>{value:42};x->value==42" "true")
     ("type Box<T> =struct{value:T;};type A=int;let x:Box<A> =Box<A>{value:42};x->value==42" "true")
     ("type Box<T> =struct{value:T;};let x:Box<bool> =Box<bool>{value:true};x->value" "true")
     ("type Box<T> =struct{value:T;};type A=bool;let x:Box<A> =Box<A>{value:true};x->value" "true")
     ("type Box<T> =struct{value:T;};let x:Box<void> =Box<void>{value:void};{x->value;true}" "true")
     ("type Box<T> =struct{value:T;};type A=void;let x:Box<A> =Box<A>{value:void};{x->value;true}" "true")
     ("type Box<T> =struct{value:T;};let x:Box<string> =Box<string>{value:\"ok\"};x->value==\"ok\"" "true")
     ("type Box<T> =struct{value:T;};type A=string;let x:Box<A> =Box<A>{value:\"ok\"};x->value==\"ok\"" "true")
     ("type U=struct{n:int;};type Box<T> =struct{value:T;};let x:Box<U> =Box<U>{value:U{n:42}};x->value->n==42" "true")
     ("type U=struct{n:int;};type Box<T> =struct{value:T;};type A=U;let x:Box<A> =Box<A>{value:U{n:42}};x->value->n==42" "true")
     ("type E=enum{One;};type Box<T> =struct{value:T;};let x:Box<E> =Box<E>{value:E::One};branch on(x->value){E::One=>true}" "true")
     ("type E=enum{One;};type Box<T> =struct{value:T;};type A=E;let x:Box<A> =Box<A>{value:E::One};branch on(x->value){E::One=>true}" "true"))
    ("C08-02"
     ("type Choice<T,E> =enum{Value(T);Error(E);};branch on(Choice<string,int>::Value(\"ok\")){Choice<string,int>::Value(v)=>v==\"ok\",Choice<string,int>::Error(ignoredPayload1)=>false}" "true"))
    ("C08-03"
     ("type Choice<T,E> =Result<E,T>;type Count=Choice<string,int>;let r:Count=Count::Ok(42);branch on(r){Count::Ok(v)=>v==42,Count::Err(ignoredPayload2)=>false}" "true"))
    ("C08-04"
     ("type Box<T> =struct{value:T;};let b:Box<Box<int,>,> =Box<Box<int,>,>{value:Box<int,>{value:42}};b->value->value==42" "true")
     ("type Box<T> =struct{value:T;};type Bad=Box<>;true" "parse")
     ("type Box<T> =struct{value:T;};type Bad=Box<int,,>;true" "parse")
     ("type Box<T> =struct{value:T;};type Bad=Box<,int>;true" "parse"))
    ("C08-05"
     ("type Box<T> =struct{value:T;};let b:Box<bool> =Box<int>{value:42};true" "semantic")
     ("type Box<T> =struct{value:T;};type Other<T> =struct{value:T;};let b:Box<int> =Other<int>{value:42};true" "semantic"))
    ("C08-06"
     ("type Box<T> =struct{value:T;};type Bad=Box<int,bool>;true" "semantic")
     ("type Box<T> =struct{value:T;};type Bad=Box<Missing>;true" "semantic")
     ("type Box<T> =struct{value:T;};type Bad=T;true" "semantic")
     ("type Box<T,T> =struct{value:T;};true" "semantic"))
    ("C08-07"
     ("type Box<T> =struct{value:T;};interface I{} type Bad=Box<I>;true" "semantic")
     ("type Box<T> =struct{value:T;};interface I{} type J=I;type Bad=Box<J>;true" "semantic")
     ("type A<T> =A<T>;true" "semantic")
     ("type A<T> =enum{Next(A<T>);};true" "semantic"))
    ("C08-08"
     ("let identity:function<T>(T):T=function<T>(x:T):T{x};branch when{identity<int>(42)==42=>identity<string>(\"x\")==\"x\",else=>false}" "true"))
    ("C08-09"
     ("let identity:function<T>(T):T=function<T>(x:T):T{x};identity::<int>(42)==42" "parse"))
    ("C08-10"
     ("let identity:function<T>(T):T=function<T>(x:T):T{x};type T=int;let T:int=1;identity < T > (42)==42" "true")
     ("let identity:function<T>(T):T=function<T>(x:T):T{x};identity < Missing > (42)==42" "semantic")
     ("type Box<T> =struct{value:T;};let identity:function<T>(T):T=function<T>(x:T):T{x};identity<Box<Box<int>>>(Box<Box<int>>{value:Box<int>{value:42}})->value->value==42" "true"))
    ("C08-11"
     ("let f:function(int):int=function(x:int):int{x};f<int>(42)==42" "semantic")
     ("let identity:function<T>(T):T=function<T>(x:T):T{x};identity<bool>(42)" "semantic")
     ("let identity:function<T>(T):T=function<T>(x:T):T{x};identity<int>(42,1)==42" "semantic"))
    ("C08-12"
     ("let identity:function<T>(T):T=function<T>(x:T):T{x};let a:function<T>(T):T=identity;let b:function<T>(T):T=(a);b<int>(42)==42" "true")
     ("let identity:function<T>(T):T=function<T>(x:T):T{x};(identity)<int>(42)==42" "reject")
     ("let identity:function<T>(T):T=function<T>(x:T):T{x};identity<int>" "reject")
     ("(function<T>(x:T):T{x})<int>(42)==42" "reject")
     ("let identity:function<T>(T):T=function<T>(x:T):T{x};(branch when{true=>identity,else=>identity})<int>(42)==42" "reject"))
    ("C08-13"
     ("let identity:function<T>(T):T=function<T>(x:T):T{x};identity(42)==42" "semantic")
     ("let r:Result<int,string> =Result::Ok(42);true" "semantic"))
    ("C08-14"
     ("let identity:function<T>(T):T=function<T>(x:T):T{x};let n:int=identity(42);true" "semantic")
     ("let identity:function<T>(T):T=function<T>(x:T):T{x};let f:function():int=function():int{identity(42)};true" "semantic")
     ("let identity:function<T>(T):T=function<T>(x:T):T{x};type U=struct{x:int;};let u:U=U{x:identity(42)};true" "semantic")
     ("let identity:function<T>(T):T=function<T>(x:T):T{x};let n:int=branch when{true=>identity(42),else=>0};true" "semantic")
     ("let identity:function<T>(T):T=function<T>(x:T):T{x};let n:int=identity(42);n==42" "semantic"))
    ("C08-15"
     ("branch on(Result<int,string>::Ok(42)){Result::Ok(v)=>true,Result::Err(ignoredPayload3)=>false}" "semantic")
     ("branch on(Result<int,string>::Ok(42)){Result<bool,string>::Ok(v)=>true,Result<bool,string>::Err(ignoredPayload4)=>false}" "semantic"))
    ("C08-16"
     ("branch on(Result<int,string>::Ok(42)){Result<int,string>::Ok(v)=>true}" "semantic")
     ("branch on(Result<int,string>::Ok(42)){Result<int,string>::Ok(v)=>true,Result<int,string>::Ok(w)=>false,Result<int,string>::Err(ignoredPayload5)=>false}" "semantic")
     ("branch on(Result<int,string>::Ok(42)){Result<int,string>::Ok(v)=>true,Result<int,string>::Err(ignoredPayload6)=>false,else=>false}" "semantic")
     ("let n:bool=branch on(Result<int,string>::Ok(42)){Result<int,string>::Ok(v)=>true,Result<int,string>::Err(ignoredPayload7)=>false};v==42" "semantic"))
    ("C08-17"
     ("let make:function():Result<int,string> =function():Result<int,string>{Result<int,string>::Ok(42)};let r:Result<int,string> =make();branch on(r){Result<int,string>::Ok(v)=>v==42,Result<int,string>::Err(ignoredPayload8)=>false}" "true"))
    ("C08-18"
     ("let r:Result<int,string> =Result<int,string>::Err(\"ordinary\");let n:int=42;branch on(r){Result<int,string>::Ok(ignoredPayload9)=>true,Result<int,string>::Err(ignoredPayload10)=>n!=42}" "false"))
    ("C08-19"
     ("type Wrapped=struct{text:string;};let convert:function(Result<int,string>):Result<int,Wrapped> =function(r:Result<int,string>):Result<int,Wrapped>{branch on(r){Result<int,string>::Ok(v)=>Result<int,Wrapped>::Ok(v),Result<int,string>::Err(e)=>Result<int,Wrapped>::Err(Wrapped{text:e})}};branch on(convert(Result<int,string>::Err(\"kept\"))){Result<int,Wrapped>::Ok(ignoredPayload11)=>false,Result<int,Wrapped>::Err(e)=>e->text==\"kept\"}" "true"))
    ("C08-20"
     ("let f:function():Result<void,string> =function():Result<void,string>{try Result<void,string>::Ok(void);Result<void,string>::Ok(void)};branch on(f()){Result<void,string>::Ok(v)=>{v;true},Result<void,string>::Err(ignoredPayload12)=>false}" "true")
     ("let r:Result<void,string> =Result<void,string>::Ok();true" "semantic"))
    ("C08-21"
     ("type Result=int;true" "semantic")
     ("type Fake=enum{Ok(int);Err(string);};let f:function():Result<int,string> =function():Result<int,string>{Result<int,string>::Ok(try Fake::Ok(42))};true" "semantic")
     ("type R=Result<int,string>;let f:function():R=function():R{R::Ok(try R::Ok(42))};branch on(f()){R::Ok(v)=>v==42,R::Err(ignoredPayload13)=>false}" "true"))
    ("C08-22"
     ("let f:function():Result<int,string> =function():Result<int,string>{var count:int=0;let n:int=try {count=count+1;Result<int,string>::Ok(count)};Result<int,string>::Ok(count*10+n)};branch on(f()){Result<int,string>::Ok(v)=>v==11,Result<int,string>::Err(ignoredPayload14)=>false}" "true"))
    ("C08-23"
     ("let f:function():Result<int,string> =function():Result<int,string>{let n:int=try Result<int,string>::Err(\"early\");Result<int,string>::Ok(n+1/0)};branch on(f()){Result<int,string>::Ok(ignoredPayload15)=>false,Result<int,string>::Err(e)=>e==\"early\"}" "true"))
    ("C08-24"
     ("let f:function():Result<string,string> =function():Result<string,string>{let n:int=try Result<int,string>::Err(\"same\");Result<string,string>::Ok(\"bad\")};branch on(f()){Result<string,string>::Ok(ignoredPayload16)=>false,Result<string,string>::Err(e)=>e==\"same\"}" "true"))
    ("C08-25"
     ("let a:function():Result<int,string> =function():Result<int,string>{Result<int,string>::Err(\"chain\")};let b:function():Result<int,string> =function():Result<int,string>{Result<int,string>::Ok(try a())};let c:function():Result<int,string> =function():Result<int,string>{Result<int,string>::Ok(try b())};branch on(c()){Result<int,string>::Ok(ignoredPayload17)=>false,Result<int,string>::Err(e)=>e==\"chain\"}" "true"))
    ("C08-26"
     ("let a:function(Result<int,string>):Result<int,string> =function(r:Result<int,string>):Result<int,string>{let n:int=try r;Result<int,string>::Ok(n+1)};let b:function(Result<int,string>):Result<int,string> =function(r:Result<int,string>):Result<int,string>{let n:int=branch on(r){Result<int,string>::Ok(v)=>v,Result<int,string>::Err(e)=>{return Result<int,string>::Err(e);}};Result<int,string>::Ok(n+1)};let check:function(Result<int,string>):bool=function(r:Result<int,string>):bool{branch on(a(r)){Result<int,string>::Ok(x)=>branch on(b(r)){Result<int,string>::Ok(y)=>x==y,Result<int,string>::Err(ignoredPayload18)=>false},Result<int,string>::Err(x)=>branch on(b(r)){Result<int,string>::Ok(ignoredPayload19)=>false,Result<int,string>::Err(y)=>x==y}}};branch when{check(Result<int,string>::Ok(41))=>check(Result<int,string>::Err(\"bad\")),else=>false}" "true"))
    ("C08-27"
     ("try panic {\"stop\"}" "semantic")
     ("let f:function():int=function():int{try Result<int,string>::Ok(42)};true" "semantic")
     ("let f:function():Result<int,string> =function():Result<int,string>{Result<int,string>::Ok(try 42)};true" "semantic")
     ("let f:function():Result<int,int> =function():Result<int,int>{Result<int,int>::Ok(try Result<int,string>::Ok(42))};true" "semantic"))
    ("C08-28"
     ("let outer:function():bool=function():bool{let inner:function():Result<int,string> =function():Result<int,string>{loop{let n:int=try Result<int,string>::Err(\"inner\");break Result<int,string>::Ok(n);}};branch on(inner()){Result<int,string>::Ok(ignoredPayload20)=>false,Result<int,string>::Err(e)=>e==\"inner\"}};outer()" "true"))
    ("C08-29"
     ("let f:function():Result<int,string> =function():Result<int,string>{Result<int,string>::Ok(try try Result<Result<int,string>,string>::Ok(Result<int,string>::Ok(41))+1)};branch on(f()){Result<int,string>::Ok(n)=>n==42,Result<int,string>::Err(ignoredPayload21)=>false}" "true")
     ("let f:function():bool=function():bool{try {return true;}};f()" "true"))
    ("C08-30"
     ("let a:function():Result<int,string> =function():Result<int,string>{panic {\"callee\"}};let b:function():Result<int,string> =function():Result<int,string>{Result<int,string>::Ok(try a())};branch on(b()){Result<int,string>::Ok(ignoredPayload22)=>true,Result<int,string>::Err(ignoredPayload23)=>false}" "failure:panic: callee")
     ("let a:function():Result<int,string> =function():Result<int,string>{Result<int,string>::Ok(1/0)};let b:function():Result<int,string> =function():Result<int,string>{Result<int,string>::Ok(try a())};branch on(b()){Result<int,string>::Ok(ignoredPayload24)=>true,Result<int,string>::Err(ignoredPayload25)=>false}" "failure:division by zero")
     ("let a:function():Result<int,string> =function():Result<int,string>{Result<int,string>::Ok(\"x\"->slice(0,2)->length())};let b:function():Result<int,string> =function():Result<int,string>{Result<int,string>::Ok(try a())};branch on(b()){Result<int,string>::Ok(ignoredPayload26)=>true,Result<int,string>::Err(ignoredPayload27)=>false}" "failure:string_index_out_of_bounds"))
    ("C08-31"
     ("let n:int=branch when{true=>42,else=>panic {\"unselected\"}};n==42" "true")
     ("branch when{true=>panic {\"all\"},else=>panic {\"other\"}}" "failure:panic: all"))
    ("C08-32"
     ("let f:function(int,int):bool=function(a:int,b:int):bool{true};f({panic {\"first\"}},1/0)" "failure:panic: first"))
    ("C08-33"
     ("let f:function():bool=function():bool{panic {return true;}};let n:int=loop{panic {break 42;}};var i:int=0;loop while(i<2){i=i+1;panic {continue;}};branch when{f()=>n+i==44,else=>false}" "true"))
    ("C08-34"
     ("panic {\"tail\"}" "failure:panic: tail")
     ("panic(\"old\")" "parse"))
    ("C08-40"
     ("type Box<T> =struct{value:T;};let make:function():Result<Box<string>,int> =function():Result<Box<string>,int>{Result<Box<string>,int>::Ok(Box<string>{value:\"keep\"+\"!\"})};let held:Box<string> =branch on(make()){Result<Box<string>,int>::Ok(v)=>v,Result<Box<string>,int>::Err(ignoredPayload28)=>Box<string>{value:\"bad\"}};var i:int=0;loop while(i<2000){let dead:Box<string> =Box<string>{value:\"dead\"+\"!\"};i=i+1;};held->value==\"keep!\"" "true"))
    ("C08-41"
     ("let f:function<T>(T):T=function<T>(x:T):T{let g:function<U>(U):T=function<U>(y:U):T{f<T>(x)};x};true" "semantic")
     ("let f:function<T>(T):T=function<T>(x:T):T{f<int>(42)};true" "semantic"))
    ("C08-42"
     ("type U=struct{n:int;};interface I{let get=function():int;}implement U against I{let get=function():int{this->n};}let x:I=U{n:40};var n:int=x->get();loop while(n<42){n=n+1;};branch when{n==42=>\"a\"+\"b\"==\"ab\",else=>false}" "true"))
    ("C08-43"
     ("let unused:function<T>(T):T=function<T>(x:T):T{panic {\"must not run\"}};true" "true"))
    ("C08-44"
     ("let a:function():Result<int,string> =function():Result<int,string>{Result<int,string>::Err(\"chain\")};let b:function():Result<int,string> =function():Result<int,string>{Result<int,string>::Ok(try a())};let c:function():Result<int,string> =function():Result<int,string>{Result<int,string>::Ok(try b())};branch on(c()){Result<int,string>::Ok(ignoredPayload29)=>false,Result<int,string>::Err(e)=>e==\"chain\"}" "true"))
    ("C08-45"
     ("let a:int=40;var b:int=a;b=b+2;b==42" "true")
     ("let a=42;true" "semantic")
     ("var a=42;true" "semantic")
     ("let a:bool=42;true" "semantic"))
    ("C08-46"
     ("let f:function(int):int=function(x:int):int{x};f(42)==42" "true")
     ("let f=function(x):int{x};true" "parse")
     ("let f=function(x:int){x};true" "parse")
     ("var f:function():bool=function():bool{true};true" "semantic"))
    ("C08-47"
     ("let f:function():int=function():int{42};let alias:function():int=f;alias()==42" "true")
     ("let x:int=42;let alias=x;true" "semantic"))
    ("C08-48"
     ("type R=Result<int,string>;branch on(R::Ok(42)){R::Ok(n)=>n==42,R::Err(ignoredPayload30)=>false}" "true"))
    ("C08-49"
     ("let identity:function<T>(T):T=function<T>(x:T):T{x};let n:int=identity<int>(41)+1;n==42" "true"))
    ("C08-50"
     ("type T=int;type A<T> =T;true" "semantic")
     ("let f:function<T>(T):T=function<T>(x:T):T{let g:function<T>(T):T=function<T>(y:T):T{y};x};true" "semantic")
     ("let f:function<T>(T):T=function<T>(T:T):T{T};f<bool>(true)" "true")
     ("type A<T> =int;true" "semantic"))
    ("C08-51"
     ("let f:function<T>(T):T=function<T>(x:T):T{x+1};true" "semantic")
     ("let f:function<T>(T):T=function<T>(x:T):T{x==x};true" "semantic")
     ("let f:function<T>(T):T=function<T>(x:T):T{x->field};true" "semantic")
     ("let f:function<T>(T):T=function<T>(x:T):T{x->length()};true" "semantic"))
    ("C08-52"
     ("let f:function<T>(T):T=function<T>(x:T):T{let g:function(T):T=function(y:T):T{y};g(x)};f<int>(42)==42" "true")
     ("let f:function<T>(T):T=function<T>(x:T):T{let g:function():T=function():T{x};g()};true" "semantic"))
    ("C08-53"
     ("let a:function():int=function():int{42};let b:function():int=function():int{0};(branch when{true=>a,else=>b})()==42" "true")
     ("let a:function():int=function():int{42};let b:function():int=function():int{0};let f=branch when{true=>a,else=>b};f()==42" "semantic"))
    ("C08-54"
     ("let try:int=42;true" "parse")
     ("let panic:int=42;true" "parse")
     ("let Result:int=42;Result==42" "true"))
    ("C08-55"
     ("type Box<T> =struct{value:T;};implement Box<int>{}true" "parse")
     ("type Box<T> =struct{value:T;};type A=Box<int>;type B=A;interface I{}implement B{}true" "semantic")
     ("type Box<T> =struct{value:T;};type A=Box<int>;type B=A;interface I{}implement B against I{}true" "semantic")
     ("type G<T> =enum{V(T);};type A=G<int>;type B=A;interface I{}implement B{}true" "semantic")
     ("type G<T> =enum{V(T);};type A=G<int>;type B=A;interface I{}implement B against I{}true" "semantic")
     ("type A=Result<int,string>;type B=A;interface I{}implement B{}true" "semantic")
     ("type A=Result<int,string>;type B=A;interface I{}implement B against I{}true" "semantic")
     ("type Box<T> =struct{value:T;};type Wrapper=enum{Value(Box<int>);};type W=Wrapper;implement W{let get=function():int{branch on(this){W::Value(b)=>b->value}};}W::Value(Box<int>{value:42})->get()==42" "true"))
    ("C08-56"
     ("let forward:function<T,E>(Result<T,E>):Result<T,E> =function<T,E>(r:Result<T,E>):Result<T,E>{let v:T=try r;Result<T,E>::Ok(v)};branch on(forward<int,string>(Result<int,string>::Ok(42))){Result<int,string>::Ok(v)=>v==42,Result<int,string>::Err(ignoredPayload31)=>false}" "true")
     ("let forward:function<T,E>(Result<T,E>):Result<T,E> =function<T,E>(r:Result<T,E>):Result<T,E>{let v:T=try r;Result<T,E>::Ok(v)};branch on(forward<int,string>(Result<int,string>::Err(\"err\"))){Result<int,string>::Ok(ignoredPayload32)=>false,Result<int,string>::Err(e)=>e==\"err\"}" "true")
     ("let forward:function<T,E>(Result<T,E>):Result<T,E> =function<T,E>(r:Result<T,E>):Result<T,E>{let v:T=try r;Result<T,E>::Ok(v)};branch on(forward<string,string>(Result<string,string>::Ok(\"ok\"))){Result<string,string>::Ok(v)=>v==\"ok\",Result<string,string>::Err(ignoredPayload33)=>false}" "true")
     ("let forward:function<T,E>(Result<T,E>):Result<T,E> =function<T,E>(r:Result<T,E>):Result<T,E>{let v:T=try r;Result<T,E>::Ok(v)};branch on(forward<string,string>(Result<string,string>::Err(\"err\"))){Result<string,string>::Ok(ignoredPayload34)=>false,Result<string,string>::Err(e)=>e==\"err\"}" "true")
     ("let forward:function<T,E>(Result<T,E>):Result<T,E> =function<T,E>(r:Result<T,E>):Result<T,E>{let v:T=try r;Result<T,E>::Ok(v)};branch on(forward<void,string>(Result<void,string>::Ok(void))){Result<void,string>::Ok(v)=>{v;true},Result<void,string>::Err(ignoredPayload35)=>false}" "true")
     ("let forward:function<T,E>(Result<T,E>):Result<T,E> =function<T,E>(r:Result<T,E>):Result<T,E>{let v:T=try r;Result<T,E>::Ok(v)};branch on(forward<void,string>(Result<void,string>::Err(\"err\"))){Result<void,string>::Ok(ignoredPayload36)=>false,Result<void,string>::Err(e)=>e==\"err\"}" "true"))
    ("C08-57"
     ("let n:int=panic {\"stop\"};true" "semantic")
     ("let n:int=branch when{true=>panic {\"a\"},else=>panic {\"b\"}};true" "semantic")
     ("var n:int=panic {\"stop\"};true" "semantic")
     ("var n:int=branch when{true=>panic {\"a\"},else=>panic {\"b\"}};true" "semantic")
     ("var n:int=branch when{true=>42,else=>panic {\"stop\"}};n==42" "true"))
    ("C08-58"
     ("panic {}" "semantic")
     ("panic {42}" "semantic")
     ("panic \"old\"" "parse")
     ("panic {\"a\"+\"b\"}" "failure:panic: ab")
     ("var n:int=0;panic {n=n+1;let s:string=branch when{n==1=>\"once\",else=>\"twice\"};s}" "failure:panic: once")
     ("let f:function():bool=function():bool{try panic {\"stop\"}};f()" "failure:panic: stop"))
    ("C08-59"
     ("panic {panic {\"inner\"}}" "failure:panic: inner")
     ("panic {\"x\"->slice(0,2)}" "failure:string_index_out_of_bounds")
     ("panic {return true;}" "semantic")
     ("panic {break;}" "semantic")
     ("panic {continue;}" "semantic")
     ("let n:int=1;panic {let n:string=\"shadow\";n}" "semantic")
     ("loop{let f:function():void=function():void{panic {break;}};break;};true" "semantic")
     ("loop{let f:function():void=function():void{panic {continue;}};break;};true" "semantic")
     ("let f:function():bool=function():bool{panic {return true;\"dead\"}};true" "semantic")
     ("let f:function():bool=function():bool{panic {let x:string=\"private\";x}};x==\"private\"" "semantic"))
    ("C08-60"
     ("let identity:function<T>(T):T=function<T>(x:T):T{x};let alias:function<T>(T):T=(identity);let other:function<T>(T):T=alias;true" "true")
     ("let identity:function<T>(T):T=function<T>(x:T):T{x};identity;true" "semantic")
     ("let identity:function<T>(T):T=function<T>(x:T):T{x};let alias={identity};true" "semantic")
     ("let identity:function<T>(T):T=function<T>(x:T):T{x};let alias=loop{break identity;};true" "semantic")
     ("function<T>(x:T):T{x}" "semantic"))
    ))

(deftest v08-source-conformance-catalog
  (same (append (loop for n from 1 to 34 collect (format nil "C08-~2,'0D" n))
                (loop for n from 40 to 60 collect (format nil "C08-~2,'0D" n)))
        (mapcar #'first *v08-conformance-cases*))
  (dolist (group *v08-conformance-cases*)
    (dolist (fixture (rest group))
      (destructuring-bind (source expected) fixture
        (handler-case
            (cond ((string= expected "true") (v07-accept source :true))
                  ((string= expected "false") (v07-accept source :false))
                  ((and (>= (length expected) 8) (string= expected "failure:" :end1 8))
                   (v08-failure source (subseq expected 8)))
                  ((string= expected "reject")
                   (signals source-failure (check-program (parse-text source))))
                  (t (v03-reject source expected)))
          (error (c) (error "~A: ~A [~A]" (first group) c source)))))))
