(in-package #:mognitio.native.runtime)

(defstruct runtime-context-layout fields size profile)
(defun build-runtime-context-layout (test-p)
  (let ((offset 0) (fields nil))
    (dolist (field (append '((:legacy-runtime 240 0 0) (:initial-stack 8 1 0)
                             (:argument-root 16 2 0) (:arguments 8 3 0)
                             (:cleanup-head 8 1 0) (:report-mode 8 1 0))
                    (when test-p '((:test-stage 8 5 0) (:test-sequence 8 5 0)
                                   (:test-kind 8 5 0) (:test-site 8 5 0)
                                   (:test-exit 8 5 0) (:test-padding 8 4 0)))
                    '((:free-head 8 1 0) (:allocation-padding 8 4 0))))
      (destructuring-bind (name size kind zero) field
        (push (list name offset size kind zero) fields) (incf offset size)))
    (make-runtime-context-layout :fields (nreverse fields) :size offset :profile (if test-p 1 0))))

(defun context-field-offset (name &optional test-p)
  (or (second (assoc name (runtime-context-layout-fields (build-runtime-context-layout test-p))))
      (mognitio.diagnostics:internal-error "Unknown runtime context field")))

(defun context-metadata-unit ()
  (let* ((layout (build-runtime-context-layout (test-image-p)))
         (words (append (list 7 (runtime-context-layout-profile layout) (runtime-context-layout-size layout)
                              (length (runtime-context-layout-fields layout)))
                        (loop for field in (runtime-context-layout-fields layout) for id from 0 append
                          (cons id (rest field))))))
    (mognitio.object:make-code-unit :owner :runtime-context
      :instructions
      (mapcar (lambda (form) (mognitio.machine:make-instruction :opcode (car form) :operands (cdr form)))
        (list '(:align 8) '(:label (:runtime-context 7))
              (cons :bytes (loop for word in words append (mognitio.amd64:little-endian word 8))))))))
