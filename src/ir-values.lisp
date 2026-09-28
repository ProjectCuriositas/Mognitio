(in-package #:mognitio.ir)

(defun lower-value-node (node checked block env lower emit new-block new-value)
  (labels ((emit (where type op &key value operands)
             (funcall emit where type op (node-span node) :value value :operands operands))
           (lower (child where bindings) (funcall lower child where bindings))
           (ordered (nodes builder)
             (let ((operands nil))
               (dolist (child nodes)
                 (multiple-value-bind (value end updated) (lower child block env)
                   (unless end (return-from ordered (values nil nil nil)))
                   (push value operands) (setf block end env updated)))
               (values (funcall builder (nreverse operands)) block env))))
    (typecase node
      ((or data-declaration contract-declaration implementation-declaration) (values nil block env))
      (this-expression
       (let ((pair (assoc (member-info-index (checked-member checked node)) env)))
         (unless pair (internal-error "Missing receiver SSA binding")) (values (cdr pair) block env)))
      (struct-expression
       (ordered (map 'list #'named-member-value (struct-expression-fields node))
                (lambda (operands)
                  (let ((info (checked-member checked node)))
                    (emit block (member-info-type info) :struct.make :value (member-info-index info) :operands operands)))))
      (enum-expression
       (ordered (coerce (enum-expression-arguments node) 'list)
                (lambda (operands)
                  (let ((info (checked-member checked node)))
                    (emit block (member-info-type info) :enum.make :value (member-info-variant info) :operands operands)))))
      (field-expression
       (ordered (list (field-expression-receiver node))
                (lambda (operands)
                  (emit block (checked-normal-type checked node) :struct.field
                        :value (member-info-index (checked-member checked node)) :operands operands))))
      (method-call
       (ordered (cons (method-call-receiver node) (coerce (method-call-arguments node) 'list))
                (lambda (operands)
                  (let ((info (checked-member checked node)))
                    (cond
                      ((eq :field-call (member-info-kind info))
                       (let ((callee (emit block (call-info-type (checked-call checked node)) :struct.field
                                           :value (member-info-index info) :operands (list (first operands)))))
                         (emit block (checked-normal-type checked node) :closure.call :value (call-info-type (checked-call checked node)) :operands (cons callee (rest operands)))))
                      ((member-info-signature info)
                       (emit block (checked-normal-type checked node) :call :value (signature-id (member-info-signature info)) :operands operands))
                      (t (emit block (checked-normal-type checked node) :call.interface
                               :value (list (member-info-contract info) (member-info-index info) (call-info-targets (checked-call checked node)))
                               :operands operands)))))))
      (branch-expression
       (lower-value-branch node checked block env lower emit new-block new-value))
      (t (internal-error "Invalid value lowering node")))))

(defun lower-value-branch (node checked block env lower emit new-block new-value &optional (result-type (checked-normal-type checked node)))
  (let ((on-p (eq :on (branch-expression-mode node))) (subject nil) (tag nil) (ends nil)
        (visible (sort (remove-duplicates (mapcar #'car env)) #'<)))
    (labels ((fresh () (funcall new-block (node-span node)))
             (value (where type op &key data operands)
               (funcall emit where type op (node-span node) :value data :operands operands))
             (lookup (id bindings) (or (assoc id bindings) (internal-error "Lost branch binding")))
             (arm-value (arm where bindings)
               (let ((pattern (branch-arm-selector arm)))
                 (when (and on-p pattern)
                   (let ((variant (member-info-variant (checked-member checked pattern)))
                         (type (member-info-type (checked-member checked pattern))))
                     (loop for token across (or (variant-pattern-bindings pattern) #()) for index from 0
                           do
                       (let* ((symbol (checked-symbol checked token))
                              (id (value where (local-symbol-type symbol) :enum.payload
                                         :data (list type variant index) :operands (list subject))))
                         (push (cons (local-symbol-id symbol) id) bindings)))))
                 (multiple-value-bind (result end updated) (funcall lower (branch-arm-value arm) where bindings)
                   (when end (push (list result end updated) ends))))))
      (when on-p
        (multiple-value-bind (result end updated) (funcall lower (branch-expression-subject node) block env)
          (unless end (return-from lower-value-branch (values nil nil nil)))
          (setf subject result block end env updated tag (value block :int :enum.tag :operands (list subject)))))
      (loop for arm across (branch-expression-arms node) while block
            for selector = (branch-arm-selector arm) do
        (if (null selector)
            (progn (arm-value arm block env) (setf block nil))
            (multiple-value-bind (condition end updated)
                (if on-p
                    (values (value block :bool :eq :operands
                                   (list tag (value block :int :constant :data (member-info-variant (checked-member checked selector))))) block env)
                    (funcall lower selector block env))
              (if (null end) (setf block nil)
                  (let ((yes (fresh)) (no (fresh)))
                    (setf (basic-block-terminator end) (list :branch condition (basic-block-id yes) (basic-block-id no)))
                    (arm-value arm yes updated) (setf block no env updated))))))
      (when block
        (if on-p (setf (basic-block-terminator block) '(:trap))
            (push (list (value block :void :constant :data 0) block env) ends)))
      (unless ends (return-from lower-value-branch (values nil nil nil)))
      (when (null (rest ends))
        (return-from lower-value-branch
          (values (first (first ends)) (second (first ends))
                  (mapcar (lambda (id) (lookup id (third (first ends)))) visible))))
      (let* ((join (fresh)) (result (funcall new-value)) (merged nil)
             (parameters (list (cons result result-type)))
             (arguments (mapcar (lambda (end) (list (first end))) ends)))
        (dolist (id visible)
          (let ((incoming (mapcar (lambda (end) (cdr (lookup id (third end)))) ends)))
            (if (every (lambda (value) (= value (first incoming))) incoming)
                (push (cons id (first incoming)) merged)
                (let* ((symbol (aref (checked-program-bindings checked) id)) (parameter (funcall new-value)))
                  (unless (eq :var (local-symbol-mutability symbol)) (internal-error "Immutable branch binding changed"))
                  (push (cons parameter (local-symbol-type symbol)) parameters) (push (cons id parameter) merged)
                  (setf arguments (mapcar (lambda (arg value) (cons value arg)) arguments incoming))))))
        (setf (basic-block-parameters join) (nreverse parameters))
        (loop for endpoint in ends for args in arguments do
          (setf (basic-block-terminator (second endpoint)) (list :jump (basic-block-id join) (nreverse args))))
        (values result join merged)))))
