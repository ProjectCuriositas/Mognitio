(in-package #:mognitio.tests)

(defparameter *v08-err-source*
  "let f:function(Result<int,string>):Result<bool,string> =function(r:Result<int,string>):Result<bool,string>{let n:int=try r;Result<bool,string>::Ok(n==42)};branch on(f(Result<int,string>::Err(\"kept\"+\"!\"))){Result<bool,string>::Ok(ignoredPayload1)=>false,Result<bool,string>::Err(e)=>e==\"kept!\"}")

(deftest v08-try-core-guards-and-last-payload-use
  (let* ((module (native-ir *v08-err-source*))
         (function (second (mognitio.ir:module-functions module)))
         (block (find-if (lambda (b) (some (lambda (i) (and (eq :enum.make (mognitio.ir:instruction-op i))
                                                                           (eql 1 (mognitio.ir:instruction-value i))))
                                                          (mognitio.ir:basic-block-instructions b)))
                        (mognitio.ir:ir-function-blocks function)))
         (payload (first (mognitio.ir:basic-block-instructions block)))
         (plans (mognitio.roots:analyze-roots module))
         (plan (second plans))
         (site (find (mognitio.ir:basic-block-id block) (mognitio.roots:root-plan-sites plan)
                     :key #'mognitio.roots:root-site-block-id)))
    (same :enum.payload (mognitio.ir:instruction-op payload))
    ;; Only the extracted string survives into allocation of the new Err.
    (same (list (mognitio.ir:instruction-result payload)) (mognitio.roots:root-site-values site))
    (setf (mognitio.roots:root-site-values site) nil)
    (signals internal-failure (mognitio.roots:verify-roots module plans)))
  (dolist (mutation '(:variant :subject :return-type))
    (let* ((module (native-ir *v08-err-source*)) (function (second (mognitio.ir:module-functions module)))
           (blocks (mognitio.ir:ir-function-blocks function))
           (payload (loop for b in blocks thereis (find :enum.payload (mognitio.ir:basic-block-instructions b) :key #'mognitio.ir:instruction-op)))
           (tag (loop for b in blocks thereis (find :enum.tag (mognitio.ir:basic-block-instructions b) :key #'mognitio.ir:instruction-op))))
      (ecase mutation
        (:variant (setf (second (mognitio.ir:instruction-value payload)) 1))
        (:subject (setf (mognitio.ir:instruction-operands tag) '(999)))
        (:return-type (setf (mognitio.ir:ir-function-result-type function) (first (mognitio.ir:ir-function-parameter-types function)))))
      (signals internal-failure (mognitio.ir:verify-module module)))))

(deftest v08-concrete-descriptor-bytes
  (dolist (pair '(("int" "42" 0) ("bool" "true" 0) ("void" "void" 0) ("string" "\"x\"" 1)))
    (destructuring-bind (type value refs) pair
      (let* ((source (format nil "type Box<T> =struct{value:T;};let x:Box<~A> =Box<~A>{value:~A};true" type type value))
             (code (mognitio.machine:lower-module (native-ir source))))
        (multiple-value-bind (bytes labels) (mognitio.amd64:encode code)
          (let ((offset (mognitio.object:image-symbol-offset (gethash '(:descriptor 0 0) labels))))
            (same (list 1 0 0 1 refs) (loop for n below 5 collect (image-integer bytes (+ offset (* n 8)) 8)))
            (when (plusp refs) (same 0 (image-integer bytes (+ offset 40) 8))))))))
  (let* ((code (mognitio.machine:lower-module (native-ir "let r:Result<void,string> =Result<void,string>::Ok(void);true"))))
    (multiple-value-bind (bytes labels) (mognitio.amd64:encode code)
      (loop for variant below 2 for expected in '((2 0 0 1 0) (2 0 1 1 1 0)) do
        (let ((offset (mognitio.object:image-symbol-offset (gethash (list :descriptor 0 variant) labels))))
          (same expected (loop for n below (length expected) collect (image-integer bytes (+ offset (* n 8)) 8))))))))

(deftest v08-result-private-abi
  ;; A handwritten caller checks argument slots, one-word Result return,
  ;; payload/tag/header offsets, stack restoration and runtime register R15.
  (let ((source "let forward:function(Result<int,string>):Result<int,string> =function(r:Result<int,string>):Result<int,string>{Result<int,string>::Ok(try r)};let r:Result<int,string> =Result<int,string>::Ok(42);true"))
    (multiple-value-bind (out err code)
        (v05-cross-abi source 0
          (append '((:label (:function 0)) (:push-rbp) (:mov-reg :rbp :rsp))
            (loop repeat 12 collect '(:push-zero))
            '((:store-frame -8 :r15) (:store-frame -16 :rsp)
              (:imm-rax 42) (:store-out 0 :rax) (:call (:helper (:enum.make (:enum 0) 0)))
              (:store-out 0 :rax) (:call (:function 1))
              (:load-word :rcx :rax 24) (:cmp-imm :rcx 0) (:jnz :bad)
              (:load-word :rcx :rax 32) (:cmp-imm :rcx 42) (:jnz :bad)
              (:load-word :rcx :rax 16) (:lea-meta (:descriptor 0 0)) (:cmp) (:jnz :bad)
              (:mov-reg :rax :r15) (:load-frame :rcx -8) (:cmp) (:jnz :bad)
              (:mov-reg :rax :rsp) (:load-frame :rcx -16) (:cmp) (:jnz :bad)
              (:load-word :rax :r15 0) (:test) (:jnz :bad)
              (:imm-rax 1) (:mov-reg :rsp :rbp) (:pop-rbp) (:ret)) (v06-abi-bad)))
      (same 0 code) (same (format nil "true~%") out) (same "" err))))
