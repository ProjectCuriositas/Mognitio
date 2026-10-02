(in-package #:mognitio.driver)

(defun checked-source (path)
  (let* ((source (read-source path))
         (tokens (lex-source source))
         (program (parse-program source tokens)))
    (check-program program)))

(defun checked-project (project)
  (check-program (mognitio.project::project-program (mognitio.project::resolve-project project))))

(defun run-pipeline (argv stdout &optional (stderr *error-output*))
  (multiple-value-bind (command manifest output target arguments) (parse-invocation argv)
    (when (string= command "test")
      (return-from run-pipeline
        (mognitio.testing::run-tests manifest stdout stderr)))
    (let ((project (mognitio.project::load-project manifest)))
      (when output (mognitio.project::validate-project-output project output))
      (let ((checked (checked-project project)))
        (if (string= command "run")
            (let* ((compiled (compile-program checked))
                   (mognitio.runtime::*arguments* (mognitio.runtime::decode-arguments arguments))
                   (mognitio.io::*input* *standard-input*) (mognitio.io::*output* stdout)
                   (mognitio.io::*error-output-stream* stderr))
              (return-from run-pipeline (mognitio.runtime::application-status (execute-program compiled))))
            (let* ((image (mognitio.backend.native:compile-program checked target))
                   (mognitio.artifact::*project-validation*
                     (lambda () (mognitio.project::validate-project-output project output))))
              (mognitio.artifact:publish-image image manifest output))))))
  0)

(defun run-cli-guarded (argv stdout stderr)
  (labels ((report-failure (diagnostic code)
             ;; A broken diagnostic stream must not cause recursive reporting.
             (handler-case (progn (render-diagnostic diagnostic stderr) (values code t))
               ((or error storage-condition) () (values 3 t)))))
    (handler-case (run-pipeline argv stdout stderr)
      (mognitio.runtime::program-assertion (condition) (values (mognitio.runtime::write-assertion condition stderr) t))
      (mognitio.runtime::program-panic (condition) (values (mognitio.runtime::write-panic condition stderr) t))
      (mognitio.runtime:program-runtime-failure (condition)
        (values (mognitio.runtime:write-runtime-failure condition stderr) t))
      (source-failure (condition)
        (report-failure (failure-diagnostic condition) 1))
      (mognitio.runtime::argument-startup-failure (condition)
        (values (mognitio.runtime::write-argument-startup-failure condition stderr) t))
      (usage-or-io-failure (condition)
        (report-failure (failure-diagnostic condition) 2))
      (internal-failure (condition)
        (report-failure (failure-diagnostic condition) 3))
      (storage-condition ()
        (report-failure (make-diagnostic :phase :internal :message "Compiler storage failure") 3))
      (error ()
        (report-failure (make-diagnostic :phase :internal
                                         :message "Unexpected compiler failure") 3)))))

(defun run-cli (argv stdout stderr)
  (let ((mognitio.io::*signal-secondary* nil))
    (handler-case
      (mognitio.io::call-with-io-signals (lambda () (run-cli-guarded argv stdout stderr)))
    ((or error storage-condition) ()
      ;; Guard setup/restore is an internal command boundary. Reporting is best
      ;; effort and never replaces this status or re-enters the failed guard.
      (ignore-errors (write-line "mgn: internal: I/O signal guard failure" stderr) (finish-output stderr))
      3))))
