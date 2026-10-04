(in-package #:mognitio.backend.cl)

(defvar *void-value* (make-symbol "VOID"))

(defstruct (compiled-program
             (:constructor %make-compiled-program
                 (function span &optional warnings-p compiler-output (result-type :bool))))
  (function nil :read-only t) (span nil :read-only t) (result-type :bool :read-only t)
  (warnings-p nil :read-only t) (compiler-output "" :read-only t))

(defun unpacked-expression-form (node checked names functions exits &optional loops)
  (labels ((form (child) (if child (expression-form child checked names functions exits loops) (list 'cl:quote *void-value*)))
           (symbol-for (child)
             (or (gethash (local-symbol-id (checked-symbol checked child)) names)
                 (internal-error "Missing host binding")))
           (ordered (children build)
             (let ((bindings nil) (args nil))
               (dolist (child children)
                 (unless (checked-normal-type checked child)
                   (return-from ordered (list 'cl:let* (nreverse bindings) (form child))))
                 (let ((name (make-symbol "ARG")))
                   (push (list name (form child)) bindings) (push name args)))
               (list 'cl:let* (nreverse bindings) (funcall build (nreverse args)))))
           (sequence-form (statements tail index)
             (if (= index (length statements)) (form tail)
                 (let ((statement (aref statements index)))
                   (unless (checked-normal-type checked statement) (return-from sequence-form (form statement)))
                   (if (typep statement 'local-binding)
                       (list 'cl:let (list (list (symbol-for statement) (form (local-binding-initializer statement))))
                             (sequence-form statements tail (1+ index)))
                       (list 'cl:progn (form statement) (sequence-form statements tail (1+ index))))))))
    (typecase node
      ((or data-declaration contract-declaration implementation-declaration struct-expression enum-expression field-expression this-expression branch-expression)
       (value-expression-form node checked names functions exits loops))
      (mognitio.syntax::io-expression
       (ordered (coerce (mognitio.syntax::io-expression-arguments node) 'list)
         (lambda (args)
           (let* ((context (checked-program-values checked)) (result (checked-normal-type checked node))
                  (error-type (second (mognitio.semantic::canonical-result-arguments context result)))
                  (fields (type-info-fields (context-type context error-type))))
             (list 'mognitio.io::invoke (mognitio.syntax::io-expression-operation node) (cons 'cl:list args)
                   (list 'cl:quote result) (list 'cl:quote error-type)
                   (list 'cl:quote (cdr (assoc "operation" fields :test #'string=)))
                   (list 'cl:quote (cdr (assoc "kind" fields :test #'string=)))
                   (list 'cl:quote (cdr (assoc "phase" fields :test #'string=)))
                   (list 'cl:quote (gethash "standard:Std\\Io#DirectoryEntry" (mognitio.semantic::value-context-names context)))
                   (list 'cl:quote (gethash "standard:Std\\Io#DirectoryEntryKind" (mognitio.semantic::value-context-names context))))))))
      (mognitio.syntax::test-stage *void-value*)
      (mognitio.syntax::runtime-arguments '(cl:prog1 mognitio.runtime::*arguments*
          (cl:setf mognitio.runtime::*arguments* mognitio.value::*empty-list*)))
      (assert-statement
       `(cl:progn (cl:unless ,(form (assert-statement-operand node))
                    (mognitio.runtime::raise-assertion ',(node-span node))) ,*void-value*))
      (panic-expression
       (let ((child (panic-expression-block node)))
         (if (checked-normal-type checked child) (list 'mognitio.runtime::raise-panic (form child)) (form child))))
      (try-expression
       (let* ((child (try-expression-operand node)) (info (checked-error checked node)) (value (make-symbol "RESULT")))
         (if (null (checked-normal-type checked child)) (form child)
             (list 'cl:let (list (list value (form child)))
                   (list 'cl:case (list 'mognitio.value:tag value)
                         (list 0 (list 'mognitio.value:field value 0))
                         (list 1 (list 'cl:return-from (gethash (error-info-owner info) exits)
                                       (list 'mognitio.value:construct (list 'cl:quote (error-info-return-type info)) 1
                                             (list 'mognitio.value:field value 0))))
                         (list 'cl:otherwise (list 'mognitio.diagnostics:internal-error "Invalid Result tag")))))))
      (loop-expression
       (let* ((id (loop-info-id (checked-loop checked node))) (exit (make-symbol "BREAK")) (again (make-symbol "CONTINUE"))
              (start (make-symbol "LOOP")) (inner (acons id (cons exit again) loops))
              (target (loop-expression-target node)) (condition (loop-expression-condition node)))
         (if target
             (let ((buffer (make-symbol "BUFFER")) (index (make-symbol "INDEX")) (binder (loop-expression-binder node)))
               (list 'cl:let (list (list buffer (list 'mognitio.value::list-buffer (form target))) (list index 0))
                 (list 'cl:block exit
                   (list 'cl:tagbody start
                     (list 'cl:when (list 'cl:>= index (list 'cl:length buffer)) (list 'cl:return-from exit (list 'cl:quote *void-value*)))
                     (list 'cl:let (list (list (symbol-for binder) (list 'cl:aref buffer index)))
                           (expression-form (loop-expression-body node) checked names functions exits inner))
                     again (list 'cl:incf index) (list 'cl:go start)))))
             (list 'cl:block exit
               (list 'cl:tagbody again
                 (when condition (list 'cl:unless (form condition) (list 'cl:return-from exit (list 'cl:quote *void-value*))))
                 (expression-form (loop-expression-body node) checked names functions exits inner)
                 (list 'cl:go again))))))
      (break-statement
       (let ((value (break-statement-value node)))
         (if (or (null value) (checked-normal-type checked value))
             (list 'cl:return-from (cadr (assoc (loop-info-id (checked-control checked node)) loops)) (form value))
             (form value))))
      (continue-statement
       (list 'cl:go (cddr (assoc (loop-info-id (checked-control checked node)) loops))))
      (string-literal (list 'cl:quote (mognitio.text:literal-value (string-literal-payload node))))
      (void-literal (list 'cl:quote *void-value*))
      (local-binding (form (local-binding-initializer node)))
      (expression-statement (form (expression-statement-expression node)))
      (assignment (list 'cl:progn (list 'cl:setq (symbol-for node) (form (assignment-rhs node))) (list 'cl:quote *void-value*)))
      (boolean-literal (ecase (boolean-literal-value node) (:true t) (:false nil)))
      (integer-literal (checked-literal checked node))
      (concrete-function-reference
       (let ((signature (checked-function checked node)))
         (list* 'mognitio.value::closure (list 'cl:function (gethash (signature-id signature) functions))
                (mapcar (lambda (binding) (gethash (local-symbol-id binding) names)) (signature-captures signature)))))
      (function-expression (signature-id (checked-function checked node)))
      (variable-reference (or (local-symbol-static-target (checked-symbol checked node)) (symbol-for node)))
      (sequence-node (sequence-form (sequence-node-statements node) (sequence-node-terminal node) 0))
      (grouping (form (grouping-expression node)))
      (return-statement
       (let ((value (return-statement-value node)))
         (if (or (null value) (checked-normal-type checked value))
             (list 'cl:return-from (gethash (checked-return checked node) exits) (form value))
             (form value))))
      (method-call
       (if (not (checked-operation checked node))
           (value-expression-form node checked names functions exits loops)
           (ordered (cons (method-call-receiver node) (coerce (method-call-arguments node) 'list))
             (lambda (args)
               (let* ((info (checked-operation checked node)) (result (operation-info-result-type info))
                      (error-type (when (member (operation-info-kind info) '(:list.at :text.slice.result))
                                    (second (mognitio.semantic::type-info-arguments (context-type (checked-program-values checked) result))))))
                 (append
                   (list (ecase (operation-info-kind info)
                           (:text.length 'mognitio.text:text-length)
                           (:text.scalars 'mognitio.value::text-scalars)
                           (:text.join 'mognitio.value::text-join)
                           (:text.slice.result 'mognitio.value::text-slice-result)
                           (:list.length 'mognitio.value::list-length-value)
                           (:list.append 'mognitio.value::list-append-value)
                           (:list.at 'mognitio.value::list-at-value)))
                   args (when error-type (list (list 'cl:quote result) (list 'cl:quote error-type)))))))))
      (call-expression
       (if (checked-pack checked node) (form (aref (call-expression-arguments node) 0))
           (ordered (cons (call-expression-callee node) (coerce (call-expression-arguments node) 'list))
                    (lambda (args) (cons 'mognitio.value::closure-call args)))))
      (list-expression
       (ordered (coerce (list-expression-elements node) 'list)
                (lambda (args) (cons 'mognitio.value::list-literal args))))
      (if-expression
       (if (null (checked-normal-type checked (if-expression-condition node)))
           (form (if-expression-condition node))
           (list 'cl:if (form (if-expression-condition node))
                   (form (if-expression-then-branch node)) (form (if-expression-else-branch node)))))
      (unary-expression
       (if (checked-literal-p checked node) (checked-literal checked node)
           (let ((child (unary-expression-operand node)))
             (if (checked-normal-type checked child)
                 (if (eq :not (token-kind (unary-expression-operator node))) (list 'cl:not (form child))
                     (list 'mognitio.integer:checked-arithmetic :neg (form child))) (form child)))))
      (binary-expression
       (let ((op (token-kind (binary-expression-operator node))) (a (binary-expression-left node)) (b (binary-expression-right node)))
         (if (member op '(:and :or))
             (list (if (eq op :and) 'cl:and 'cl:or) (form a) (form b))
             (ordered (list a b)
               (lambda (args)
                 (let ((kind (operation-info-kind (checked-operation checked node))))
                   (cond
                     ((member kind '(:text.concat :text.equal :text.not-equal))
                      (cons (ecase kind (:text.concat 'mognitio.text:text-concat) (:text.equal 'mognitio.text:text-equal)
                                        (:text.not-equal 'mognitio.text:text-not-equal)) args))
                     ((member op '(:add :sub :mul :div :rem)) (list* 'mognitio.integer:checked-arithmetic op args))
                     (t (let ((comparison (cons (case op ((:eq :ne) (if (eq :int (checked-normal-type checked a)) 'cl:= 'cl:eq))
                                                         (:lt 'cl:<) (:le 'cl:<=) (:gt 'cl:>) (:ge 'cl:>=)) args)))
                          (if (eq op :ne) (list 'cl:not comparison) comparison))))))))))
      (t (internal-error "Invalid checked AST")))))

(defun program-form (checked)
  (let ((names (make-hash-table)) (functions (make-hash-table)) (exits (make-hash-table))
        (program (checked-program-program checked)))
    (loop for symbol across (checked-program-bindings checked)
          do (setf (gethash (local-symbol-id symbol) names) (make-symbol "LOCAL")))
    (loop for signature across (checked-program-signatures checked) do
      (setf (gethash (signature-id signature) functions) (make-symbol "FUNCTION")
            (gethash (signature-id signature) exits) (make-symbol "RETURN")))
    (let ((definitions
            (loop for signature across (checked-program-signatures checked)
                  for declaration = (signature-declaration signature) when declaration collect
              (let ((context (make-symbol "CONTEXT")))
                (list (gethash (signature-id signature) functions)
                      (append (unless (signature-receiver signature) (list context))
                              (map 'list (lambda (p) (gethash (local-symbol-id (checked-symbol checked p)) names))
                                   (function-expression-parameters declaration)))
                      (list 'cl:declare (list 'cl:ignorable
                        (if (signature-receiver signature) (gethash (local-symbol-id (signature-receiver signature)) names) context)))
                      (list 'cl:let
                        (loop for capture in (signature-captures signature) for index from 0
                              collect (list (gethash (local-symbol-id capture) names) (list 'mognitio.value::capture context index)))
                        (list 'cl:block (gethash (signature-id signature) exits)
                              (expression-form (function-expression-body declaration) checked names functions exits)))))))
          (entry (expression-form (make-sequence-node :statements (program-statements program)
                                    :terminal (program-root program)) checked names functions exits)))
      (if definitions
          (list 'cl:labels definitions (list 'cl:declare (cons 'cl:notinline (mapcar #'first definitions))) entry) entry))))

(defun host-compile (form)
  (with-compilation-unit (:override t)
    (compile nil form)))

(defun call-isolated (span thunk &optional runtime-allowed)
  (let* ((capture (make-string-output-stream))
         (*standard-output* capture) (*error-output* capture) (*trace-output* capture)
         (*compile-verbose* nil) (*compile-print* nil))
    (handler-case (with-compilation-unit (:override t) (funcall thunk))
      (mognitio.runtime:program-runtime-failure (condition)
        (if runtime-allowed (error condition)
            (internal-error "Runtime operation evaluated during host compilation")))
      (storage-condition ()
        (if runtime-allowed (mognitio.runtime:runtime-error :allocation-failed)
            (fail-at span :internal "Host compilation storage failure" 'internal-failure)))
      (compiler-failure (condition) (error condition))
      (error ()
        (fail-at span :internal "Host compilation or execution failed" 'internal-failure)))))

(defun compile-program (checked)
  (setf checked (mognitio.semantic::prepare-runtime-program checked))
  (let* ((root (program-root (checked-program-program checked)))
         (span (node-span (or root (checked-program-program checked)))))
    (call-isolated
     span
     (lambda ()
       (multiple-value-bind (function warnings-p failure-p)
           (host-compile (list 'cl:lambda '() (program-form checked)))
         (when (or failure-p (not (compiled-function-p function)))
           (fail-at span :internal "Host compile did not produce a valid function"
                    'internal-failure))
         (%make-compiled-program function span warnings-p
                                 (get-output-stream-string *standard-output*)
                                 (signature-result-type (aref (checked-program-signatures checked) 0))))))))

(defun execute-program (compiled)
  (unless (typep compiled 'compiled-program)
    (internal-error "Expected CompiledProgram"))
  (call-isolated
   (compiled-program-span compiled)
   (lambda ()
     (let ((result (funcall (compiled-program-function compiled))))
       (cond ((and (eq (compiled-program-result-type compiled) :int) (mognitio.integer:in-range-p result)) result)
             ((and (eq (compiled-program-result-type compiled) :void) (eq result *void-value*)) :unit)
             ((and (eq (compiled-program-result-type compiled) :bool) (eq result t)) :true)
             ((and (eq (compiled-program-result-type compiled) :bool) (eq result nil)) :false)
             (t (fail-at (compiled-program-span compiled) :internal
                         "Host returned an invalid entry result" 'internal-failure))))) t))
