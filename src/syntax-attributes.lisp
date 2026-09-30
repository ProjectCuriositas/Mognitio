(in-package #:mognitio.syntax)

(defun declaration-attributes (node)
  (typecase node
    (local-binding (local-binding-attributes node))
    (data-declaration (data-declaration-attributes node))
    (contract-declaration (contract-declaration-attributes node))
    (implementation-declaration (implementation-declaration-attributes node))
    (template-declaration (template-declaration-attributes node))
    (t #())))

(defun declaration-span (node)
  (or (typecase node
        (local-binding (local-binding-declaration-span node))
        (data-declaration (data-declaration-declaration-span node))
        (contract-declaration (contract-declaration-declaration-span node))
        (implementation-declaration (implementation-declaration-declaration-span node))
        (template-declaration (template-declaration-declaration-span node)))
      (node-span node)))

(defun with-declaration-metadata (node attributes span)
  ;; Construct a fresh node; metadata slots have no public mutating accessors.
  (apply (symbol-function (intern (concatenate 'string "MAKE-" (symbol-name (type-of node))) :mognitio.syntax))
         :attributes attributes :declaration-span span
         (loop for slot in (sb-mop:class-slots (class-of node))
               for name = (sb-mop:slot-definition-name slot)
               unless (member name '(attributes declaration-span))
                 append (list (intern (symbol-name name) :keyword) (slot-value node name)))))

(defun walk-ast (node visit)
  (cond ((and (vectorp node) (not (stringp node)))
         (map nil (lambda (child) (walk-ast child visit)) node))
        ((and (typep node 'structure-object) (eq (symbol-package (type-of node)) (find-package :mognitio.syntax)))
         (funcall visit node)
         (dolist (slot (sb-mop:class-slots (class-of node)))
           (let ((name (sb-mop:slot-definition-name slot)))
             (unless (member name '(span source project modules payload attributes declaration-span keyword-span))
               (walk-ast (slot-value node name) visit)))))))
