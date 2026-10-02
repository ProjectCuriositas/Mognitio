(in-package #:mognitio.tests)

(defclass v12-failing-diagnostic (sb-gray:fundamental-character-output-stream)
  ((mode :initarg :mode :reader v12-diagnostic-mode)))
(defmethod sb-gray:stream-write-char ((stream v12-failing-diagnostic) char)
  (when (eq (v12-diagnostic-mode stream) :write) (error "Diagnostic write failure"))
  (when (eq (v12-diagnostic-mode stream) :storage) (error 'storage-condition))
  char)
(defmethod sb-gray:stream-finish-output ((stream v12-failing-diagnostic))
  (when (eq (v12-diagnostic-mode stream) :flush) (error "Diagnostic flush failure")))

(deftest v012-startup-diagnostic-preserves-primary
  (let ((manifest (v12-manifest "0")))
    (dolist (mode '(:write :flush :storage))
      (let ((out (make-string-output-stream))
            (err (make-instance 'v12-failing-diagnostic :mode mode))
            (bad (make-array 1 :element-type '(unsigned-byte 8) :initial-element 255)))
        (same 2 (mognitio.driver:run-cli (list "run" (namestring manifest) "--" bad) out err))
        (same "" (get-output-stream-string out))
        ;; Compiler invocation errors retain the existing diagnostic fallback.
        (same 3 (mognitio.driver:run-cli '("unknown") out err))))))

(deftest v012-test-source-failure-preserves-primary
  (let* ((manifest (project-fixture '(("app.mgn" . "namespace App; this is invalid;"))))
         (original (fdefinition 'mognitio.io::signal-action))
         (before (v12-signals)) (fds (v11-fd-snapshot)))
    (dolist (outer '(nil t))
      (let ((out (make-string-output-stream)) (err (make-string-output-stream))
            (restored 0) (mognitio.io::*signal-secondary* nil)
            (mognitio.testing::*runner-hook*
              (lambda (&rest args) (declare (ignore args)) (error "Source failure started runner"))))
        (replacing (mognitio.io::signal-action
                     (lambda (state mode)
                       (funcall original state mode)
                       (when (eq mode :restore) (incf restored) (internal-error "Restore report failure"))))
          (flet ((command () (mognitio.driver:run-cli (list "test" (namestring manifest)) out err)))
            (same 1 (if outer (mognitio.io::call-with-io-signals #'command) (command)))))
        (same 2 restored)
        (when outer (same 2 (length mognitio.io::*signal-secondary*)))
        (same "" (get-output-stream-string out))
        (let ((message (get-output-stream-string err)))
          (is (search "app.mgn" message))
          (is (not (search "guard failure" message)))
          (is (not (search "tests:" message))))
        (same before (v12-signals))
        (same fds (v11-fd-snapshot))))))

(deftest v012-application-status-is-not-command-primary
  (dolist (body '("1" "2"))
    (let ((original (fdefinition 'mognitio.io::signal-action)))
      (replacing (mognitio.io::signal-action
                   (lambda (state mode)
                     (funcall original state mode)
                     (when (eq mode :restore) (internal-error "Restore report failure"))))
        (multiple-value-bind (out err code) (v12-driver (v12-manifest body))
          (same 3 code) (same "" out) (is (search "guard failure" err)))))))
