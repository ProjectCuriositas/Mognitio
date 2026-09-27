(in-package #:mognitio.tests)

(defun v08-check-template (source)
  (handler-case
      (let ((checked (check-program (parse-text source)))) (verify-checked-program checked) checked)
    (compiler-failure (condition) (error "Source ~A: ~A" source (diagnostic-message (failure-diagnostic condition))))))

(deftest v08-opaque-functions-and-static-calls
  (dolist (source
           '("let identity:function<T>(T):T=function<T>(value:T):T{value}; identity<int>(42)==42"
             "let identity:function<T>(T):T=(function<T>(value:T):T{value}); let alias:function<T>(T):T=(identity); let copy:function<T>(T):T=alias; copy<string>(\"ok\")==\"ok\""
             "let identity:function<T>(T):T=function<T>(T:T):T{T}; identity<bool>(true)"
             "let identity:function<T>(T):T=function<T>(value:T):T{value}; let outer:function<T>(T):T=function<T>(value:T):T{identity<T>(value)}; outer<int>(42)==42"
             "let outer:function<T>(T):T=function<T>(value:T):T{let inner:function(T):T=function(item:T):T{item};inner(value)}; outer<int>(42)==42"
             "let outer:function<T>(T):T=function<T>(value:T):T{let inner:function<U>(T,U):T=function<U>(a:T,b:U):T{a};inner<bool>(value,true)}; outer<int>(42)==42"
             "type Box<T> =struct{value:T;}; let unbox:function<T>(Box<T>):T=function<T>(value:Box<T>):T{value->value}; unbox<int>(Box<int>{value:42})==42"
             "let wrap:function<T,E>(T):Result<T,E> =function<T,E>(value:T):Result<T,E>{Result<T,E>::Ok(value)}; branch on(wrap<int,string>(42)){Result<int,string>::Ok(x)=>x==42,Result<int,string>::Err(ignoredPayload1)=>false,}"
             "let unused:function<T>(T):T=function<T>(value:T):T{value}; let alias:function<T>(T):T=unused; true"
             "let make:function():bool=function():bool{let unused:function<T>(T):T=function<T>(value:T):T{value}; let alias:function<T>(T):T=unused; true}; make()"
             "let identity:function<T>(T):T=function<T>(value:T):T{let copy:T=value; copy}; identity<void>(void); true"
             "let used:function<T>():void=function<T>():void{let holder:function(T):T=function(value:T):T{value};}; true"))
    (is (v08-check-template source))
    (v07-accept source))
  (let* ((checked (v08-check-template "let identity:function<T>(T):T=function<T>(value:T):T{value}; let alias:function<T>(T):T=identity; true"))
         (statements (program-statements (checked-program-program checked))))
    (loop for statement across statements do
      (same :void (checked-normal-type checked statement))
      (same nil (completion-exits (checked-completion checked statement)))
      (is (mognitio.semantic::local-symbol-template (checked-symbol checked statement))))
    (same :bool (checked-normal-type checked (checked-program-program checked)))))

(deftest v08-template-value-and-opaque-rejections
  (dolist (source
           '("let f:function<T>(T):T=function<T>(x:T):T{x+1}; true"
             "let f:function<T>(T):T=function<T>(x:T):T{x+1}; f<int>(42)==43"
             "let f:function<T>(T):int=function<T>(x:T):int{x->length()}; true"
             "let f:function<T>(T):int=function<T>(x:T):int{x->field}; true"
             "let f:function<T>():int=function<T>():int{42}; true"
             "let f:function<T,E>(T):E=function<T,E>(x:T):E{x}; true"
             "type T=int; let f:function<T>(T):T=function<T>(x:T):T{x}; true"
             "let f:function<T,T>(T):T=function<T,T>(x:T):T{x}; true"
             "let f:function<T>(T):T=function<T>(x:T):T{let g:function<T>(T):T=function<T>(y:T):T{y};g<T>(x)}; true"
             "let f:function<T>(T):T=function<T>(x:T):T{x}; f(42)==42"
             "let f:function<T>(T):T=function<T>(x:T):T{x}; let x:int=f(42); true"
             "let f:function<T>(T):T=function<T>(x:T):T{x}; f<int,bool>(42)==42"
             "let f:function<T>(T):T=function<T>(x:T):T{x}; interface I{} f<I>(void); true"
             "let f:function(int):int=function(x:int):int{x}; f<int>(42)==42"
             "function<T>(x:T):T{x}"
             "(function<T>(x:T):T{x})(42)==42"
             "var f:function<T>(T):T=function<T>(x:T):T{x}; true"
             "let f:function<T>(T):T=function<T>(x:T):T{x}; var alias:function<T>(T):T=f; true"
             "let f:function<T>(T):T=function<T>(x:T):T{x}; let alias:void=f; true"
             "let f:function<T>(T):T=function<T>(x:T):T{x}; f; true"
             "let f:function<T>(T):T=function<T>(x:T):T{x}; branch when{true=>f,else=>f}"
             "let f:function<T>(T):T=function<T>(x:T):T{x}; let alias={f}; true"
             "let f:function<T>(T):T=function<T>(x:T):T{x}; let alias=loop{break f;}; true"
             "let f:function<T>(T):T=function<T>(x:T):T{x}; let use:function(int):int=function(x:int):int{x}; use(f)==42"
             "let f:function<T>(T):T=function<T>(x:T):T{x}; let use:function():int=function():int{return f;}; true"
             "let f:function<T>(T):T=function<T>(x:T):T{let inner:function():T=function():T{x};inner()}; true"
             "let f:function<T>(T):T=function<T>(x:T):T{f<int>(42)}; true"
             "let f:function<T>(T):T=function<T>(x:T):T{let alias:function<T>(T):T=f;alias<T>(x)}; true"
             "interface I{let go=function():int;} let f:function<T>(T,I):int=function<T>(x:T,i:I):int{i->go()};type U=struct{};implement U against I{let go=function():int{f<bool>(true,this)};}true"))
    (v03-reject source "semantic")))

(deftest v08-template-metadata-corruption
  (dolist (mutation '(:rigid :parent :binding :completion :argument :call :owner))
    (let* ((checked (v08-check-template "let identity:function<T>(T):T=function<T>(x:T):T{x}; identity<int>(42)==42"))
           (signature (aref (checked-program-signatures checked) 1))
           (binding (aref (program-statements (checked-program-program checked)) 0))
           (call (binary-expression-left (program-root (checked-program-program checked)))))
      (ecase mutation
        (:rigid (setf (signature-parameter-types signature) '(:int)))
        (:parent (setf (mognitio.semantic::signature-parent signature) 99))
        (:binding (setf (mognitio.semantic::local-symbol-template (checked-symbol checked binding)) nil))
        (:completion (setf (completion-normal-type (checked-completion checked binding)) nil))
        (:argument (setf (mognitio.semantic::call-info-type-arguments (checked-call checked call)) '(:bool)))
        (:call (setf (mognitio.semantic::call-info-template (checked-call checked call)) nil))
        (:owner (setf (gethash (function-expression-body (signature-declaration signature))
                              (mognitio.semantic::checked-program-node-owners checked)) 0)))
      (signals internal-failure (verify-checked-program checked)))))
