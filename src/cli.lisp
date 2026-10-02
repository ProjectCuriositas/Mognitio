(in-package #:mognitio.cli)

(defun command ()
  (let ((arguments (uiop:command-line-arguments)))
    (when (equal arguments '("--mognitio-argv-fd=3"))
      (handler-case
          (with-open-stream (stream (sb-sys:make-fd-stream 3 :input t :element-type '(unsigned-byte 8)))
            (setf arguments (mognitio.driver::read-raw-invocation stream)))
        ((or mognitio.diagnostics:usage-or-io-failure stream-error file-error sb-posix:syscall-error) ()
          (ignore-errors (write-line "mgn: Invalid argument transport" *error-output*) (finish-output *error-output*))
          (return-from command (values 2 t)))))
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
