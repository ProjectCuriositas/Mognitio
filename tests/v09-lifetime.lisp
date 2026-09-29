(in-package #:mognitio.tests)

(defun v06-gc-dump-forms ()
  ;; Test adapter writes a bounded context record and existing arenas. No heap
  ;; allocation or collector call is introduced by observation.
  '((:label :gc-dump) (:store-word :r15 24 :rax)
    (:mov-reg :rsi :r15) (:mov-edx 240) (:mov-edi 2) (:mov-eax 1) (:syscall)
    (:cmp-imm :rax 240) (:jnz :gc-dump-bad) (:load-word :r8 :r15 8)
    (:label :gc-dump-arena) (:cmp-imm :r8 0) (:jz :gc-dump-done)
    (:mov-reg :rsi :r8) (:load-word :rdx :r8 8)
    (:label :gc-dump-write) (:mov-edi 2) (:mov-eax 1) (:syscall)
    (:test) (:jle :gc-dump-bad) (:add-rsi) (:sub-rdx) (:jnz :gc-dump-write)
    (:load-word :r8 :r8 0) (:jmp :gc-dump-arena)
    (:label :gc-dump-done) (:load-word :rax :r15 24) (:jmp :print)
    (:label :gc-dump-bad) (:mov-edi 97) (:mov-eax 60) (:syscall) (:ud2)))


(defun v06-gc-artifact (source options &optional caller)
  (let ((original (fdefinition 'mognitio.object:layout-units)))
    (replacing (mognitio.object:layout-units
                 (lambda (units)
                   (let ((entry (first units)))
                     (setf (mognitio.object:code-unit-instructions entry)
                           (mapcar (lambda (inst)
                                     (if (and (eq (mognitio.machine:instruction-opcode inst) :jmp)
                                              (equal (mognitio.machine:instruction-operands inst) '(:print)))
                                         (first (machine '(:jmp :gc-dump))) inst))
                                   (mognitio.object:code-unit-instructions entry))))
                   (when caller
                     (setf (mognitio.object:code-unit-instructions
                            (find 0 units :key #'mognitio.object:code-unit-owner))
                           (apply #'machine caller)))
                   (funcall original
                     (append units (list (mognitio.object:make-code-unit :owner :gc-dump
                                          :instructions (apply #'machine (v06-gc-dump-forms))))))))
      (v06-runtime-artifact source options))))


(defun v06-raw-allocate (bytes)
  `((:imm-rax ,bytes) (:store-out 0 :rax) (:imm-rax 0) (:store-out 8 :rax)
    (:call (:runtime :allocate))))

(defun v06-raw-frame ()
  (append '((:label (:function 0)) (:push-rbp) (:mov-reg :rbp :rsp))
          (loop repeat 12 collect '(:push-zero))
          '((:imm-rax 2) (:store-frame -40 :rax) (:lea-base :rax :rbp -48)
            (:store-word :r15 0 :rax))))

(defun v06-raw-finish ()
  '((:imm-rax 0) (:store-word :r15 0 :rax) (:imm-rax 1)
    (:mov-reg :rsp :rbp) (:pop-rbp) (:ret)))


(in-package #:mognitio.tests)
(defparameter *v09-lifetime-source*
  "let obsolete:String=\"dead\"+\"first\";type Page=product{text:String;};type State=sum{Ready(Page);};
contract Readable{read(self:Self):String;}
witness Evidence1 = State implements Readable{read(self:Self):String{branch on self{State::Ready(p:Page)=>p->text}}}
let make:Function(String):Function():String=function(text:String):Function():String{function():String{text}};
let keep:String=\"keep\"+\"!\";
let fn:Function():String=make(keep);
let package:Readable=Readable(State::Ready(Page{text:keep}));
let entries:List<Function():String>=List<Function():String>[fn,fn];
let run:Function():Bool=function():Bool{
 loop over(entries as read:Function():String){
  var i:Int=0;
  loop while(i<2000){
   let dead:String=\"dead\"+\"!\";
   let closure:Function():String=make(dead);
   let box:Readable=Readable(State::Ready(Page{text:dead}));
   discard List<Function():String>[closure];
   discard List<Readable>[box];
   i=i+1;
  };
  branch when{read()==keep=>{return fn()==keep&&package->read()==keep;},else=>unit};
 };
 false
};
run()")
(defun v09-check-heap (artifact mode &optional size)
  (multiple-value-bind (out err status)
      (process-result (append (list "python3" (namestring (root-path "tests/v09-heap-check.py"))
                                   (namestring artifact) mode) (when size (list (princ-to-string size)))) :timeout 60)
    (is (= 0 status) (format nil "Heap oracle failed: ~A ~A" out err))
    (same "" err) (is (search "V09_HEAP_OK" out)) (format t "~A" out)))
(deftest v09-native-bounded-transitive-lifetime
  (same :true (compiled-result *v09-lifetime-source*))
  (dolist (stress '(nil t))
    (v09-check-heap
      (v06-gc-artifact *v09-lifetime-source*
        (list :arena-unit 4096 :cap 4096 :trace t :validate t :stress stress)) "lifetime"))
  (dolist (mutation '(:no-sweep :all-mark :no-trace))
    (multiple-value-bind (out err code)
        (process-result (list (namestring (v06-runtime-artifact *v09-lifetime-source*
          (list :arena-unit 4096 :cap 4096 :validate t :mutation mutation)))))
      (is (not (zerop code)) (format nil "Mutation escaped: ~A" mutation))
      (same "" out)
      (when (= code 4) (same (format nil "runtime error: allocation failure~%") err)))))
(defun v09-chain-forms (n forward)
  (append (v06-raw-frame)
    (loop for i below n append
      (append
        '((:imm-rax 24) (:store-out 0 :rax) (:call (:runtime :allocate-block))
          (:mov-reg :r9 :rax) (:imm-rax 81) (:store-word :r9 8 :rax)
          (:lea-meta (:layout (:list (:list :int)))) (:store-word :r9 16 :rax)
          (:imm-rax 0) (:store-word :r9 24 :rax) (:store-word :r9 48 :rax))
        (list (list :imm-rax (1+ i)) '(:store-word :r9 32 :rax))
        (if (zerop i)
            '((:store-frame -8 :r9) (:lea-object (:static-object :list (:list :int))))
            '((:load-frame :rax -16)))
        '((:store-word :r9 40 :rax) (:store-frame -16 :r9) (:store-frame -32 :r9))))
    (when forward
      (append '((:load-frame :r8 -8))
        (loop repeat (1- n) append
          '((:lea-base :rax :r8 56) (:store-word :r8 40 :rax) (:mov-reg :r8 :rax)))
        '((:lea-object (:static-object :list (:list :int))) (:store-word :r8 40 :rax)
          (:load-frame :rax -8) (:store-frame -32 :rax))))
    '((:imm-rax 0) (:store-word :r15 48 :rax) (:store-word :r15 208 :rax)
      (:store-word :r15 216 :rax) (:store-word :r15 224 :rax)
      (:call (:runtime :collect)))
    (v06-raw-finish)))
(deftest v09-collector-reverse-chain-cost
  (dolist (n '(32 64 128))
    (dolist (forward '(nil t))
      (v09-check-heap
        (v06-gc-artifact "let a:List<Int>=List<Int>[1];true"
          '(:arena-unit 65536 :cap 65536 :validate t)
          (v09-chain-forms n forward))
        (if forward "forward" "reverse") n))))
(deftest v09-live-growth-is-distinct-from-reclamation
  (let ((source "var a:List<Int>=List<Int>[];var i:Int=0;loop while(i<1000){a=a->append(i);i=i+1;};a->length()==1000"))
    (same :true (compiled-result source))
    (multiple-value-bind (out err code)
        (process-result (list (namestring (v06-runtime-artifact source '(:arena-unit 4096 :cap 4096 :validate t)))))
      (same 4 code) (same "" out) (same (format nil "runtime error: allocation failure~%") err))
    (v06-expect-native source :true '(:arena-unit 65536 :cap 65536 :validate t))))

(deftest v09-extracted-child-outlives-parent
  (let ((source "type Leaf=product{text:String;};type Parent=product{child:Leaf;marker:Int;};let make:Function():Leaf=function():Leaf{let parent:Parent=Parent{child:Leaf{text:\"child\"+\"!\"},marker:7};parent->child};let kept:Leaf=make();var i:Int=0;loop while(i<2000){discard Parent{child:Leaf{text:\"trash\"+\"!\"},marker:9};i=i+1;};kept->text==\"child!\""))
    (same :true (compiled-result source))
    (dolist (stress '(nil t))
      (v09-check-heap (v06-gc-artifact source (list :arena-unit 4096 :cap 4096 :validate t :stress stress)) "extracted"))))
