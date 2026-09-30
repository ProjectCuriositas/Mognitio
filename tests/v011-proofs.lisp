(in-package #:mognitio.tests)

(defun v11-manifest (&optional (body "assert true;") (count 2))
  (project-fixture (list (cons "app.mgn"
    (format nil "namespace App;~{~A~}" (loop for n below count collect
      (format nil "@test let check~D:Function():Unit=function():Unit{~A};" n body)))))))
(defun v11-plan (manifest) (mognitio.testing::make-checked-test-plan (namestring manifest)))
(defun v11-driver (manifest &optional hook)
  (let ((out (make-string-output-stream)) (err (make-string-output-stream))
        (mognitio.testing::*runner-hook* hook))
    (let ((code (mognitio.driver:run-cli (list "test" (namestring manifest)) out err)))
      (values (get-output-stream-string out) (get-output-stream-string err) code))))

(deftest v011-attribute-and-plan-proofs
  (dolist (mutation '(:missing :extra :identity :syntax))
    (let* ((plan (v11-plan (v11-manifest))) (checked (mognitio.testing::test-plan-checked plan))
           (table (mognitio.semantic::checked-program-attributes checked))
           (key (loop for k being the hash-keys of table return k)) (proof (gethash key table)))
      (ecase mutation
        (:missing (remhash key table))
        (:extra (setf (gethash (mognitio.syntax::copy-local-binding key) table) proof))
        (:identity (setf (mognitio.semantic::checked-attribute-declaration proof) nil))
        (:syntax (setf (mognitio.semantic::checked-attribute-syntax proof) nil)))
      (signals internal-failure (verify-checked-program checked))))
  (dolist (mutation '(:order :name :ordinal :missing :duplicate :span))
    (let* ((plan (v11-plan (v11-manifest))) (cases (mognitio.testing::test-plan-cases plan)) (test (aref cases 0)))
      (ecase mutation
        (:order (rotatef (aref cases 0) (aref cases 1)))
        (:name (setf (mognitio.testing::test-case-identity test) "forged"))
        (:ordinal (setf (mognitio.testing::test-case-ordinal test) 4))
        (:missing (setf (mognitio.testing::test-plan-cases plan) (subseq cases 0 1)))
        (:duplicate (setf (aref cases 1) test))
        (:span (setf (mognitio.testing::test-case-span test) nil)))
      (signals internal-failure (mognitio.testing::verify-test-plan plan))))
  (dolist (mutation '(:marker :callee :initializers :prefix))
    (let* ((plan (v11-plan (v11-manifest))) (project (mognitio.testing::test-plan-project plan))
           (test (aref (mognitio.testing::test-plan-cases plan) 0))
           (program (mognitio.project::project-program project (mognitio.testing::test-case-declaration test)))
           (checked (check-program program)) (root (program-root program)))
      (ecase mutation
        (:marker (setf (aref (sequence-node-statements root) 0) (make-void-literal :span (node-span root))))
        (:callee (setf (checked-program-program checked) (mognitio.semantic::rebuild-syntax-node program (list (cons 'mognitio.syntax::root (sequence-node-terminal root))))))
        (:initializers (setf (checked-program-program checked) (mognitio.semantic::rebuild-syntax-node program (list (cons 'mognitio.syntax::statements #())))))
        (:prefix (setf (mognitio.project::module-declaration-attributes (mognitio.testing::test-case-declaration test)) #())))
      (signals internal-failure (verify-checked-program checked)))))

(defun v11-pressure-function (&optional marker)
  (let* ((span (make-span (text-source "true") 0 4))
         (instructions (loop for n below 4 collect
           (mognitio.ir:make-instruction :result n :type :int :op :constant :value (+ n 10) :span span))))
    (when marker (setf instructions (append instructions
      (list (mognitio.ir:make-instruction :result 4 :type :void :op :test.stage :span span)))))
    (setf instructions (append instructions
      (list (mognitio.ir:make-instruction :result 5 :type :int :op :add :operands '(0 1) :span span)
            (mognitio.ir:make-instruction :result 6 :type :int :op :add :operands '(2 3) :span span)
            (mognitio.ir:make-instruction :result 7 :type :int :op :add :operands '(5 6) :span span))))
    (mognitio.ir:make-ir-function :id 0 :result-type :int :entry 0 :span span
      :blocks (list (mognitio.ir:make-basic-block :id 0 :span span :instructions instructions :terminator '(:return 7))))))

(deftest v011-stage-register-proof
  ;; D11-R01/R02: four simultaneous scalar homes force R11 in the negative control.
  (let* ((plain (mognitio.regalloc:allocate-function (v11-pressure-function)))
         (function (v11-pressure-function t)) (allocation (mognitio.regalloc:allocate-function function))
         (homes (mognitio.regalloc:allocation-locations allocation)))
    (is (loop for n below 4 thereis (eq :r11 (gethash n (mognitio.regalloc:allocation-locations plain)))))
    (dotimes (n 4) (is (integerp (gethash n homes))))
    (same '(:may-fail :call-barrier) (mognitio.ir::operation-effects :test.stage))
    (setf (mognitio.regalloc::allocation-barriers allocation) nil)
    (setf (gethash 3 homes) :r11)
    (signals internal-failure (mognitio.regalloc:verify-allocation allocation)))
  (let ((mognitio.native.runtime::*runtime-module* (mognitio.ir:make-module :test-ordinal 0)))
    (dolist (mutation '(:clobber :frame :allocation))
      (let* ((units (mognitio.native.runtime::test-helper-units)) (unit (third units))
             (body (mognitio.object:code-unit-instructions unit)))
        (mognitio.native.runtime::verify-returning-test-helper unit)
        (ecase mutation
          (:clobber (setf (mognitio.machine:instruction-opcode (nth 3 body)) :mov-reg
                          (mognitio.machine:instruction-operands (nth 3 body)) '(:r11 :rax))
                    ;; R11 is allowed; a callee-save modification is not.
                    (mognitio.native.runtime::verify-returning-test-helper unit)
                    (setf (mognitio.machine:instruction-operands (nth 3 body)) '(:r15 :rax)))
          (:frame (setf (mognitio.machine:instruction-operands (nth (- (length body) 3) body)) '(:rsp :rax)))
          (:allocation (setf (mognitio.machine:instruction-operands (find :call body :key #'mognitio.machine:instruction-opcode)) '((:runtime :allocate)))))
        (signals internal-failure (mognitio.native.runtime::verify-returning-test-helper unit))))))

(deftest v011-native-stage-pressure
  (let* ((function (v11-pressure-function t)) (block (first (mognitio.ir:ir-function-blocks function)))
         (span (mognitio.ir:basic-block-span block))
         (test (mognitio.testing::make-test-case :ordinal 0 :span span :sites (vector span)
                 :identity "pressure" :path (namestring (fresh-path ".elf")))))
    (setf (mognitio.ir:ir-function-result-type function) :void
          (mognitio.ir:basic-block-instructions block)
          (append (mognitio.ir:basic-block-instructions block)
            (list (mognitio.ir:make-instruction :result 8 :type :int :op :constant :value 46 :span span)
                  (mognitio.ir:make-instruction :result 9 :type :bool :op :eq :operands '(7 8) :span span)))
          (mognitio.ir:basic-block-terminator block) '(:branch 9 1 2)
          (mognitio.ir:ir-function-blocks function)
          (list block (mognitio.ir:make-basic-block :id 1 :span span :terminator '(:return 10)
                        :instructions (list (mognitio.ir:make-instruction :result 10 :type :void :op :constant :value 0 :span span)))
                      (mognitio.ir:make-basic-block :id 2 :span span :terminator '(:assert-fail 0))))
    (let ((module (mognitio.ir:make-module :test-ordinal 0 :assertion-sites (vector span) :span span :functions (list function))))
      (multiple-value-bind (bytes symbols) (mognitio.amd64:encode (mognitio.machine:lower-module module))
        (mognitio.backend.native::verify-native-metadata module bytes symbols)
        (put-bytes (test-case-pathname test) (mognitio.elf:make-image bytes))))
    (sb-posix:chmod (mognitio.testing::test-case-path test) #o700)
    (let ((stream (make-string-output-stream)))
      (mognitio.testing::run-attempt test (mognitio.testing::make-test-output :stream stream))
      (same :passed (mognitio.testing::test-case-state test)) (same "" (get-output-stream-string stream)))))

(defun test-case-pathname (test) (pathname (mognitio.testing::test-case-path test)))

(deftest v011-template-assertions-and-lifetime
  (let ((manifest (project-fixture
    '(("app.mgn" . "namespace App;template make<T>=function(value:T):Function():Unit{function():Unit{assert true;}};@test let check:Function():Unit=make<Int>(42);let main:Function():Unit=check;")))))
    (expect-project manifest '(:stress t :validate t))
    (multiple-value-bind (out err code) (v11-driver manifest)
      (same 0 code) (same "" err) (is (search "passed=1" out))))
  (let* ((source "namespace App;let make:Function(String):Function():Unit=function(s:String):Function():Unit{function():Unit{assert s==\"kept!\";}};@test let check:Function():Unit=make(\"kept\"+\"!\");let garbage:Unit={var i:Int=0;loop while(i<1200){discard List<String>[\"dead\"+\"!\"];i=i+1;};};")
         (manifest (project-fixture (list (cons "app.mgn" source))))
         (mognitio.native.runtime::*test-options* '(:stress t :validate t :arena-unit 4096 :cap 4096)))
    (multiple-value-bind (out err code) (v11-driver manifest)
      (same 0 code) (same "" err) (is (search "passed=1" out)))))
