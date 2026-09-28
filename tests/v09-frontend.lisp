(in-package #:mognitio.tests)

(deftest v09-symbolic-and-host-fixtures
  (dolist (fixture *v09-positive-fixtures*)
    (handler-case
        (let* ((checked (check-program (parse-text (second fixture))))
               (concrete (mognitio.semantic::prepare-runtime-program checked)))
          (is (eq checked (verify-checked-program checked)))
          (is (eq concrete (mognitio.semantic::verify-specialization concrete)))
          (same :true (execute-program (compile-program concrete))))
      (error (condition) (error "Fixture ~A: ~A" (first fixture) condition)))))

(deftest v09-rejected-boundaries
  (dolist (text '("let x=1;true" "let x:int=1;true" "loop{break;};true"
    "template bad<T>=function(x:T):Unit{discard x;};true"
    "alias Id<T>=T;template bad<T>=function(x:Id<T>):Unit{discard x;};true"
    "template bad<T>=function(f:Function():T):Unit{discard f();};true"
    "template id<T>=function(x:T):T{x};let f:Function(Int):Int=id;true"
    "template a<T>=function(x:T):T{b<T>(x)};template b<T>=function(x:T):T{a<T>(x)};true"
    "let x:Int=1;template bad<T>=function(v:T):Int{x};true"
    "let x:Int=1;let f:Function(Int):Int=function(x:Int):Int{x};true"
    "var x:Int=1;let f:Function():Unit=function():Unit{x=2;};true"
    "let f:Function():Int=function():Int{f()};true"
    "type A=product{b:B;};type B=product{a:A;};true"
    "type A=product{f:Function():A;};true"
    "contract A{run(self:Self):A;}true"
    "contract A{run(self:Self,x:Self):Int;}true"
    "type Empty=sum{};true"
    "discard panic{\"stop\"};true"
    "let x:Int=panic{\"stop\"};true"
    "(panic{\"a\"})==(panic{\"b\"})"
    "(panic{\"a\"})()"
    "1+(List<Int>[panic{\"a\"}])==1"
    "1+(branch when{true=>List<Int>[panic{\"a\"}],else=>List<Int>[panic{\"b\"}]})==1"
    "1<2==true"
    "loop while(break){unit};true"
    "loop over(xs as xs:List<Int>){unit};true"
    "List<Int>[1]->missing()==1"
    "type P=product{x:Int;};P{x:1}==P{x:1}"
    "type S=sum{A(Int);B;};branch on S::A(1){S::A(x:Bool)=>true,S::B=>false}"
    "branch when{true=>true}"
    "type S=sum{A;};branch on S::A{else=>true}"
    "return true;"
    "try Result<Bool,String>::Ok(true)"
    "let f:Function():Result<Int,String>=function():Result<Int,String>{Result<Int,String>::Ok(try Result<Int,Int>::Err(panic{\"x\"}))};true"))
    (signals compiler-failure (check-program (parse-text text)))))

(deftest v09-symbolic-proof-mutations
  (flet ((rejected (text mutate)
           (let ((checked (check-program (parse-text text))))
             (funcall mutate checked)
             (signals internal-failure (verify-checked-program checked)))))
    (rejected "true" (lambda (c) (setf (completion-structure (checked-completion c (program-root (checked-program-program c)))) nil)))
    (rejected "true" (lambda (c) (setf (completion-normal-type (checked-completion c (program-root (checked-program-program c)))) nil)))
    (rejected "1+2==3" (lambda (c)
      (setf (operation-info-kind (checked-operation c (binary-expression-left (program-root (checked-program-program c))))) :sub)))
    (rejected "let x:Int=1;let f:Function():Int=function():Int{x};f()==1"
      (lambda (c) (setf (signature-captures (aref (checked-program-signatures c) 1)) nil)))))

(deftest v09-specialization-proof-mutations
  (let ((text "template probe<T,U>=function(flag:Bool):Int{1+(branch when{flag=>List<T>[panic{\"left\"}],else=>List<U>[panic{\"right\"}]})};discard probe<Int,Int>(true);true"))
    (dolist (mutation '(:promote :erase :operation :node))
      (let* ((concrete (mognitio.semantic::prepare-runtime-program (check-program (parse-text text))))
             (node (loop for n being the hash-keys of (mognitio.semantic::checked-program-summaries concrete)
                         when (typep n 'branch-expression) return n))
             (summary (checked-completion concrete node)))
        (same nil (completion-structure summary))
        (ecase mutation
          (:promote (setf (completion-structure summary) '(:list :int)))
          (:erase (let ((plus (loop for n being the hash-keys of (mognitio.semantic::checked-program-operations concrete)
                                   when (typep n 'binary-expression) return n)))
                    (setf (completion-structure (checked-completion concrete plus)) nil)))
          (:operation (maphash (lambda (n op) (declare (ignore n)) (when (eq :add (operation-info-kind op)) (setf (operation-info-kind op) :sub)))
                               (mognitio.semantic::checked-program-operations concrete)))
          (:node (let ((proof (mognitio.semantic::checked-program-specialization concrete)))
                   (clrhash (mognitio.semantic::function-instance-nodes (second (mognitio.semantic::specialization-proof-instances proof)))))))
        (signals internal-failure (mognitio.semantic::verify-specialization concrete))))))

(deftest v09-panic-and-arithmetic
  (dolist (case '(("let x:Int=panic{\"stop\"};" :panic "stop")
                 ("9223372036854775807+1==0" :overflow nil)
                 ("1%0==0" :division-by-zero nil)
                 ("-9223372036854775808/(-1)==0" :overflow nil)))
    (let ((condition (handler-case (progn (compiled-result (first case)) nil)
                       (mognitio.runtime:program-runtime-failure (e) e))))
      (is condition)
      (same (second case) (mognitio.runtime::failure-kind condition))
      (when (third case)
        (same (third case) (sb-ext:octets-to-string (mognitio.text::text-value-octets (mognitio.runtime::panic-message condition)) :external-format :utf-8))))))

(deftest v09-persistent-costs
  (let ((counts (make-hash-table)) (old mognitio.value::*empty-list*))
    (let ((mognitio.value::*list-operation-observer* (lambda (kind) (incf (gethash kind counts 0)))))
      (dotimes (n 1000) (mognitio.value::list-append-value old n))
      (same 1000 (gethash :node-create counts)) (same 0 (gethash :link-visit counts 0))
      (dotimes (n 1000) (setf old (mognitio.value::list-append-value old n)))
      (same 2000 (gethash :node-create counts)) (same 0 (gethash :link-visit counts 0))
      (same (coerce (loop for n below 1000 collect n) 'vector) (mognitio.value::list-buffer old))
      (same 1000 (gethash :link-visit counts)) (same 1000 (gethash :buffer-write counts)))))
