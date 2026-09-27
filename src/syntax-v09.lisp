(in-package #:mognitio.syntax)

(defstruct template-declaration name parameters function span)
(defstruct specialization-reference name arguments span)
(defstruct list-expression type elements span)
