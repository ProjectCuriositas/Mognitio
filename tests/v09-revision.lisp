(in-package #:mognitio.tests)

(defparameter *v09-revision-fixtures*
  '(("value-loop-int" "(loop{break 42;})==42")
    ("value-loop-unit" "loop{break unit;};true")
    ("value-loop-alias" "alias N=Int;let x:N=2;let y:Int=loop{branch when{false=>{break 1;},else=>{break x;}}};y==2")
    ("value-loop-continue" "var n:Int=0;let x:Int=loop{n=n+1;branch when{n<3=>{continue;},else=>{break n;}}};x==3&&n==3")
    ("value-loop-in-condition" "var n:Int=0;loop while(loop{break n<3;}){n=n+1;};n==3")
    ("value-loop-in-target" "var n:Int=0;loop over(loop{break List<Int>[1,2];} as x:Int){n=n+x;};n==3")
    ("value-loop-nested" "let n:Int=loop{loop{break unit;};break 7;};n==7")
    ("value-loop-head-target" "let n:Int=loop{loop over({break 9;} as x:Int){discard x;};};n==9")
    ("value-loop-head-condition" "let n:Int=loop{loop while({break 8;}){};};n==8")
    ("value-loop-break-operand-exit" "let n:Int=loop{break {break 4;};};n==4")
    ("value-loop-break-return" "let f:Function():Int=function():Int{loop{break {return 6;};}};f()==6")
    ("value-loop-break-try" "let f:Function():Result<Int,String>=function():Result<Int,String>{Result<Int,String>::Ok(loop{break try Result<Int,String>::Err(\"stop\");})};branch on f(){Result<Int,String>::Ok=>false,Result<Int,String>::Err(s:String)=>s==\"stop\"}")
    ("value-loop-template" "template id<T>=function(x:T):T{loop{break x;}};id<Int>(3)==3&&id<Unit>(unit)==unit")
    ("value-loop-snapshot" "var n:Int=1;let f:Function():Int=loop{break function():Int{n};};n=2;f()==1")
    ("value-loop-list-root" "let xs:List<String>=loop{break List<String>[\"a\"+\"b\"];};discard List<String>[\"c\"+\"d\"];branch on xs->at(0){Result<String,IndexError>::Ok(s:String)=>s==\"ab\",Result<String,IndexError>::Err=>false}")
    ("value-loop-product-root" "type P=product{s:String;};let p:P=loop{break P{s:\"a\"+\"b\"};};discard List<Int>[1,2,3];p->s==\"ab\"")
    ("value-loop-function-join" "let f:Function():String=loop{branch when{false=>{break function():String{\"x\"};},else=>{let s:String=\"a\"+\"b\";break function():String{s};}}};discard List<String>[\"c\"+\"d\"];f()==\"ab\"")
    ("member-field-call-order" "type P=product{f:Function(Int):Int;};var n:Int=0;let p:P=P{f:function(x:Int):Int{x}};let r:Int=({n=n+1;p})->f({n=n*10;n});r==10&&n==10")
    ("member-field-value" "type P=product{f:Function(Int):Int;};let p:P=P{f:function(x:Int):Int{x+1}};let f:Function(Int):Int=p->f;f(2)==3&&(p->f)(3)==4")
    ("member-chain" "type Inner=product{value:Int;};type Outer=product{inner:Inner;};Outer{inner:Inner{value:2}}->inner->value==2")
    ("member-operation-field" "type P=product{length:Function():Int;};P{length:function():Int{7}}->length()==7")
    ("member-field-template" "type P<T>=product{f:Function(T):T;};template run<T>=function(x:T):T{P<T>{f:function(y:T):T{y}}->f(x)};run<Int>(7)==7")
    ("underscore-discard" "let _:Int=1;discard _;_==1")
    ("underscore-binding" "var _:Int=1;_=2;_==2")
    ("underscore-parameter" "let f:Function(Int):Int=function(_:Int):Int{_};f(3)==3")
    ("underscore-payload" "branch on Result<Int,String>::Ok(4){Result<Int,String>::Ok(_:Int)=>_==4,Result<Int,String>::Err=>false}")
    ("underscore-element" "var total:Int=0;loop over(List<Int>[1,2] as _:Int){total=total+_;};total==3")
    ("underscore-receiver-field" "type P=product{_:Int;};contract C{_(receiver:Self):Int;}witness Evidence1 = P implements C{_(_:Self):Int{_-> _}}C(P{_:5})->_()==5")
    ("witness-alias" "alias Number=Int;contract C{get(self:Self):Int;}witness Evidence2 = Number implements C{get(value:Self):Int{value}}C(4)->get()==4")
    ("member-nested-generic" "type Box<T>=product{value:T;};type Outer<T>=product{box:Box<T>;};template make<T>=function(x:T):T{Outer<T>{box:Box<T>{value:x}}->box->value};make<Int>(2)==2&&make<Bool>(true)")
    ("value-loop-continue-operand" "var n:Int=0;let x:Int=loop{n=n+1;break branch when{n<2=>{continue;},else=>n};};x==2")
    ("member-returned-function" "type P=product{make:Function():Function(Int):Int;};P{make:function():Function(Int):Int{function(x:Int):Int{x}}}->make()(4)==4")
    ("member-field-list" "type P=product{xs:List<String>;};P{xs:List<String>[\"a\"]}->xs->length()==1")
    ("former-keyword-identifiers"  "let implement:Int=1;let against:Int=2;implement+against==3")))

(setf *v09-positive-fixtures* (append *v09-positive-fixtures* *v09-revision-fixtures*))

(deftest v09-revision-rejections
  (dolist (source
           '("loop{break;};true"
             "loop while(true){break unit;};true"
             "loop over(List<Int>[] as n:Int){break 1;};true"
             "let n:Int=loop while(true){break;};true"
             "discard loop{break unit;};true"
             "loop{branch when{true=>{break 1;},else=>{break false;}}}"
             "type A=product{};type B=product{};loop{branch when{true=>{break A{};},else=>{break B{};}}}"
             "template f<T,U>=function(x:T,y:U):T{loop{branch when{true=>{break x;},else=>{break y;}}}};true"
             "loop{let f:Function():Unit=function():Unit{break unit;};break unit;};true"
             "loop{break 1;} ; true"
             "loop{break unit;unit};true"
             "type P=product{x:Int;};P{x:1}.x==1"
             "type P=product{x:Int;};P{x:1}->x()==1"
             "List<Int>[]->length"
             "contract C{f(self:Self):Int;}witness Evidence3 = Int implements C{f(self:Self):Int{self}}C(1)->f"
             "contract C{}implement Int against C{}true"
             "let _:Int=1;let _:Int=2;true"
             "let _:Int=1;{let _:Bool=true;unit};true"
             "let _:Int={let _:Int=1;_};true"
             "let _:Int=1;_;true"
             "branch on Result<Int,String>::Ok(1){Result<Int,String>::Ok(_)=>true,Result<Int,String>::Err=>false}"))
    (signals compiler-failure (check-program (parse-text source)))))

(deftest v09-value-loop-noncompletion-and-mutations
  (dolist (source '("loop{}" "loop{continue;}"
                    "loop{break panic{\"stop\"};}"))
    (let* ((checked (check-program (parse-text source)))
           (node (program-root (checked-program-program checked))))
      (same nil (checked-normal-type checked node))
      (same nil (completion-structure (checked-completion checked node)))
      (verify-checked-program checked)
      (mognitio.ir:verify-module (native-ir source))
      (mognitio.backend.native:compile-program checked (mognitio.target:linux-amd64))))
  (dolist (concrete-p '(nil t))
    (dolist (mutation '(:loop :break))
      (let* ((original (check-program (parse-text "template f<T>=function(x:T):T{loop{break x;}};f<Int>(3)==3")))
             (checked (if concrete-p (mognitio.semantic::prepare-runtime-program original) original)))
        (ecase mutation
          (:loop (maphash (lambda (node info) (declare (ignore node)) (setf (loop-info-normal-type info) :bool))
                          (mognitio.semantic::checked-program-loops checked)))
          (:break (maphash (lambda (node summary)
                            (when (typep node 'break-statement)
                              (setf (completion-exits summary) nil)))
                          (mognitio.semantic::checked-program-summaries checked))))
        (signals internal-failure (verify-checked-program checked)))))
  (let ((checked (check-program (parse-text "loop{loop{break unit;};break unit;};true"))))
    (maphash (lambda (node info) (declare (ignore node)) (setf (loop-info-id info) 0))
             (mognitio.semantic::checked-program-loops checked))
    (signals internal-failure (verify-checked-program checked)))
  ;; A Function member selection must stay a field access in checked evidence.
  (let* ((checked (check-program (parse-text "type P=product{f:Function():Int;};P{f:function():Int{1}}->f()==1")))
         (node (loop for n being the hash-keys of (mognitio.semantic::checked-program-calls checked)
                     when (typep n 'method-call) return n)))
    (setf (member-info-kind (checked-member checked node)) :interface-call)
    (signals internal-failure (verify-checked-program checked))))

(deftest v09-host-allocation-execution-boundary
  ;; Inject before the helper's own handler to cover call/rest/table setup.
  (dolist (entry '((mognitio.value::closure-call . "let f:Function():Bool=function():Bool{true};f()")
                   (mognitio.value:pack . "contract C{get(self:Self):Bool;}witness Evidence4 = Bool implements C{get(self:Self):Bool{self}}C(true)->get()")
                   (mognitio.value::list-literal . "List<Int>[1]->length()==1")))
    (let* ((symbol (car entry)) (old (fdefinition symbol))
           (source (namestring (put-text (fresh-path) (cdr entry)))))
      (unwind-protect
           (progn
             (setf (fdefinition symbol) (lambda (&rest args) (declare (ignore args)) (error 'storage-condition)))
             (multiple-value-bind (out err code) (driver-result (list "run" source))
               (same 4 code) (same "" out) (same (format nil "runtime error: allocation failure~%") err)))
        (setf (fdefinition symbol) old))))
  (let ((source (namestring (put-text (fresh-path) "true"))))
    (replacing (mognitio.backend.cl::host-compile (lambda (&rest args) (declare (ignore args)) (error 'storage-condition)))
      (multiple-value-bind (out err code) (driver-result (list "run" source))
        (same 3 code) (same "" out) (is (search "internal:" err))))
    (replacing (mognitio.driver::checked-source (lambda (&rest args) (declare (ignore args)) (error 'storage-condition)))
      (multiple-value-bind (out err code) (driver-result (list "run" source))
        (same 3 code) (same "" out) (is (search "internal:" err)))))
  (let ((source (namestring (put-text (fresh-path) "let f:Function():Bool=function():Bool{true};f()"))))
    (replacing (mognitio.value::closure-call (lambda (&rest args) (declare (ignore args)) (error "not allocation")))
      (multiple-value-bind (out err code) (driver-result (list "run" source))
        (same 3 code) (same "" out) (is (search "internal:" err))))))

(deftest v09-revision-static-diagnostic
  (let ((source (namestring (put-text (fresh-path) "let _:Bool=1;true"))))
    (multiple-value-bind (out err code) (driver-result (list "run" source))
      (same 1 code) (same "" out)
      (is (search "type:" err)) (is (search "[bytes " err))
      (is (not (search "category" err))))))

(deftest v09-body-only-type-proof-mutations
  (dolist (mutation '(:origin :argument :field))
    (let* ((checked (mognitio.semantic::prepare-runtime-program
                      (check-program (parse-text "type P<T>=product{f:Function(T):T;};template run<T>=function(x:T):T{P<T>{f:function(y:T):T{y}}->f(x)};run<Int>(7)==7"))))
           (proof (mognitio.semantic::checked-program-specialization checked))
           (recorded (mognitio.semantic::specialization-proof-type-context proof))
           (info (find "P" (value-context-types recorded) :key #'type-info-name :test #'string=)))
      (ecase mutation
        (:origin (setf (mognitio.semantic::type-info-origin info) :nonexistent))
        (:argument (setf (mognitio.semantic::type-info-arguments info) '(:bool)))
        (:field (let ((concrete (find "P" (value-context-types (checked-program-values checked)) :key #'type-info-name :test #'string=)))
                  (setf (type-info-fields concrete) '(("f" . :int))))))
      (signals internal-failure (verify-checked-program checked)))))

(deftest v09-break-failure-runtime
  (let ((source "let x:Int=loop{break panic{\"stop\"};};"))
    (multiple-value-bind (out err code) (driver-result (list "run" (namestring (put-text (fresh-path) source))))
      (same 4 code) (same "" out) (same (format nil "panic: stop~%") err))
    (multiple-value-bind (out err code) (process-result (list (namestring (build-text source))))
      (same 4 code) (same "" out) (same (format nil "panic: stop~%") err))))
