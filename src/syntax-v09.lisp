(in-package #:mognitio.syntax)

(defstruct template-declaration (attributes #() :read-only t) (declaration-span nil :read-only t) name parameters function span)
(defstruct specialization-reference name arguments span)
(defstruct list-expression type elements span)
