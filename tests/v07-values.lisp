(in-package #:mognitio.tests)

(defun v07-reject (source phase)
  (v03-reject source phase))

(defun v07-accept (source &optional (expected :true))
  (handler-case (v07-accept-internal source expected)
    (compiler-failure (c) (error "Source ~A: ~A" source (diagnostic-message (failure-diagnostic c))))))

(defun v07-accept-internal (source expected)
  (same expected (compiled-result source))
  (let ((input (put-text (fresh-path) source)))
    (multiple-value-bind (out err status) (driver-result (list "run" (namestring input)))
      (same 0 status) (same "" err) (same (format nil "~(~A~)~%" expected) out)))
  (dolist (options '(nil (:stress t :validate t :arena-unit 4096 :cap 4096)))
    (v06-expect-native source expected options)))

(deftest v07-data-and-source-order
  ;; C07-01..10, 45..47, 51: expected values do not use compiler metadata.
  (dolist (source
    '("type N=int; type S=string; let f:function(N,S):int=function(n:N,s:S,):int{n+s->length()}; f(2,\"abc\",)==5"
      "type Z=struct{}; type U=struct{n:int;z:Z;}; type A=U; type E=enum{Zero;Pair(U,string,);}; let e: E=E::Pair(A{z:Z{},n:7,},\"ok\",); branch on(e){E::Zero=>false,E::Pair(u,s,)=>branch when{u->n==7=>s==\"ok\",else=>false,},}"
      "type U=struct{a:int;b:int;}; var n: int=0; let u: U=U{b:{n=n+1;n},a:{n=n+1;n}}; u->a*100+u->b*10+n==212"
      "type U=struct{a:int;b:int;}; var n: int=0; let x: int=loop{U{b:{break 8;},a:{n=n+1;n}}}; x+n==8"
      "type U=struct{a:int;b:int;}; let f:function():int=function():int{U{a:{return 8;},b:1/0}}; f()==8"
      "type U=struct{a:int;}; var u: U=U{a:1}; let old: U=u; u=U{a:2}; old->a*10+u->a==12"
      "type U=struct{a:int;}; let f:function(U):int=function(U:U):int{U->a}; let U: U=U{a:7}; f(U)==7"
      "type X=enum{A(int);B(int);}; branch on(X::B(2)){X::A(X)=>X==1,X::B(X)=>X==2}"
      "type E=enum{A;B(int);}; branch on(E::B (2,)){E::A=>false,E::B(x)=>x==2}"
      "type E=enum{A;B(int);}; let value: E=E::A;true"
      "type E=enum{A;B(int);}; let value: E=E::B(1);true"
      "type E=enum{A;B(int);}; branch on(E::A){E::A=>true,E::B(ignoredPayload1)=>false}"))
    (v07-accept source))
  (dolist (source
    '("type A=struct{x:int;}; type B=struct{x:int;}; let f:function(A):int=function(a:A):int{a->x}; f(B{x:1})==1"
      "type A=struct{x:int;}; type B=struct{x:int;}; let f:function():A=function():A{B{x:1}};true"
      "type A=struct{x:int;}; type B=struct{x:int;}; var a: A=A{x:1};a=B{x:2};true"
      "type U=struct{x:int;}; U{y:1}->x==1" "type U=struct{x:int;}; U{x:1,x:2}->x==1"
      "type U=struct{x:int;}; U{}->x==1" "type U=struct{x:int;}; U{x:false}->x==1"
      "type E=enum{A;B(int);}; let value=E::B();true" "type E=enum{A;B(int);}; let value=E::B;true"
      "type E=enum{A;B(int);}; let value=E::B(1,2);true" "type E=enum{A;B(int);}; let value=E::B(false);true"
      "type E=enum{A;B(int);}; let value=E::A();true" "type E=enum{A;B(int);}; let value=(E::B)(1);true"
      "type E=enum{A;B(int);}; let value=E::B(1)(2);true" "type E=enum{A;B(int);}; let value=(E::A)();true"
      "type U=struct{x:int;}; var u: U=U{x:1};u->x=2;true"
      "type U=struct{};U{}==U{}" "type U=struct{};U{}+U{}==0"
      "type E=enum{A;};E::A!=E::A" "type E=enum{A;};E::A<E::A"
      "type A=Unknown;true" "type A=B;type B=int;true" "type A=A;true"
      "type A=B;type B=A;true" "type A=struct{a:A;};true"
      "type A=enum{A(A);};true" "type A=int;type A=bool;true"
      "interface I{} type I=int;true" "interface I{} type J=I;type A=struct{i:J;};true"
      "interface I{} type J=I;type A=enum{A(J);};true"))
    (v03-reject source "semantic"))
  (dolist (source '("{type A=int;true}" "type A=enum{};true"
                    "type A=struct{function f():int{1}};true"
                    "type A=struct{x:int;}; A{x:1,,}->x==1"
                    "type A=enum{A(int,,);};true" "type A=enum{A(,);};true"
                    "let f:function(int):int=function(x:int,,):int{x};true" "let f:function():int=function(,):int{1};true"
                    "let f:function(int):int=function(x:int):int{x}; f(,)==1" "let f:function(int):int=function(x:int):int{x}; f(1,,)==1"))
    (v03-reject source "parse")))

(deftest v07-branch-contracts
  ;; C07-11..24: completion, scope, static checks, and branch candidate unions.
  (v03-reject "type E=enum{A;B;};branch on(E::A){E::A|E::B=>true}" "lex")
  (dolist (source
    '("var n: int=0; let x: int=branch when{{n=n+1;false}=>1,{n=n+1;true}=>{n=n+10;2},{n=n+100;true}=>1/0,else=>0};x+n==14"
      "type E=enum{A(int,int);B(int,int);}; var n: int=0; let x: int=branch on({n=n+1;E::B(2,3)}){E::A(ignoredPayload2,ignoredPayload3)=>0,E::B(a,b)=>a+b};x+n==6"
      "type E=enum{A;B;}; branch on(E::B){E::A=>false,else=>true}"
      "type E=enum{A;}; branch on(E::A){else=>true}"
      "branch when{false=>void};true" "branch when{true=>void,};true"
      "let f:function():int=function():int{branch when{true=>{return 2;},else=>1}};f()==2"
      "let f:function():int=function():int{branch when{{return 7;}=>1/0,else=>2}};f()==7"
      "type E=enum{A;}; let f:function():int=function():int{branch on({return 7;}){E::A=>1/0}};f()==7"
      "var i: int=0; let x: int=loop{i=i+1;branch when{i<3=>{continue;},else=>{break 8;}};};x+i==11"
      "let a:function():int=function():int{1};let b:function():int=function():int{2};(branch when{false=>a,else=>b})()==2"
      "let f:function(int):int=function(x:int):int{x};let g:function(int):int=function(x:int):int{x+1}; (branch when{true=>f,else=>g})(7,)==7"))
    (v07-accept source))
  (dolist (source
    '("type E=enum{A;B;};branch on(E::A){E::A=>void};true"
      "type E=enum{A;};branch on(E::A){E::A=>true,E::A=>false}"
      "type E=enum{A;};branch on(E::A){E::A=>true,else=>false}"
      "branch when{true=>1}" "branch when{1=>true,else=>false}"
      "branch on(1){else=>true}"
      "type E=enum{A;};type F=enum{A;};branch on(E::A){F::A=>true}"
      "type E=enum{A(int);};branch on(E::A(1)){E::A=>true}"
      "type E=enum{A(int,int);};branch on(E::A(1,2)){E::A(x,x)=>true}"
      "type E=enum{A(int);};let x: int=1;branch on(E::A(1)){E::A(x)=>true}"
      "type E=enum{A(int);};let x=branch on(E::A(1)){E::A(x)=>x};true"
      "type E=enum{A(int);};branch on(E::A(1)){E::A(x)=>true};x==1"
      "branch when{true=>true,else=>unknown}" "branch when{true=>true,else=>{break;}}"
      "branch when{true=>true,else=>1}" "branch when{true=>true,else=>{let x=1+false;true}}"
      "let f:function():int=function():int{branch on({return 1;}){else=>1}};true"
      "let f:function():int=function():int{branch when{true=>{return 1;},else=>{return 2;}};3};true"
      "let f:function():int=function():int{let x=branch when{true=>{return 1;},else=>{return 2;}};3};true"
      "let a:function():int=function():int{1};let b:function():int=function():int{2};let f=branch when{true=>a,else=>b};let g:function():int=function():int{f()};true"))
    (v03-reject source "semantic"))
  (dolist (source '("branch when{true=>return 1;,else=>2}" "branch when{true=>1,,else=>2}"
                    "type E=enum{A(int);};branch on(E::A(1)){E::A(1)=>true}"
                    "type E=enum{A(int);};branch on(E::A(1)){E::A(x) when true=>true}"
                    "type E=enum{A(int);};branch on(E::A(1)){E::A(E::A(x))=>true}"))
    (v03-reject source "parse")))
