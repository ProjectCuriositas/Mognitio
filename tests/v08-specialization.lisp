(in-package #:mognitio.tests)

(defparameter *v08-instances-source*
  "let identity:function<T>(T):T=function<T>(x:T):T{x}; let alias:function<T>(T):T=identity; let a:int=identity<int>(42); let b:string=alias<string>(\"ok\"); let c:int=alias<int>(a); branch when{c==42=>b==\"ok\",else=>false}")
(defparameter *v08-nested-source*
  "let outer:function<T>():bool=function<T>():bool{let leaf:function():Result<T,string> =function():Result<T,string>{Result<T,string>::Err(\"x\")};let inner:function():bool=function():bool{branch on(leaf()){Result<T,string>::Ok(ignoredPayload1)=>false,Result<T,string>::Err(e)=>e==\"x\"}};inner()}; outer<int>()==outer<string>()")

(deftest v08-instance-closure-and-isolation
  (dolist (pair (list (cons *v08-instances-source* 3) (cons *v08-nested-source* 7)
                     (cons "let unused:function<T>(T):T=function<T>(x:T):T{let inner:function():bool=function():bool{true};x};let alias:function<T>(T):T=unused;true" 1)
                     (cons "let identity:function<T>(T):T=function<T>(x:T):T{x};let unused:function():int=function():int{identity<int>(42)};true" 3)
                     (cons "let outer:function<T>(T):bool=function<T>(x:T):bool{let independent:function():bool=function():bool{true};independent()};outer<int>(42)==outer<string>(\"ok\")" 4)))
    (let* ((checked (v08-check-template (car pair)))
           (before (length (mognitio.semantic::value-context-types (mognitio.semantic::checked-program-values checked))))
           (first (mognitio.semantic::specialize-program checked))
           (second (mognitio.semantic::specialize-program checked)))
      (is (mognitio.semantic::verify-specialization first))
      (is (mognitio.semantic::verify-specialization second))
      (same (cdr pair) (length (checked-program-signatures first)))
      (same before (length (mognitio.semantic::value-context-types (mognitio.semantic::checked-program-values checked))))
      (is (verify-checked-program checked))
      (is (not (eq (checked-program-program checked) (checked-program-program first))))
      (same (mapcar #'mognitio.semantic::function-instance-key (mognitio.semantic::specialization-proof-instances (mognitio.semantic::checked-program-specialization first)))
            (mapcar #'mognitio.semantic::function-instance-key (mognitio.semantic::specialization-proof-instances (mognitio.semantic::checked-program-specialization second))))
      (v07-accept (car pair)))))

(deftest v08-concrete-control-and-data
  (dolist (source
           '("let choose:function<T>(T,bool):T=function<T>(x:T,flag:bool):T{loop{branch when{flag=>{return x;}};break x;}};let a:int=choose<int>(42,true);let b:string=choose<string>(\"ok\",false);branch when{a==42=>b==\"ok\",else=>false}"
             "let change:function<T>(T,T):T=function<T>(x:T,y:T):T{var value:T=x;value=y;value};change<int>(1,42)==42"
             "let choose:function<T>(T):T=function<T>(x:T):T{let a:function(T):T=function(y:T):T{y};let b:function(T):T=function(z:T):T{z};(branch when{true=>a,else=>b})(x)};choose<int>(42)==42"
             "type Box<T> =struct{value:T;};let identity:function<T>(T):T=function<T>(x:T):T{x};type U=struct{box:Box<int>;};interface I{let get=function():int;}implement U against I{let get=function():int{identity<int>(this->box->value)};}let use:function(I):int=function(i:I):int{i->get()};use(U{box:Box<int>{value:42}})==42"
             "let wrap:function<T,E>(T):Result<T,E> =function<T,E>(value:T):Result<T,E>{Result<T,E>::Ok(value)};let x:Result<void,string> =wrap<void,string>(void);branch on(x){Result<void,string>::Ok(v)=>{v;true},Result<void,string>::Err(ignoredPayload2)=>false}"
             "let identity:function<T>(T):T=function<T>(x:T):T{x};branch when{true=>identity<int>(42)==42,else=>identity<string>(\"ok\")==\"ok\"}"))
    (v07-accept source))
  (let ((source "type Box<T> =struct{value:T;};let make:function<T>(T):Box<T> =function<T>(x:T):Box<T>{Box<T>{value:x}};let keep:Box<Result<string,int>> =make<Result<string,int>>(Result<string,int>::Ok(\"keep\"+\"!\"));var i:int=0;loop while(i<2000){let dead:Box<string> =make<string>(\"dead\"+\"!\");i=i+1;};branch on(keep->value){Result<string,int>::Ok(s)=>s==\"keep!\",Result<string,int>::Err(ignoredPayload3)=>false}"))
    (v07-accept source))
  (same (native-image *v08-instances-source*) (native-image *v08-instances-source*)))

(deftest v08-specialization-corruption
  (dolist (mutation '(:signature :key :environment :binding :callee :extra :tail :shared :metadata))
    (let* ((checked (mognitio.semantic::specialize-program (v08-check-template *v08-instances-source*)))
           (proof (mognitio.semantic::checked-program-specialization checked))
           (instances (mognitio.semantic::specialization-proof-instances proof))
           (first (second instances)) (second (third instances))
           (signature (aref (checked-program-signatures checked) 1)))
      (ecase mutation
        (:signature (setf (signature-parameter-types signature) '(:bool)))
        (:key (setf (mognitio.semantic::function-instance-key first) '(1 nil (:bool))))
        (:environment (setf (mognitio.semantic::function-instance-environment first) nil))
        (:binding (setf (local-symbol-owner (aref (checked-program-bindings checked) 0)) 99))
        (:callee (let ((node (loop for node being the hash-keys of (mognitio.semantic::checked-program-calls checked) return node)))
                   (setf (mognitio.semantic::call-info-targets (checked-call checked node)) '(999))))
        (:extra (setf (mognitio.semantic::specialization-proof-instances proof) (append instances (list first))))
        (:tail (setf (mognitio.semantic::checked-program-program checked)
                     (make-program :source (program-source (checked-program-program checked))
                                   :statements (program-statements (checked-program-program checked)) :root (make-boolean-literal :value :false))))
        (:shared (setf (signature-declaration (mognitio.semantic::function-instance-signature second))
                       (signature-declaration (mognitio.semantic::function-instance-signature first))))
        (:metadata (setf (gethash (make-void-literal) (mognitio.semantic::checked-program-summaries checked))
                        (mognitio.semantic::make-completion :normal-type :void))))
      (signals internal-failure (mognitio.semantic::verify-specialization checked))
      (signals internal-failure (compile-program checked))
      (signals internal-failure (mognitio.ir:lower-program checked)))))

(deftest v08-concrete-type-graph-verification
  (let* ((module (native-ir "type Box<T> =struct{value:T;};type E=enum{Bad;};let x:Box<E> =Box<E>{value:E::Bad};true"))
         (context (mognitio.ir:module-values module))
         (box (find :struct (mognitio.semantic::value-context-types context) :key #'type-info-kind)))
    (is (mognitio.ir:verify-module module))
    (setf (type-info-fields box) (list (cons "value" (canonical-type box))))
    (signals internal-failure (mognitio.ir:verify-module module))))
