(in-package #:mognitio.testing)

(defstruct test-output stream failed
  (pending (make-array 4 :element-type '(unsigned-byte 8))) (used 0) (needed 0))
(defun output-bytes (output bytes count)
  (when (test-output-failed output) (runner-io "Test report stream is unavailable"))
  (handler-case
      (let ((stream (test-output-stream output)))
        (cond
          ((typep stream 'sb-sys:fd-stream)
           (finish-output stream)
           (let ((offset 0) (retries 0) (fd (sb-sys:fd-stream-fd stream)))
             (loop while (< offset count) do
               (let ((n (mognitio.runtime::write-chunk fd bytes offset (- count offset))))
                 (cond ((plusp n) (incf offset n) (setf retries 0))
                       ((and (= n (- sb-posix:eintr)) (< (incf retries) 16)))
                       (t (runner-io "Cannot write test report")))))))
          ((subtypep (stream-element-type stream) '(unsigned-byte 8)) (write-sequence bytes stream :end count))
          (t
           ;; In-memory character adapters retain at most one partial UTF-8 scalar.
           (dotimes (i count)
             (let ((b (aref bytes i)))
               (when (zerop (test-output-used output))
                 (setf (test-output-needed output) (cond ((< b 128) 1) ((< b 224) 2) ((< b 240) 3) (t 4))))
               (setf (aref (test-output-pending output) (test-output-used output)) b)
               (when (= (incf (test-output-used output)) (test-output-needed output))
                 (write-string (sb-ext:octets-to-string (test-output-pending output)
                                :end (test-output-used output) :external-format :utf-8) stream)
                 (setf (test-output-used output) 0))))))
        (finish-output stream))
    (error () (setf (test-output-failed output) t) (runner-io "Cannot write test report"))))
(defun output-text (output text)
  (let ((bytes (sb-ext:string-to-octets text :external-format :utf-8))) (output-bytes output bytes (length bytes))))
(defun stage-name (stage) (case stage (1 "initialization") (2 "body") (otherwise "unknown")))
(defun result-line (test output)
  (unless (test-case-reported test)
    (output-text output
      (format nil "~A~A ~A~%"
        (ecase (test-case-state test) (:passed "PASS") (:failed "FAIL") (:errors "ERROR") (:aborted "ABORTED"))
        (if (test-case-kind test) (format nil " ~A" (string-downcase (symbol-name (test-case-kind test)))) "")
        (one-line (test-case-identity test))))
    (setf (test-case-reported test) t)))
(defun test-context (test output)
  (unless (eq (test-case-state test) :passed)
    (output-text output
      (with-output-to-string (s)
        (render-diagnostic
          (mognitio.source:span-diagnostic (test-case-span test) :test
            (format nil "~A; kind=~A; stage=~A" (test-case-identity test)
                    (or (test-case-kind test) (test-case-state test)) (stage-name (test-case-stage test)))) s)))))
(defun summary-line (cases output)
  (let ((states (loop for test across cases collect (test-case-state test))))
    (when (member :running states) (internal-error "Unresolved test in summary"))
    (output-text output (format nil "tests: total=~D passed=~D failed=~D errors=~D aborted=~D not_run=~D~%"
      (length cases) (count :passed states) (count :failed states) (count :errors states)
      (count :aborted states) (count :not-run states)))))
