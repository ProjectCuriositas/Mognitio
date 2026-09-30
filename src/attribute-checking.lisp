(in-package #:mognitio.semantic)

(defstruct checked-attribute kind declaration syntax)
(defparameter *compiler-attributes* '(("test" :kind :test :target :module-let :repeatable nil)))

(defun diagnostic-type-name (type context)
  (labels ((name (part)
             (cond ((assoc part '((:int . "Int") (:bool . "Bool") (:string . "String") (:void . "Unit")))
                    (cdr (assoc part '((:int . "Int") (:bool . "Bool") (:string . "String") (:void . "Unit")))))
                   ((function-type-p part)
                    (format nil "Function(~{~A~^, ~}): ~A" (mapcar #'name (second part)) (name (third part))))
                   ((list-type-p part) (format nil "List<~A>" (name (second part))))
                   ((application-type-p part)
                    (format nil "~A<~{~A~^, ~}>"
                            (generic-template-name (gethash (third part) (value-context-templates context)))
                            (mapcar #'name (fourth part))))
                   ((nominal-type-p part)
                    (let ((info (context-type context part)))
                      (if (type-info-arguments info)
                          (format nil "~A<~{~A~^, ~}>" (type-info-name info)
                                  (mapcar #'name (type-info-arguments info)))
                          (type-info-name info))))
                   ((rigid-type-p part)
                    (or (loop for key being the hash-keys of (value-context-names context)
                                using (hash-value value) when (equal part value) return key)
                        "type parameter"))
                   (t "non-completing"))))
    (name type)))

(defun attribute-roots (program)
  (or (mognitio.syntax::program-modules program) (list program)))

(defun module-binding-p (program node)
  (and (typep node 'local-binding) (eq (local-binding-mutability node) :let)
       (some (lambda (root) (find node (program-statements root))) (attribute-roots program))))

(defun check-attribute-targets (program)
  (dolist (root (attribute-roots program))
    (walk-ast root
      (lambda (node)
        (let ((seen nil))
          (loop for attribute across (declaration-attributes node)
                for name = (attribute-syntax-name attribute)
                for descriptor = (assoc (token-text name) *compiler-attributes* :test #'string=) do
            (unless descriptor (fail-at (token-span name) :semantic (format nil "Unknown compiler attribute ~A (unsupported in this version)" (token-text name))))
            (let ((previous (assoc (token-text name) seen :test #'string=)))
              (when previous
                (let ((diagnostic (span-diagnostic (attribute-syntax-span attribute) :semantic "Duplicate attribute")))
                  (setf (mognitio.diagnostics::diagnostic-related diagnostic)
                        (list (span-diagnostic (attribute-syntax-span (cdr previous)) :semantic "First attribute")))
                  (error 'source-failure :diagnostic diagnostic))))
            (push (cons (token-text name) attribute) seen)
            (unless (module-binding-p program node)
              (let ((diagnostic (span-diagnostic (attribute-syntax-span attribute) :semantic
                                                "test requires a module-level let declaration")))
                (setf (mognitio.diagnostics::diagnostic-related diagnostic)
                      (list (span-diagnostic (declaration-span node) :semantic "Invalid attribute target")))
                (error 'source-failure :diagnostic diagnostic)))))))))

(defun check-attribute-types (checked)
  (let ((program (checked-program-program checked)))
    (dolist (root (attribute-roots program))
      (loop for node across (program-statements root) do
        (loop for attribute across (declaration-attributes node) do
          (unless (equal (local-symbol-type (checked-symbol checked node)) '(:function nil :void))
            (fail-at (form-span (local-binding-annotation node)) :type
                     (format nil "test must have type Function(): Unit; actual ~A"
                             (diagnostic-type-name (local-symbol-type (checked-symbol checked node))
                                                   (checked-program-values checked)))))
          (setf (gethash node (checked-program-attributes checked))
                (make-checked-attribute :kind :test :declaration node :syntax attribute)))))))

(defun verify-attributes (checked)
  ;; Reconstruct the accepted declaration set from original AST ownership.
  (let ((program (checked-program-program checked)) (seen (make-hash-table :test #'eq)))
    (dolist (root (attribute-roots program))
      (walk-ast root
        (lambda (node)
          (let ((attributes (declaration-attributes node)))
            (when (plusp (length attributes))
              (let* ((attribute (aref attributes 0)) (stored (gethash node (checked-program-attributes checked))))
                (unless (and (= (length attributes) 1)
                             (string= (token-text (attribute-syntax-name attribute)) "test")
                             (typep node 'local-binding) (eq (local-binding-mutability node) :let)
                             (find node (program-statements root))
                             (equal (local-symbol-type (checked-symbol checked node)) '(:function nil :void))
                             stored (eq (checked-attribute-kind stored) :test)
                             (eq (checked-attribute-declaration stored) node) (eq (checked-attribute-syntax stored) attribute))
                  (internal-error "Invalid checked attribute proof"))
                (setf (gethash node seen) t)))))))
    (unless (= (hash-table-count seen) (hash-table-count (checked-program-attributes checked)))
      (internal-error "Extra checked attribute proof")))
  t)
