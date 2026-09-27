(in-package #:mognitio.tests)

(deftest v08-explicit-local-boundaries
  (dolist (source '("let x: int = 42; var y: int = x; y=y+1; y==43"
                    "let f:function(int):int=function(x: int): int {x}; let alias:function(int):int=(f); alias(42)==42"
                    "let x: string = \"x\"; x==\"x\""
                    "let x: void = void; true"
                    "type E=enum { A(int); }; branch on (E::A(42)) {E::A(x)=>x==42,}"
                    "(branch when {true=>function():bool {true},else=>function():bool {false},})()"))
    (v07-accept source :true))
  (dolist (source '("let x=42; true" "var x=42; true" "let x: int=42; let copy=x; true"
                    "let x: bool=42; true" "let x: Unknown=42; true"
                    "let operation=branch when {true=>function():bool {true},else=>function():bool {false},}; operation()"
                    "var operation:function():bool=function():bool {true}; true"
                    "let f:function():int=function():int{7}; let chosen={f}; chosen()==7"
                    "let f:function():int=function():int{7}; let chosen=loop {break f;}; chosen()==7"))
    (v03-reject source "semantic"))
  (let* ((checked (check-program (parse-text "let x: int=42; true")))
         (binding (aref (program-statements (checked-program-program checked)) 0)))
    (setf (mognitio.semantic::local-symbol-type (checked-symbol checked binding)) :bool)
    (signals internal-failure (verify-checked-program checked))))

(deftest v08-interface-annotated-locals
  (v07-accept "type Value=struct {n:int;}; interface I {let get=function():int;}
implement Value against I {let get=function():int {this->n};}
let x:I=Value {n:42}; var y:I=x; y=Value {n:43}; x->get()+y->get()==85" :true))

(deftest v081-explicit-binding-annotations
  (v03-reject "let x:_=42; true" "lex")
  (dolist (source '("let x:int=42; x==42"
                    "let f:function(int):int=function(value:int):int{value}; f(42)==42"
                    "let cond:bool=true; let f:function():bool=branch when{cond=>function():bool{true},else=>function():bool{false},}; f()"
                    "let identity:function<T>(T):T=function<T>(value:T):T{value}; identity<int>(42)==42"
                    "let identity:function<A>(A):A=function<T>(value:T):T{value}; identity<int>(42)==42"
                    "let identity:function<T>(T):T=function<T>(value:T):T{value}; let alias:function<A>(A):A=identity; alias<int>(42)==42"
                    "let identity:function<T>(T):T=function<T>(value:T):T{value}; let alias:function<A>(A):A=(identity); alias<string>(\"ok\")==\"ok\""
                    "let f:function():int=function():int{1}; let fromBlock:function():int={f}; let fromLoop:function():int=loop{break f;}; fromBlock()+fromLoop()==2"))
    (v07-accept source :true))
  (dolist (source '("let x=42; true"
                    "let f=function(value:int):int{value}; true"
                    "let f:function(bool):int=function(value:int):int{value}; true"
                    "let f:function(int):bool=function(value:int):int{value}; true"
                    "let identity:function<T,U>(T):U=function<T>(value:T):T{value}; true"
                    "let identity:function<T>(int):T=function<T>(value:T):T{value}; true"
                    "let identity:function<T>(T):int=function<T>(value:T):T{value}; true"
                    "let identity:function<T,U>(U):T=function<A,B>(value:A):B{value}; true"
                    "var identity:function<T>(T):T=function<T>(value:T):T{value}; true"
                    "let identity:function<T>(T):T=function<T>(value:T):T{value}; branch when{true=>identity,else=>identity,}"
                    "let identity:function<T>(T):T=function<T>(value:T):T{value}; let use:function(int):int=function(value:int):int{value}; use(identity)==42"
                    "let identity:function<T>(T):T=function<T>(value:T):T{value}; let escape:function():int=function():int{return identity;}; true"
                    "let identity:function<T>(T):T=function<T>(value:T):T{value}; {identity}"
                    "let identity:function<T>(T):T=function<T>(value:T):T{value}; loop{break identity;}; true"
                    "function(value:function(int):int):int{value(1)}"
                    "function():function():int{function():int{1}}"
                    "type Holder=struct{value:function(int):int;}; true"
                    "type Choice=enum{Wrap(function(int):int);}; true"
                    "type Holder<T> =struct{value:T;f:function(int):int;}; true"
                    "type Choice<T> =enum{Value(T);F(function(int):int);}; true"))
    (v03-reject source "semantic"))
  (v03-reject "function consume(f:function<T>(T):T):int{1}" "parse"))
