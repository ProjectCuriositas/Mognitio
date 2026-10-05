(in-package #:mognitio.cli)

(defun command ()
  (let ((arguments (uiop:command-line-arguments)))
    (when (equal arguments '("--mognitio-argv-fd=3" "--mognitio-stdin-closed"))
      ;; The launcher reserves descriptor 0 through SBCL bootstrap so its script
      ;; reader cannot reuse the absent application stdin. Release that temporary
      ;; reservation before project execution, restoring the original closed state.
      (sb-posix:close 0)
      (setf arguments '("--mognitio-argv-fd=3")))
    (when (equal arguments '("--mognitio-argv-fd=3"))
      (handler-case
          (with-open-stream (stream (sb-sys:make-fd-stream 3 :input t :element-type '(unsigned-byte 8)))
            (setf arguments (mognitio.driver::read-raw-invocation stream)))
        ((or mognitio.diagnostics:usage-or-io-failure stream-error file-error sb-posix:syscall-error) ()
          (ignore-errors (write-line "mgn: Invalid argument transport" *error-output*) (finish-output *error-output*))
          (return-from command (values 2 t)))))
    (let ((argv (if (mognitio.driver::raw-invocation-p arguments)
                    (mognitio.driver::raw-invocation-arguments arguments) arguments)))
      (when (and (= (length argv) 1) (equal (mognitio.driver::compiler-argument (first argv)) "--version"))
        (let ((version (symbol-value (find-symbol "*VERSION*" "MOGNITIO.IDENTITY"))))
          (unless version
            (write-line "mgn: Build the toolchain before requesting its identity" *error-output*)
            (return-from command (values 3 t)))
          (format t "mgn ~A~%" version)
          (return-from command (values 0 t)))))
    (mognitio.driver:run-cli arguments *standard-output* *error-output*)))

(defun main ()
  ;; Cover argument transport and its diagnostics as soon as the adapter is
  ;; available. The driver's nested guard shares this ownership interval.
  (sb-ext:exit :code
    (handler-case (mognitio.io::call-with-io-signals #'command)
      ((or error storage-condition) ()
        (ignore-errors (write-line "mgn: internal: Command startup or cleanup failed" *error-output*)
                       (finish-output *error-output*))
        3))))
