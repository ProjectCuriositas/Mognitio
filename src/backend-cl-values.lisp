(in-package #:mognitio.backend.cl)

(defun interface-table (checked implementation functions)
  (let* ((context (checked-program-values checked)) (contract (implementation-info-contract implementation)))
    (map 'vector (lambda (requirement)
                   (list 'cl:function (gethash (signature-id (cdr (assoc (requirement-name requirement) (implementation-info-methods implementation) :test #'string=))) functions)))
         (type-info-methods (context-type context contract)))))

(defun expression-form (node checked names functions exits &optional loops)
  (let ((form (unpacked-expression-form node checked names functions exits loops))
        (pack (checked-pack checked node)))
    (if pack (list 'mognitio.value:pack form (list 'quote (implementation-info-contract pack))
                   (cons 'cl:vector (coerce (interface-table checked pack functions) 'list))) form)))

(defun value-expression-form (node checked names functions exits loops)
  (labels ((form (child) (expression-form child checked names functions exits loops))
           (binding (token) (gethash (local-symbol-id (checked-symbol checked token)) names))
           (ordered (children build)
             (let ((bindings nil) (args nil))
               (dolist (child children)
                 (unless (checked-normal-type checked child)
                   (return-from ordered (list 'let* (nreverse bindings) (form child))))
                 (let ((name (make-symbol "VALUE"))) (push (list name (form child)) bindings) (push name args)))
               (list 'let* (nreverse bindings) (funcall build (nreverse args)))))
           (when-arms (arms)
             (if (null arms) (list 'quote *void-value*)
                 (let* ((arm (first arms)) (condition (branch-arm-selector arm)))
                   (cond ((null condition) (form (branch-arm-value arm)))
                         ((null (checked-normal-type checked condition)) (form condition))
                         (t (list 'if (form condition) (form (branch-arm-value arm)) (when-arms (rest arms)))))))))
    (typecase node
      ((or data-declaration contract-declaration implementation-declaration) (list 'quote *void-value*))
      (this-expression (gethash (member-info-index (checked-member checked node)) names))
      (struct-expression
       (ordered (map 'list #'named-member-value (struct-expression-fields node))
                (lambda (args)
                  (let* ((info (checked-member checked node))
                         (pairs (mapcar #'cons (member-info-index info) args)))
                    (list* 'mognitio.value:construct (list 'quote (member-info-type info)) 0
                           (mapcar #'cdr (sort pairs #'< :key #'car)))))))
      (enum-expression
       (ordered (coerce (enum-expression-arguments node) 'list)
                (lambda (args)
                  (let ((info (checked-member checked node)))
                    (list* 'mognitio.value:construct (list 'quote (member-info-type info)) (member-info-variant info) args)))))
      (field-expression
       (ordered (list (field-expression-receiver node))
                (lambda (args) (list 'mognitio.value:field (first args) (member-info-index (checked-member checked node))))))
      (branch-expression
       (if (eq :when (branch-expression-mode node)) (when-arms (coerce (branch-expression-arms node) 'list))
           (let ((subject (branch-expression-subject node)) (name (make-symbol "SUBJECT")))
             (if (null (checked-normal-type checked subject)) (form subject)
                 (list 'let (list (list name (form subject)))
                       (list* 'case (list 'mognitio.value:tag name)
                              (append
                               (loop for arm across (branch-expression-arms node) for pattern = (branch-arm-selector arm)
                                     collect
                                 (if (null pattern) (list 'otherwise (form (branch-arm-value arm)))
                                     (list (member-info-variant (checked-member checked pattern))
                                           (list 'let
                                                 (loop for token across (or (variant-pattern-bindings pattern) #()) for index from 0
                                                       collect (list (binding token) (list 'mognitio.value:field name index)))
                                                 (form (branch-arm-value arm))))))
                               (unless (some (lambda (arm) (null (branch-arm-selector arm))) (coerce (branch-expression-arms node) 'list))
                                 (list (list 'otherwise (list 'mognitio.diagnostics:internal-error "Invalid enum tag")))))))))))
      (method-call
       (ordered (cons (method-call-receiver node) (coerce (method-call-arguments node) 'list))
         (lambda (args)
           (let ((member (checked-member checked node)))
             (if (eq :field-call (member-info-kind member))
                 (list* 'mognitio.value::closure-call
                        (list 'mognitio.value:field (first args) (member-info-index member)) (rest args))
                 (list* 'cl:funcall (list 'mognitio.value:method-id (first args) (member-info-index member))
                        (list 'mognitio.value:receiver (first args)) (rest args)))))))
      (t (internal-error "Invalid host value node")))))
