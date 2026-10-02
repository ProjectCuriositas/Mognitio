(in-package #:mognitio.testing)

(defvar *runner-secondary* nil)

(defun sync-start (attempt test)
  (when (and (attempt-resources-execution-delegated attempt) (eq (test-case-state test) :not-run))
    (setf (test-case-state test) :running)))

(defun classify-child-command (attempt reader test)
  (when (and (eq (attempt-resources-process-state attempt) :reaped) (event-reader-eof reader))
    (let ((status (attempt-resources-status attempt)))
      (when (zerop (logand status 127))
        (case (ash status -8)
          (#.+internal-child-status+
           (let ((message (if (event-reader-terminal reader)
                              "Native internal failure contradicts a terminal event"
                              "Native child detected an internal runtime inconsistency")))
             (internal-error (if (eq (test-case-state test) :not-run)
                                 (format nil "~A; ~A; stage=~A" message (test-case-identity test)
                                         (stage-name (event-reader-stage reader))) message))))
          (#.+transport-child-status+ (runner-io "Test report transport failed")))))))

(defun commit-result (attempt reader test)
  (classify-child-command attempt reader test)
  (when (and (eq (attempt-resources-process-state attempt) :reaped)
             (event-reader-eof reader) (eq (test-case-state test) :running))
    (let* ((status (attempt-resources-status attempt)) (signal (logand status 127))
           (code (ash status -8)) (terminal (event-reader-terminal reader)))
      (cond
        ((and (zerop signal) (= code 124)) (runner-io "Test report transport failed"))
        ((or (plusp signal) (null terminal) (plusp (event-reader-used reader)))
         (setf (test-case-state test) :errors (test-case-kind test) :abnormal))
        (t
         (let* ((kind (car terminal)) (expected (case kind (0 0) (1 5) (otherwise 4))))
           (unless (= code expected) (internal-error "Test terminal disagrees with process status"))
           (when (= kind 1)
             (setf (test-case-assertion-site test) (aref (test-case-sites test) (cdr terminal))))
           (setf (test-case-kind test) (car (rassoc kind *event-kinds*))
                 (test-case-state test) (case kind (0 :passed) (1 :failed) (otherwise :errors)))
         (when (eq (test-case-state test) :passed) (setf (test-case-kind test) nil)))))
      (runner-hook :result-committed test))))

(defun wait-readiness (attempt reader)
  (sb-alien:with-alien ((polls (array sb-alien:unsigned-char 40)))
    (let ((sap (sb-alien:alien-sap (sb-alien:addr polls))))
      (loop for index in '(4 0 2 8 7) for offset from 0 by 8 do
        (setf (sb-sys:sap-ref-32 sap offset)
              (logand #xffffffff (if (and (= index 7) (or (not (event-reader-ready reader))
                                                         (attempt-resources-execution-delegated attempt)))
                                    -1 (aref (attempt-resources-fds attempt) index)))
              (sb-sys:sap-ref-16 sap (+ offset 4)) (if (= index 7) 4 1)
              (sb-sys:sap-ref-16 sap (+ offset 6)) 0))
      (when (minusp (raw-poll sap 5 20))
        (unless (= (sb-sys:sap-ref-32 (errno-pointer) 0) sb-posix:eintr)
          (runner-io "Cannot wait for test output"))))))

(defun drain-attempt (attempt reader test stderr)
  (let ((buffer (make-array 4096 :element-type '(unsigned-byte 8)))
        (application (make-array 4096 :element-type '(unsigned-byte 8))) (ep (errno-pointer)))
    (labels ((read-channel (index bytes)
               (let ((fd (aref (attempt-resources-fds attempt) index)))
                 (when (< fd 0) (return-from read-channel nil))
                 (let ((count 0) (errno 0))
                   (sb-sys:with-pinned-objects (bytes)
                     (setf count (raw-read fd (sb-sys:vector-sap bytes) (length bytes)))
                     (when (minusp count) (setf errno (sb-sys:sap-ref-32 ep 0))))
                   (cond ((plusp count) count)
                         ((zerop count)
                          (when (= index 4) (setf (event-reader-eof reader) t))
                          (close-owned-fd attempt index) (commit-result attempt reader test) nil)
                         ((member errno (list sb-posix:eintr sb-posix:eagain)) nil)
                         (t (runner-io "Cannot read test output"))))))
             (applications ()
               (dolist (index '(0 2))
                 (loop for count = (read-channel index application) while count do
                   (output-application test (if (zerop index) "stdout" "stderr") stderr application count)))))
      (loop
        ;; Commit independently of presentation; later capture/report errors
        ;; retain an already determined result.
        (collect-wait attempt) (commit-result attempt reader test)
        (let ((count (read-channel 4 buffer)))
          (when count
            (feed-events reader buffer count) (setf (test-case-stage test) (event-reader-stage reader))
            (when (and (plusp (event-reader-stage reader)) (not (attempt-resources-execution-delegated attempt)))
              (internal-error "Test ran before execution was delegated"))))
        (applications)
        (let ((count (read-channel 8 buffer)))
          (when count
            ;; Bytes written before a terminal diagnostic can have arrived after
            ;; the first drain. Re-drain them after observing diagnostic data,
            ;; without waiting for EOF (which could deadlock a full pipe).
            (applications) (output-bytes stderr buffer count)))
        (when (and (event-reader-ready reader) (not (attempt-resources-execution-delegated attempt))
                   (not (eq (attempt-resources-process-state attempt) :reaped)) (not (event-reader-eof reader)))
          (runner-hook :before-delegation attempt)
          (when (delegate-start attempt) (sync-start attempt test) (close-owned-fd attempt 7)))
        (when (and (eq (attempt-resources-process-state attempt) :reaped) (event-reader-eof reader)
                   (not (attempt-resources-execution-delegated attempt)))
          (runner-io "Test image exited before execution started"))
        (when (and (eq (attempt-resources-process-state attempt) :reaped)
                   (every (lambda (i) (= -1 (aref (attempt-resources-fds attempt) i))) '(0 2 4 8)))
          (commit-result attempt reader test) (return))
        (runner-hook :draining test) (wait-readiness attempt reader)))))

(defun run-attempt (test stderr)
  (let ((attempt (make-attempt-resources))
        (reader (make-event-reader :ordinal (test-case-ordinal test) :site-count (length (test-case-sites test))))
        (primary nil))
    (unwind-protect
         (handler-case (progn (spawn-attempt attempt (test-case-path test))
                              (drain-attempt attempt reader test stderr))
           ((or error storage-condition) (c) (setf primary c)))
      (setf (test-case-stage test) (event-reader-stage reader))
      (sync-start attempt test)
      (handler-case (finalize-attempt attempt)
        ((or error storage-condition) (c) (if primary (push c *runner-secondary*) (setf primary c))))
      (when (and primary (eq (test-case-state test) :running)) (setf (test-case-state test) :aborted)))
    (when primary (error primary))))

(defun command-code (condition)
  (typecase condition (source-failure 1) (usage-or-io-failure 2)
    ((or sb-posix:syscall-error file-error stream-error) 2) (t 3)))
(defun report-command (condition stderr)
  (unless (test-output-failed stderr)
    (output-text stderr (with-output-to-string (s)
      (render-diagnostic
        (if (typep condition 'compiler-failure) (failure-diagnostic condition)
            (make-diagnostic :phase (if (= (command-code condition) 3) :internal :io)
                             :message (cond ((typep condition 'storage-condition) "Test runner storage failure")
                                            ((= (command-code condition) 3) "Test runner failed")
                                            (t "Test runner I/O failed")))) s)))))
(defun suite-exit (cases)
  (cond ((find :abnormal cases :key #'test-case-kind) 6)
        ((find :errors cases :key #'test-case-state) 4)
        ((find :failed cases :key #'test-case-state) 5) (t 0)))

(defun %run-tests (manifest stdout-stream stderr-stream)
  (let* ((stdout (make-test-output :stream stdout-stream)) (stderr (make-test-output :stream stderr-stream))
         (plan nil) (session nil) (primary nil) (cleanup nil) (*runner-secondary* nil))
    (unwind-protect
         (handler-case
             (progn
               (setf plan (make-checked-test-plan manifest)
                     session (make-preparation-session :cases (test-plan-cases plan)))
               (prepare-suite session plan)
               (runner-hook :runner-entered session)
               (loop for test across (test-plan-cases plan) do
                 (run-attempt test stderr)
                 (test-context test stderr)
                 (runner-hook :before-result-output test)
                 (result-line test stdout)))
           ((or error storage-condition) (c) (setf primary c)))
      (when session
        (handler-case
            (multiple-value-bind (paths failure) (cleanup-preparation session)
              (setf cleanup paths)
              (when failure (if primary (push failure *runner-secondary*) (setf primary failure))))
          ((or error storage-condition) (c) (if primary (push c *runner-secondary*) (setf primary c))))))
    (when cleanup
      (unless primary
        (setf primary (make-condition 'usage-or-io-failure :diagnostic
                       (make-diagnostic :message "Cannot remove test temporary resources")))))
    (flet ((report (thunk)
             (handler-case (funcall thunk) ((or error storage-condition) (c) (unless primary (setf primary c))))))
      (when primary (report (lambda () (report-command primary stderr))))
      (dolist (condition (reverse *runner-secondary*))
        (report (lambda () (output-text stderr (format nil "mgn: cleanup also failed; recovery may be incomplete~%"))
                           (report-command condition stderr))))
      (dolist (path cleanup)
        (report (lambda () (output-text stderr (format nil "mgn: cleanup incomplete: ~A~%" (one-line path))))))
      (when (and plan (or (null primary) (find-if (lambda (test) (not (eq (test-case-state test) :not-run))) (test-plan-cases plan))))
        (loop for test across (test-plan-cases plan) unless (eq (test-case-state test) :not-run) do
          (unless (test-output-failed stderr) (report (lambda () (test-context test stderr))))
          (unless (test-output-failed stdout) (report (lambda () (result-line test stdout)))))
        (let ((before primary))
          (report (lambda () (runner-hook :before-summary plan)))
          (report (lambda () (summary-line (test-plan-cases plan) stdout)))
          (when (and (null before) primary) (report (lambda () (report-command primary stderr)))))))
    (if primary (command-code primary) (suite-exit (test-plan-cases plan)))))

(defun run-tests (manifest stdout stderr)
  (mognitio.io::call-with-io-signals
    (lambda () (let ((code (%run-tests manifest stdout stderr))) (values code (member code '(1 2 3)))))))
