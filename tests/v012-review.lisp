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

(deftest v012-short-read-chunks-preserve-consumption
  (let* ((input (put-bytes (fresh-path ".input")
                  (concatenate '(vector (unsigned-byte 8))
                    (make-array 4096 :initial-element 65) #(255) (make-array 20000 :initial-element 66))))
         (manifest (v12-manifest
           "assert branch on readStdin(){Result<String,IoError>::Ok=>false,Result<String,IoError>::Err=>true};
            branch on readStdin(){Result<String,IoError>::Ok(s:String)=>{discard writeStdout(s);0},Result<String,IoError>::Err=>9}"))
         (expected (make-string 19999 :initial-element #\B))
         (reader (fdefinition 'mognitio.io::read-chunk)) (first t))
    ;; Actually consume two bytes on the first read, then use the ordinary read
    ;; policy. No fake return value leaves the kernel position unchanged.
    (replacing (mognitio.io::read-chunk
                 (lambda (fd bytes)
                   (if first
                       (let ((small (make-array 2 :element-type '(unsigned-byte 8))))
                         (setf first nil)
                         (prog1 (funcall reader fd small) (replace bytes small)))
                       (funcall reader fd bytes))))
      (with-open-file (in input :element-type '(unsigned-byte 8))
        (let ((*standard-input* in))
          (multiple-value-bind (out err code) (v12-driver manifest)
            (same 0 code) (same "" err) (same (length expected) (length out)) (is (string= expected out))))))
    (let ((emitter (fdefinition 'mognitio.native.runtime::io-read-forms)))
      (replacing (mognitio.native.runtime::io-read-forms
                   (lambda ()
                     (loop for tail on (funcall emitter) for form = (first tail) append
                       (if (and (equal form '(:mov-eax 0)) (equal (second tail) '(:syscall)))
                           ;; Stdin does not use the stat buffer; this test-only
                           ;; word records whether this helper has read before.
                           (append '((:load-frame :rax -200) (:test) (:jnz :test-full-read)
                                     (:imm-rax 1) (:store-frame -200 :rax) (:mov-edx 2)
                                     (:label :test-full-read)) (list form))
                           (list form)))))
        (let ((image (v12-native manifest)))
          (incf *processes*)
          (multiple-value-bind (out err code)
              (uiop:run-program (list (namestring image)) :input input :output :string
                                :error-output :string :ignore-error-status t)
            (same 0 code) (same "" err) (same (length expected) (length out)) (is (string= expected out))))))))
