(in-package #:mognitio.tests)

(defparameter *v07-gc-source*
  "type Leaf=struct{s:string;}; type Pair=struct{left:Leaf;right:Leaf;v:void;}; type E=enum{Empty;Item(Pair);}; interface Text{let text = function():string;} implement E against Text{let text=function():string{branch on(this){E::Empty=>\"\",E::Item(p)=>p->left->s+p->right->s}};} let make:function():Text=function():Text{let leaf: Leaf=Leaf{s:\"keep\"+\"!\"};E::Item(Pair{right:leaf,left:leaf,v:void})}; let discarded: Leaf=Leaf{s:\"trash\"+\"!\"};let held: Text=make();let child: Leaf={let p: Pair=Pair{left:Leaf{s:\"child\"+\"!\"},right:Leaf{s:\"discard\"+\"!\"},v:void};p->left};var i: int=0;loop while(i<2000){let x: Leaf=Leaf{s:\"dead\"+\"?\"};let e: E=E::Item(Pair{left:x,right:x,v:void});i=i+1;};branch when{held->text()==\"keep!keep!\"=>child->s==\"child!\",else=>false}")

(deftest v07-transitive-lifetime-and-reclamation
  ;; C07-36..39. Allocate over sixty heap capacities while retaining a box,
  ;; its shared deep child, and a child whose original parent is dead.
  (v07-accept *v07-gc-source*)
  (dolist (stress '(nil t))
    (let ((artifact (v06-gc-artifact *v07-gc-source*
                      (list :arena-unit 4096 :cap 4096 :trace t :validate t :stress stress))))
      (multiple-value-bind (out err status)
          (process-result (list "python3" (namestring (root-path "tests/v07-heap-check.py")) (namestring artifact)))
        (same 0 status) (same "" err) (is (search "VALUE_GC_OK" out)) (format t "~A" out))))
  (dolist (mutation '(:no-sweep :all-mark :no-trace))
    (multiple-value-bind (out err status)
        (process-result (list (namestring (v06-runtime-artifact *v07-gc-source*
                              (list :arena-unit 4096 :cap 4096 :mutation mutation :validate t)))))
      (if (eq mutation :no-trace)
          (is (or (/= status 0) (not (string= out (format nil "true~%")))))
          (progn (same 4 status) (same "" out) (same (format nil "runtime: allocation_failed~%") err)))))
  ;; A source-level retention mutant keeps the otherwise dead parent live.
  ;; The independent heap observer must reject it despite a true result.
  (let* ((start (search "let child: Leaf={let p: Pair=" *v07-gc-source*))
         (end (search ";p->left};" *v07-gc-source* :start2 start))
         (mutant (concatenate 'string (subseq *v07-gc-source* 0 start)
                    "let parent: Pair=" (subseq *v07-gc-source* (+ start (length "let child: Leaf={let p: Pair=")) end)
                    ";let child: Leaf=parent->left;" (subseq *v07-gc-source* (+ end (length ";p->left};")))))
         (tail (search "child->s==\"child!\"" mutant)))
    (setf mutant (concatenate 'string (subseq mutant 0 tail)
                   "branch when{parent->right->s==\"discard!\"=>child->s==\"child!\",else=>false}"
                   (subseq mutant (+ tail (length "child->s==\"child!\"")))))
    (multiple-value-bind (out err status)
        (process-result (list "python3" (namestring (root-path "tests/v07-heap-check.py"))
                              (namestring (v06-gc-artifact mutant '(:stress t :validate t :trace t :arena-unit 4096 :cap 4096)))))
      (same 1 status) (same "" out) (is (search "dead parent was retained" err))))
  (multiple-value-bind (out err status)
      (process-result (list "sbcl" "--dynamic-space-size" "256" "--noinform" "--script"
                            (namestring (root-path "tests/v07-host-gc-entry.lisp"))) :timeout 120)
    (same 0 status) (same "" err) (is (search "VALUE_HOST_GC_OK" out)) (format t "~A" out)))

(deftest v07-deep-shared-data
  (let ((source
          (with-output-to-string (out)
            (write-string "type T0=struct{s:string;};" out)
            (loop for i from 1 to 40 do (format out "type T~D=struct{a:T~D;b:T~D;};" i (1- i) (1- i)))
            (write-string "let make:function():T40=function():T40{let v0:T0=T0{s:\"deep\"+\"!\"};" out)
            (loop for i from 1 to 40 do (format out "let v~D:T~D=T~D{a:v~D,b:v~D};" i i i (1- i) (1- i)))
            (write-string "v40};let held:T40=make();var i:int=0;loop while(i<200){let dead:T0=T0{s:\"d\"+\"!\"};i=i+1;};held" out)
            (loop repeat 40 do (write-string "->a" out)) (write-string "->s==\"deep!\"" out))))
    (v07-accept source)
    (multiple-value-bind (out err status)
        (process-result (list "python3" (namestring (root-path "tests/v07-depth-check.py"))
                              (namestring (v06-gc-artifact source '(:stress t :validate t :arena-unit 4096 :cap 4096)))))
      (same 0 status) (same "" err) (is (search "VALUE_DEPTH_OK" out)) (format t "~A" out))))

(deftest v07-allocation-and-operand-failures
  ;; C07-06,28,40: earlier operand failures win; allocator failures remain
  ;; runtime failures after successful compilation.
  (dolist (source '("type U=struct{x:int;y:string;}; U{x:1/0,y:\"a\"->slice(-1,0)}->x==0"
                    "type E=enum{A(int,string);};branch on(E::A(1/0,\"a\"->slice(-1,0))){E::A(x,ignoredPayload1)=>x==0}"))
    (v03-runtime source "division by zero"))
  (v03-runtime "type U=struct{s:string;x:int;};U{s:\"a\"->slice(-1,0),x:1/0}->x==0" "string_index_out_of_bounds")
  (dolist (source '("type U=struct{};let u: U=U{};let later: int=1/0;true"
                    "type U=struct{};interface I{}implement U against I{}let f:function(I):bool=function(u:I):bool{true};f(U{})"))
    (multiple-value-bind (out err status)
        (process-result (list (namestring (v06-runtime-artifact source '(:mmap-fail t)))))
      (same 4 status) (same "" out) (same (format nil "runtime: allocation_failed~%") err)))
  (let ((source "type U=struct{};let u: U=U{};let later: int=1/0;true"))
    (replacing (mognitio.value::%make-data-value
                 (lambda (&rest args) (declare (ignore args)) (error 'storage-condition)))
      (let ((input (put-text (fresh-path) source)))
        (multiple-value-bind (out err status) (driver-result (list "run" (namestring input)))
          (same 4 status) (same "" out) (same (format nil "runtime: allocation_failed~%") err))))))
