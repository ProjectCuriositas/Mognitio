(in-package #:mognitio.tests)

(define-condition v11-injected-storage (storage-condition) ())

(deftest v011-parent-storage-recovery
  ;; A recoverable host condition, not an actual process-wide memory exhaustion.
  (dolist (phase '(:suite-prepared :before-spawn :body :before-summary))
    (let ((attempt nil) (before (v11-fd-snapshot)) (fired nil))
      (multiple-value-bind (out err code)
          (v11-driver (v11-manifest (if (eq phase :body) "var i:Int=0;loop while(i==0){unit};" "unit"))
            (lambda (point object)
              (when (eq point :before-spawn) (setf attempt object))
              (when (and (not fired)
                         (or (eq point phase)
                             (and (eq phase :body) (eq point :draining)
                                  (= 2 (mognitio.testing::test-case-stage object)))))
                (setf fired t) (error 'v11-injected-storage))))
        (is fired) (when attempt (v11-assert-released attempt)) (same before (v11-fd-snapshot))
        (same 3 code)
        (ecase phase
          ((:suite-prepared :before-spawn) (same "" out) (is (not (search "tests:" err))))
          (:body
           (is (search "total=2 passed=0 failed=0 errors=0 aborted=1 not_run=1" out))
           (is (search "src/app.mgn::App::check0" err)) (is (search "stage=body" err)))
          (:before-summary (is (search "total=2 passed=2 failed=0 errors=0 aborted=0 not_run=0" out))))
        (is (search "storage failure" err)))))
  ;; Native program allocation failure remains a test error and continues the suite.
  (let ((mognitio.native.runtime::*test-options* '(:fail-allocation 1)))
    (multiple-value-bind (out err code) (v11-driver (v11-manifest "discard List<Int>[1];"))
      (same 4 code) (is (search "total=2 passed=0 failed=0 errors=2 aborted=0 not_run=0" out))
      (is (search "allocation-failed" out)) (is (not (search "storage failure" err))))))

(deftest v011-storage-during-cleanup
  (dolist (prior '(nil t))
    (let ((residual nil) (paths nil)
          (before (v11-fd-snapshot)))
      (unwind-protect
           (replacing (mognitio.testing::raw-rmdir
             (lambda (pointer) (declare (ignore pointer)) (error 'v11-injected-storage)))
             (multiple-value-bind (out err code)
                 (v11-driver (v11-manifest) (lambda (point object)
                   (when (eq point :image-created) (push (mognitio.testing::test-case-path object) paths))
                   (when (eq point :suite-prepared)
                     (setf residual (mognitio.testing::preparation-session-directory object))
                     (when prior (mognitio.testing::runner-io "Primary preparation I/O failure")))))
               (same (if prior 2 3) code)
               (if prior (same "" out) (is (search "passed=2 failed=0 errors=0 aborted=0 not_run=0" out)))
               (is (search "storage failure" err)) (is (search "cleanup incomplete:" err))
               (when prior (is (search "Primary preparation I/O failure" err)))
               (same 2 (length paths))
               (dolist (path paths) (is (not (probe-file path))))
               (is (probe-file residual)))
             (same before (v11-fd-snapshot)))
        (when residual
          (sb-posix:rmdir residual))))))

(deftest v011-helper-destination-preservation
  (let ((mognitio.native.runtime::*runtime-module* (mognitio.ir:make-module :test-ordinal 0)))
    (dolist (form '((:mov-reg :rsi :rax) (:load-frame :rsi -48) (:load-word :rsi :r15 240)
                    (:lea-base :rsi :rbp -40) (:add-imm :rsi 1) (:add-reg :rsi :rax)))
      (dolist (destination '(:rbp :rsp :rbx :r12 :r13 :r14 :r15))
        (let* ((unit (first (mognitio.native.runtime::test-helper-units)))
               (instruction (find :load-frame (mognitio.object:code-unit-instructions unit)
                                  :key #'mognitio.machine:instruction-opcode)))
          (mognitio.native.runtime::verify-returning-test-helper unit)
          (setf (mognitio.machine:instruction-opcode instruction) (first form)
                (mognitio.machine:instruction-operands instruction) (copy-list (rest form)))
          ;; Caller-save destinations are a positive control for each allowed opcode.
          (mognitio.native.runtime::verify-returning-test-helper unit)
          (setf (first (mognitio.machine:instruction-operands instruction)) destination)
          (signals internal-failure (mognitio.native.runtime::verify-returning-test-helper unit)))))
    (dolist (form '((:push-zero) (:push-rbp) (:pop-rbp) (:ret) (:imm-reg :rsp 0)))
      (let* ((unit (first (mognitio.native.runtime::test-helper-units)))
             (instruction (find :load-frame (mognitio.object:code-unit-instructions unit)
                                :key #'mognitio.machine:instruction-opcode)))
        (setf (mognitio.machine:instruction-opcode instruction) (first form)
              (mognitio.machine:instruction-operands instruction) (rest form))
        (signals internal-failure (mognitio.native.runtime::verify-returning-test-helper unit))))))

(defun v11-occurrences (needle text)
  (loop for position = (search needle text) then (search needle text :start2 (+ position (length needle)))
        while position count t))

(deftest v011-committed-context-recovery
  ;; A separate helper location must survive commit-before-output interruption.
  (dolist (failure '(:assertion :panic :arithmetic))
    (dolist (point '(:result-committed :before-result-output nil))
      (let* ((manifest (project-fixture
              (list (cons "helper.mgn"
                          (format nil "namespace App;~%public let fail:Function():Unit=function():Unit{~%~A~%};"
                            (ecase failure (:assertion "assert false;") (:panic "panic{\"payload\"}")
                                           (:arithmetic "discard 1/0;"))))
                    (cons "app.mgn" "namespace App;use App\\{fail};@test let first:Function():Unit=function():Unit{fail();};@test let next:Function():Unit=function():Unit{unit};"))))
             (handles nil) (cases nil) (before (v11-fd-snapshot)) (fired nil))
        (multiple-value-bind (out err code)
            (v11-driver manifest (lambda (event object)
              (when (eq event :before-spawn) (push object handles))
              (when (eq event :result-committed) (push object cases))
              (when (and point (eq event point) (not fired))
                (setf fired t) (internal-error "Injected after result commit"))))
          (mapc #'v11-assert-released handles) (same before (v11-fd-snapshot))
          (same (if point 3 (if (eq failure :assertion) 5 4)) code)
          (is (search (if (eq failure :assertion) "failed=1 errors=0" "failed=0 errors=1") out))
          (is (search (if point "aborted=0 not_run=1" "aborted=0 not_run=0") out))
          (same 1 (v11-occurrences "src/app.mgn::App::first; kind=" err))
          (is (search "stage=body" err))
          (when (eq failure :assertion)
            ;; Literal source position, independent of compiler span reconstruction.
            (same 1 (v11-occurrences "src/helper.mgn:3:1: assertion:" err))
            (is (search "[bytes 64,77)" err)))
          ;; Calling the recovery reporter again must be a no-op.
          (dolist (test cases)
            (let ((s (make-string-output-stream)))
              (mognitio.testing::test-context test (mognitio.testing::make-test-output :stream s))
              (same "" (get-output-stream-string s)))))))))
