(in-package #:mognitio.syntax)

;; Type syntax retains token compatibility for the non-generic readers.
(defstruct try-expression operand span)
(defstruct panic-expression block span)

(defstruct concrete-function-reference target span)

(defun error-node-span (node)
  (typecase node
    (concrete-function-reference (concrete-function-reference-span node))
    (try-expression (try-expression-span node))
    (panic-expression (panic-expression-span node))))

;; Compile-time arguments are syntax, never runtime expressions.
(defstruct (value-parameter-syntax (:include token)) domain)
(defstruct (value-argument-syntax (:include token)) digits negative reference)
