(in-package #:mognitio.tests)

(defun v08-failure (source expected)
  (handler-case
      (let ((input (put-text (fresh-path) source)))
        (multiple-value-bind (out err status) (driver-result (list "run" (namestring input)))
          (same 4 status) (same "" out) (same (format nil "runtime: ~A~%" expected) err))
        (dolist (options '(nil (:stress t :validate t :arena-unit 4096 :cap 4096)))
          (multiple-value-bind (out err status) (process-result (list (namestring (v06-runtime-artifact source options))))
            (same 4 status) (same "" out) (same (format nil "runtime: ~A~%" expected) err))))
    (compiler-failure (c) (error "Source ~A: ~A" source (diagnostic-message (failure-diagnostic c))))))

(deftest v08-try-result-flow
  (dolist (source
    '("let f:function():Result<int,string> =function():Result<int,string>{Result<int,string>::Ok(try Result<int,string>::Ok(41)+1)};branch on(f()){Result<int,string>::Ok(x)=>x==42,Result<int,string>::Err(ignoredPayload1)=>false}"
      "let f:function():Result<bool,string> =function():Result<bool,string>{let n:int=try Result<int,string>::Err(\"bad\"+\"!\");Result<bool,string>::Ok(n==42)};branch on(f()){Result<bool,string>::Ok(ignoredPayload2)=>false,Result<bool,string>::Err(e)=>e==\"bad!\"}"
      "type R=Result<int,string>;type E=string;let f:function():Result<bool,E> =function():Result<bool,E>{let n:int=try R::Err(\"same\");Result<bool,E>::Ok(n==42)};branch on(f()){Result<bool,E>::Ok(ignoredPayload3)=>false,Result<bool,E>::Err(e)=>e==\"same\"}"
      "let f:function<T,E>(Result<T,E>):Result<T,E> =function<T,E>(r:Result<T,E>):Result<T,E>{Result<T,E>::Ok(try r)};branch on(f<int,string>(Result<int,string>::Ok(42))){Result<int,string>::Ok(n)=>n==42,Result<int,string>::Err(ignoredPayload4)=>false}"
      "let f:function<T,E>(Result<T,E>):Result<bool,E> =function<T,E>(r:Result<T,E>):Result<bool,E>{let n:T=try r;Result<bool,E>::Ok(true)};branch on(f<int,string>(Result<int,string>::Err(\"kept\"))){Result<bool,string>::Ok(ignoredPayload5)=>false,Result<bool,string>::Err(e)=>e==\"kept\"}"
      "let f:function():Result<void,string> =function():Result<void,string>{try Result<void,string>::Ok(void);Result<void,string>::Ok(void)};branch on(f()){Result<void,string>::Ok(v)=>{v;true},Result<void,string>::Err(ignoredPayload6)=>false}"
      "let f:function():Result<int,string> =function():Result<int,string>{let g:function(int,int):int=function(x:int,y:int):int{x+y};Result<int,string>::Ok(g(try Result<int,string>::Err(\"early\"),1/0))};branch on(f()){Result<int,string>::Ok(ignoredPayload7)=>false,Result<int,string>::Err(e)=>e==\"early\"}"
      "let f:function():int=function():int{try {return 42;}};f()==42"
      "let f:function():int=function():int{panic {return 42;}};f()==42"
      "let f:function():int=function():int{try panic {return 42;}};f()==42"
      "let n:int=loop{panic {break 42;}};n==42"
      "var i:int=0;loop while(i<3){i=i+1;panic {continue;}};i==3"
      "let f:function():Result<int,string> =function():Result<int,string>{let n:int=loop{break try Result<int,string>::Ok(42);};Result<int,string>::Ok(n)};branch on(f()){Result<int,string>::Ok(n)=>n==42,Result<int,string>::Err(ignoredPayload8)=>false}"
      "type U=struct{};interface I{let f=function():Result<int,string>;}implement U against I{let f=function():Result<int,string>{Result<int,string>::Ok(try Result<int,string>::Ok(42))};}branch on(U{}->f()){Result<int,string>::Ok(n)=>n==42,Result<int,string>::Err(ignoredPayload9)=>false}"
      "let f:function():Result<string,int> =function():Result<string,int>{Result<string,int>::Ok((try Result<string,int>::Ok(\"abc\"))->slice(1,3))};branch on(f()){Result<string,int>::Ok(s)=>s==\"bc\",Result<string,int>::Err(ignoredPayload10)=>false}"
      "let f:function():Result<int,void> =function():Result<int,void>{let x:string=try Result<string,void>::Err(void);Result<int,void>::Ok(x->length())};branch on(f()){Result<int,void>::Ok(ignoredPayload11)=>false,Result<int,void>::Err(v)=>{v;true}}"))
    (v07-accept source)))

(deftest v08-error-syntax-and-types
  (dolist (source '("panic \"stop\"" "panic(\"stop\")" "panic" "panic {\"x\",\"y\"}"))
    (v03-reject source "parse"))
  (dolist (source
    '("panic {}" "panic {42}" "try panic {\"stop\"}" "try Result<int,string>::Ok(42)==42"
      "let f:function():int=function():int{try Result<int,string>::Ok(42)};true"
      "let f:function():Result<int,string> =function():Result<int,string>{Result<int,string>::Ok(try 42)};true"
      "let f:function():Result<int,int> =function():Result<int,int>{Result<int,int>::Ok(try Result<int,string>::Ok(42))};true"
      "type Fake=enum{Ok(int);Err(string);};let f:function():Result<int,string> =function():Result<int,string>{Result<int,string>::Ok(try Fake::Ok(42))};true"
      "type A=enum{Bad;};type B=enum{Bad;};let f:function():Result<int,A> =function():Result<int,A>{Result<int,A>::Ok(try Result<int,B>::Ok(42))};true"
      "let f:function():Result<int,string> =function():Result<int,string>{let g:function():int=function():int{try Result<int,string>::Ok(42)};Result<int,string>::Ok(g())};true"
      "let f:function():int=function():int{panic {return 42;\"unreachable\"}};true"
      "panic {let x:string=\"inner\";x};x==\"inner\""
      "let f:function():int=function():int{let x:int=panic {\"stop\"};42};true"))
    (v03-reject source "semantic")))

(deftest v08-panic-messages-and-priority
  (dolist (pair '(("panic {\"stop\"}" "panic: stop")
                  ("panic {\"invalid \"+\"state\"}" "panic: invalid state")
                  ("panic {var n:int=1;n=n+1;branch when{n==2=>\"once\",else=>\"twice\"}}" "panic: once")
                  ("panic {\"\"}" "panic: ")
                  ("panic {panic {\"inner\"}}" "panic: inner")
                  ("panic {let n:int=1/0;\"outer\"}" "division by zero")
                  ("let f:function():bool=function():bool{try panic {\"stop\"}};f()" "panic: stop")
                  ("branch when{true=>panic {\"chosen\"},else=>panic {\"other\"}}" "panic: chosen")
                  ("let f:function<T>(T):T=function<T>(x:T):T{panic {\"generic\"}};f<int>(42)==42" "panic: generic")))
    (v08-failure (first pair) (second pair)))
  (let ((message (concatenate 'string "Aあ😀" (string (code-char 0)) (string #\Newline) "Z")))
    (v08-failure "panic {\"Aあ😀\\0\\nZ\"}" (concatenate 'string "panic: " message))))

(deftest v08-error-metadata-and-core-rejection
  (dolist (source '("panic {\"stop\"}" "let f:function<T,E>(Result<T,E>):Result<T,E> =function<T,E>(r:Result<T,E>):Result<T,E>{Result<T,E>::Ok(try r)};branch on(f<int,string>(Result<int,string>::Ok(42))){Result<int,string>::Ok(n)=>n==42,Result<int,string>::Err(ignoredPayload12)=>false}"))
    (dolist (mode '(:source :concrete))
      (dolist (mutation '(:owner :input :result :return :extra))
        (let* ((original (v08-check-template source))
               (checked (if (eq mode :source) original (mognitio.semantic::specialize-program original)))
               (table (mognitio.semantic::checked-program-errors checked))
               (info (loop for value being the hash-values of table return value)))
          (ecase mutation
            (:owner (setf (mognitio.semantic::error-info-owner info) 999))
            (:input (setf (mognitio.semantic::error-info-operand-type info) :bool))
            (:result (setf (mognitio.semantic::error-info-result-type info) :bool))
            (:return (setf (mognitio.semantic::error-info-return-type info) :bool))
            (:extra (setf (gethash (make-void-literal) table) info)))
          (signals internal-failure (verify-checked-program checked))
          (signals internal-failure (compile-program checked))
          (signals internal-failure (mognitio.ir:lower-program checked))))))
  (let* ((module (native-ir "panic {\"stop\"}")) (f (first (mognitio.ir:module-functions module)))
         (block (first (mognitio.ir:ir-function-blocks f))))
    (is (mognitio.ir:verify-module module))
    (setf (mognitio.ir:basic-block-terminator block) '(:panic 999))
    (signals internal-failure (mognitio.ir:verify-module module)))
  (let* ((module (native-ir "true")) (block (first (mognitio.ir:ir-function-blocks (first (mognitio.ir:module-functions module))))))
    (setf (first (mognitio.ir:basic-block-terminator block)) :panic)
    (signals internal-failure (mognitio.ir:verify-module module))))
