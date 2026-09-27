(in-package #:mognitio.backend.native)

(defun compile-program (checked target)
  (unless (typep target 'mognitio.target:target)
    (internal-error "Native compilation requires an explicit target"))
  (unless (typep checked 'mognitio.semantic:checked-program)
    (internal-error "Native compilation requires a checked program"))
  (let* ((sink (make-string-output-stream))
         (*standard-output* sink) (*error-output* sink) (*trace-output* sink)
         (span (mognitio.syntax:node-span (mognitio.semantic:checked-program-program checked))))
    (handler-case
        (let* ((ir (mognitio.ir:lower-program checked))
               (verified (mognitio.ir:verify-module ir))
               (machine (mognitio.machine:lower-module verified)))
          (multiple-value-bind (code symbols) (mognitio.amd64:encode machine)
            (verify-native-metadata verified code symbols)
            (mognitio.elf:make-image code)))
      (compiler-failure (condition)
        (mognitio.source:fail-at span :internal
                                (diagnostic-message (failure-diagnostic condition))
                                'internal-failure))
      (error ()
        (mognitio.source:fail-at span :internal "Native compilation failed"
                                'internal-failure)))))
