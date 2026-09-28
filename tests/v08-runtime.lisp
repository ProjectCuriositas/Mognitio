(in-package #:mognitio.tests)

(deftest v08-panic-terminal-roots-and-frame
  ;; A message whose only later use is the panic terminator must survive an
  ;; intervening allocation. The unrelated result must not become a root.
  (let* ((module (mognitio.ir:make-module :literal-pool (v06-test-pool) :functions
                   (list (mognitio.ir:make-ir-function :id 0 :entry 0 :result-type :bool :blocks
                     (list (mognitio.ir:make-basic-block :id 0 :instructions
                       (list (v06-i 0 :string :const.text :value 1)
                             (v06-i 1 :string :text.concat :operands '(0 0))
                             (v06-i 2 :string :text.concat :operands '(0 0))) :terminator '(:panic 1)))))))
         (plans (mognitio.roots:analyze-roots module)))
    (same '((0 2 ((0 1 (0)) (0 2 (0 1))))) (v06-root-snapshot plans))
    (setf (mognitio.roots:root-site-values (second (mognitio.roots:root-plan-sites (first plans)))) '(0))
    (signals internal-failure (mognitio.roots:verify-roots module plans)))
  (dolist (mutation '(:slot :callee :return :missing :arity))
    (destructuring-bind (function allocation roots layout sections body) (first (v06-frame-capture "panic {\"stop\"}"))
      (let* ((section (find :panic sections :key #'first)) (forms (copy-tree (third section))))
        (same 1 (mognitio.frame:layout-arity layout))
        (ecase mutation
          (:slot (setf (second (second forms)) 8))
          (:callee (setf (second (third forms)) '(:helper :text.length)))
          (:return (setf (fourth forms) '(:ret)))
          (:missing (setf sections (remove section sections)))
          (:arity (setf (mognitio.frame:layout-arity layout) 0)))
        (setf (third section) forms) (replace body forms :start1 (fourth section))
        (signals internal-failure (mognitio.frame:verify-sections function allocation roots layout sections body)))))
  (let* ((unit (mognitio.native.runtime::panic-helper-unit))
         (forms (mapcar (lambda (i) (cons (mognitio.machine:instruction-opcode i) (mognitio.machine:instruction-operands i)))
                        (mognitio.object:code-unit-instructions unit))))
    (is (notany (lambda (f) (member (first f) '(:call :ret))) forms))))

(deftest v08-panic-runtime-write-faults
  (dolist (message '("" "stop" "Aあ😀\\0\\nZ"))
    (let* ((source (format nil "panic {~S}" message)) (artifact (build-text source))
           (input (put-text (fresh-path) source)))
      (dolist (mode '("partial-eintr" "zero" "error" "eintr-budget"))
        (multiple-value-bind (out err code)
            (process-result (list "python3" (namestring (root-path "tests/runtime-syscalls.py"))
                                  (namestring artifact) mode (if (string= message "") "panic-empty" "panic")))
          (same 4 code) (same "" out)
          (same (if (string= mode "partial-eintr") (format nil "runtime: panic: ~A~%" message) "") err)))
      ;; Exercise the host's pinned byte writer with actual fd streams; no
      ;; pretty-printer is used as the byte oracle.
      (dolist (mode '(:partial :zero :error :eintr :storage))
        (let ((calls 0) (bytes nil) (out (make-string-output-stream)))
          (with-open-file (fd (fresh-path ".stderr") :direction :output :if-exists :supersede)
            (replacing (mognitio.runtime::write-chunk
                         (lambda (descriptor data offset count)
                           (declare (ignore descriptor)) (incf calls)
                           (ecase mode
                             (:zero 0) (:error -5) (:eintr -4) (:storage (error 'storage-condition))
                             (:partial (if (oddp calls) -4
                                           (let ((size (min 2 count)))
                                             (loop for index from offset below (+ offset size) do (push (aref data index) bytes)) size))))))
              (same 4 (mognitio.driver:run-cli (list "run" (namestring input)) out fd))))
          (same "" (get-output-stream-string out))
          (if (eq mode :partial)
              (same (sb-ext:string-to-octets (format nil "runtime: panic: ~A~%" message) :external-format :utf-8)
                    (coerce (nreverse bytes) '(vector (unsigned-byte 8))))
              (progn (same nil bytes) (same (if (eq mode :eintr) 16 1) calls))))))))

(deftest v08-try-and-panic-lifetime
  (v07-accept "type Box<T> =struct{value:T;};let leaf:function():Result<int,Box<string>> =function():Result<int,Box<string>>{Result<int,Box<string>>::Err(Box<string>{value:\"keep\"+\"!\"})};let middle:function():Result<string,Box<string>> =function():Result<string,Box<string>>{let n:int=try leaf();Result<string,Box<string>>::Ok(\"unreachable\")};let outer:function():Result<bool,Box<string>> =function():Result<bool,Box<string>>{let s:string=try middle();Result<bool,Box<string>>::Ok(false)};let payload:Box<string> =branch on(outer()){Result<bool,Box<string>>::Ok(ignoredPayload1)=>Box<string>{value:\"bad\"},Result<bool,Box<string>>::Err(e)=>e};var i:int=0;loop while(i<2000){let dead:Box<string> =Box<string>{value:\"dead\"+\"!\"};i=i+1;};payload->value==\"keep!\"")
  (v08-failure "panic {let message:string=\"keep\"+\"!\";var i:int=0;loop while(i<2000){let dead:Result<string,int> =Result<string,int>::Ok(\"dead\"+\"!\");i=i+1;};message}" "panic: keep!")
  (let ((calls 0) (original (fdefinition 'mognitio.runtime::raise-panic)))
    (replacing (mognitio.runtime::raise-panic (lambda (message) (incf calls) (funcall original message)))
      (same :true (compiled-result "let f:function():bool=function():bool{panic {return true;}};f()"))
      (same 0 calls)
      (let ((input (put-text (fresh-path) "panic {panic {\"inner\"}}")))
        (multiple-value-bind (out err code) (driver-result (list "run" (namestring input)))
          (same 4 code) (same "" out) (same (format nil "runtime: panic: inner~%") err)))
      (same 1 calls))))

(deftest v08-error-artifact-and-build
  (let ((source "panic {\"build must not evaluate\"}"))
    (replacing (mognitio.runtime::raise-panic (lambda (&rest args) (declare (ignore args)) (error "Source evaluated during build")))
      (same (native-image source) (native-image source)))
    (let* ((artifact (build-text source)) (before (read-bytes artifact))
           (invalid (put-text (fresh-path) "panic {42}")))
      (expect-driver (build-args invalid artifact) 1 "semantic:")
      (same before (read-bytes artifact))
      (same nil (temporary-images))))
  (check-native-relocation "let f:function():Result<int,string> =function():Result<int,string>{Result<int,string>::Ok(42)};branch on(f()){Result<int,string>::Ok(n)=>n==42,Result<int,string>::Err(ignoredPayload2)=>false}" :true))
