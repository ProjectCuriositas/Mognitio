(in-package #:mognitio.tests)

(deftest v08-generic-type-identity-and-substitution
  (dolist (source
           '("type Box<T> =struct{value:T;}; let x:Box<int> =Box<int>{value:42}; x->value==42"
             "type Box<T> =struct{value:T;}; type Alias<T> =Box<T>; type Count=Alias<int>; let x:Count=Box<int>{value:42}; x->value==42"
             "type Either<T,E> =enum{A(T);B(E);}; type Swap<T,E> =Either<E,T>; let x:Swap<string,int> =Either<int,string>::A(42); branch on(x){Swap<string,int>::A(v)=>v==42,Swap<string,int>::B(ignoredPayload1)=>false,}"
             "type Box<T> =struct{value:T;}; let x:Box<Box<string>> =Box<Box<string>>{value:Box<string>{value:\"ok\"}}; x->value->value==\"ok\""
             "type E=enum{Bad;}; type CountResult=Result<int,E>; let result:CountResult=Result<int,E>::Ok(42); branch on(result){CountResult::Ok(value)=>value==42,CountResult::Err(ignoredPayload2)=>false,}"
             "let result:Result<void,string> =Result<void,string>::Ok(void); branch on(result){Result<void,string>::Ok(value)=>{value;true},Result<void,string>::Err(ignoredPayload3)=>false,}"
             "type Box<T> =struct{value:T;}; type Wrapper=struct{box:Box<int>;}; implement Wrapper{let get=function():int{this->box->value};} Wrapper{box:Box<int>{value:42}}->get()==42"
             "type Alias<T> =T; let Result:int=42; let x:Alias<int> =Result; x==42"
             "type Box<T> =struct{value:T;}; true"))
    (handler-case
        (let ((checked (check-program (parse-text source)))) (is (verify-checked-program checked)) (v07-accept source))
      (compiler-failure (condition) (error "Source ~A: ~A" source (diagnostic-message (failure-diagnostic condition))))))
  (let* ((checked (check-program (parse-text "type Box<T> =struct{value:T;}; type A=Box<int>; type B=Box<int>; true")))
         (context (mognitio.semantic::checked-program-values checked)))
    (same 1 (length (mognitio.semantic::value-context-types context)))
    (same (gethash "A" (mognitio.semantic::value-context-names context))
          (gethash "B" (mognitio.semantic::value-context-names context)))))

(deftest v08-generic-type-rejections
  (dolist (source
           '("type Phantom<T> =struct{value:int;}; true"
             "type Pair<T,T> =struct{value:T;}; true"
             "type T=int; type Box<T> =struct{value:T;}; true"
             "type Box<Result> =struct{value:Result;}; true"
             "type Result=int; true"
             "type Box<T> =struct{value:T;}; let x:Box=Box<int>{value:42}; true"
             "type Box<T> =struct{value:T;}; let x:Box<int,bool> =Box<int>{value:42}; true"
             "type Box<T> =struct{value:T;}; interface I{} type Alias=I; type Bad=Box<Alias>; true"
             "type Box<T> =struct{value:T;}; type Bad=Box<Box>; true"
             "type Box<T> =struct{value:T;}; let x:Box<bool> =Box<int>{value:42}; true"
             "type A<T> =struct{value:T;}; type B<T> =struct{value:T;}; let x:A<int> =B<int>{value:42}; true"
             "type Box<T> =struct{value:T;}; type Wrong=Box<int>; implement Wrong{} true"
             "type Box<T> =struct{value:T;}; type First=Box<int>; type Second=First; interface I{} implement Second against I{} true"
             "type R=Result<int,string>; implement R{} true"
             "type Bad<T> =struct{next:Bad<T>;}; true"
             "type A<T> =B<T>; type B<T> =A<T>; true"
             "type Box<T> =struct{value:T;}; type Later=T; true"
             "type Box<T> =struct{value:T;}; let x:int=0; Box<int>{value:false}->value==x"
             "let x:Result<int,string> =Result::Ok(42); true"
             "let x:Result<int,string> =Result<int,string>::Ok(42); branch on(x){Result::Ok(v)=>true,Result::Err(ignoredPayload4)=>false,}"
             "type Plain=struct{}; Plain<int>{}; true"))
    (v03-reject source "semantic")))

(deftest v08-generic-type-verifier-corruption
  (dolist (mutation '(:opaque :field :argument :builtin :alias :registry :instance))
    (let* ((checked (check-program (parse-text "type Box<T> =struct{value:T;}; type A=Box<int>; let x:A=Box<int>{value:42}; x->value==42")))
           (context (mognitio.semantic::checked-program-values checked))
           (template (gethash 0 (mognitio.semantic::value-context-templates context)))
           (info (aref (mognitio.semantic::value-context-types context) 0)))
      (ecase mutation
        (:opaque (setf (mognitio.semantic::generic-template-fields template) '(("value" . :int))))
        (:field (setf (mognitio.semantic::type-info-fields info) '(("value" . :bool))))
        (:argument (setf (mognitio.semantic::type-info-arguments info) '(:bool)))
        (:builtin (setf (mognitio.semantic::generic-template-declaration
                         (gethash :result (mognitio.semantic::value-context-templates context))) :forged))
        (:registry (setf (gethash :result (mognitio.semantic::value-context-templates context))
                         (mognitio.semantic::copy-generic-template template)))
        (:instance (setf (gethash '(0 :int) (mognitio.semantic::value-context-instances context)) '(:struct 999)))
        (:alias (setf (gethash "A" (mognitio.semantic::value-context-names context)) :int)))
      (signals internal-failure (verify-checked-program checked)))))
