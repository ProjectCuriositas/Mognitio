(in-package #:mognitio.analysis)
(defparameter +token-types+
  #("namespace" "type" "interface" "typeParameter" "function" "variable"
    "parameter" "property" "method" "enumMember" "keyword"))
(defun token-row (token role &optional (modifiers 0))
  (let* ((span (token-span token)) (s (span-source span))
         (offsets (mognitio.source::source-byte-offsets s)))
    (vector (aref offsets (span-start span)) (aref offsets (span-end span))
            (position role +token-types+ :test #'equal) modifiers)))
(defun syntax-only (path text output)
  (let* ((source (text-source path text)) (rows nil)
         (mognitio.frontend::*recover-errors* t)
         (mognitio.frontend::*parser-errors* nil))
    (multiple-value-bind (tokens lexical-errors) (mognitio.frontend:lex-source source :recover t)
      (handler-case
          (if (eq (token-kind (aref tokens 0)) :namespace)
              (let ((module (mognitio.project::make-source-module :path path :source source)))
                (mognitio.project::module-header module :tokens tokens :syntax-only t)
                (dolist (decl (mognitio.project::source-module-declarations module))
                  (setf (gethash (mognitio.project::module-declaration-name decl)
                                (mognitio.project::source-module-names module)) decl))
                (mognitio.project::parse-module module :recovery t))
              (mognitio.frontend:parse-program source tokens))
        (source-failure (condition)
          (push (failure-diagnostic condition) mognitio.frontend::*parser-errors*)))
      ;; Only lexical roles survive incomplete analysis. No recovered tree reaches the checker.
      (loop for token across tokens
            when (rassoc (token-kind token) mognitio.frontend::*keywords*)
              do (push (token-row token "keyword") rows))
      (setf (gethash path output) (coerce (nreverse rows) 'vector))
      (append lexical-errors (nreverse mognitio.frontend::*parser-errors*)))))
(defun project-semantic-tokens (project checked)
  (let ((output (make-hash-table :test #'equal))
        (by-source (make-hash-table :test #'eq))
        (seen (make-hash-table :test #'equal)))
    (labels
        ((emit (token role &optional (mods 0))
           (when (and token (typep token 'token))
             (let* ((span (token-span token)) (source (span-source span))
                    (key (list (source-path source) (span-start span) (span-end span))))
               (when (and (eq (mognitio.source::source-origin source) :user)
                          (plusp (- (span-end span) (span-start span)))
                          (not (gethash key seen)))
                 (setf (gethash key seen) t)
                 (push (token-row token role mods) (gethash source by-source))))))
         (types (x &optional (role "type"))
           (typecase x
             (type-syntax (types (type-syntax-name x) role)
              (map nil #'types (type-syntax-arguments x)))
             (function-type-syntax
              (map nil #'types (function-type-syntax-parameters x))
              (types (function-type-syntax-result x)))
             (token
              (let ((resolved (gethash (token-text x)
                                      (mognitio.semantic::value-context-names
                                       (mognitio.semantic::checked-program-values checked)))))
                (emit x (if (mognitio.semantic::nominal-type-p resolved :interface) "interface" role)
                      (if (member (token-text x) mognitio.project::*predeclared* :test #'equal) 4 0))))))
         (visit (node)
           (typecase node
             (local-binding (types (local-binding-annotation node)))
             (parameter (types (parameter-type node)))
             (function-expression (types (function-expression-result-type node)))
             (data-declaration
              (emit (data-declaration-name node) "type" 1)
              (types (data-declaration-target node))
              (map nil (lambda (p) (emit p "typeParameter" 1)) (data-declaration-type-parameters node))
              (loop for member across (data-declaration-members node) do
                (emit (named-member-name member)
                      (if (eq (data-declaration-kind node) :enum) "enumMember" "property") 1)
                (let ((value (named-member-value member)))
                  (if (vectorp value) (map nil #'types value) (types value)))))
             (contract-declaration
              (emit (contract-declaration-name node) "interface" 1)
              (loop for m across (contract-declaration-methods node) do (emit (named-member-name m) "method" 1)))
             (implementation-declaration
              (emit (mognitio.syntax::implementation-declaration-name node) "variable" 3)
              (types (implementation-declaration-target node))
              (types (implementation-declaration-contract node) "interface")
              (loop for method across (implementation-declaration-methods node)
                    do (emit (local-binding-name method) "method" 1)))
             (template-declaration
              (emit (template-declaration-name node) "function" 3)
              (map nil (lambda (p) (emit p "typeParameter" 1)) (template-declaration-parameters node)))
             (variable-reference
              (let ((resolved (gethash (token-text (variable-reference-name node))
                                      (mognitio.semantic::value-context-names
                                       (mognitio.semantic::checked-program-values checked)))))
                (when (mognitio.semantic::nominal-type-p resolved :interface)
                  (emit (variable-reference-name node) "interface"))))
             (specialization-reference (emit (specialization-reference-name node) "function"))
             (field-expression (emit (field-expression-name node) "property"))
             (method-call
              (let ((info (mognitio.semantic::checked-member checked node)))
                (emit (method-call-name node)
                      (if (and info (eq (mognitio.semantic::member-info-kind info) :field-call)) "property" "method")
                      (if (mognitio.semantic::checked-operation checked node) 4 0))))
             (enum-expression (types (enum-expression-name node)) (emit (enum-expression-variant node) "enumMember"))
             (struct-expression
              (types (struct-expression-name node))
              (loop for m across (struct-expression-fields node) do (emit (named-member-name m) "property")))
             (variant-pattern (types (variant-pattern-name node)) (emit (variant-pattern-variant node) "enumMember")))))
      ;; Scoped type parameter occurrences and declaration roles precede binding types.
      (dolist (module (mognitio.project::project-modules project))
        (let ((program (mognitio.project::source-module-program module)))
          (mognitio.syntax:walk-ast
           program
           (lambda (node)
             (let ((parameters (typecase node
                                 (data-declaration (data-declaration-type-parameters node))
                                 (template-declaration (template-declaration-parameters node)))))
               (when parameters
                 (map nil (lambda (token) (emit token "typeParameter" 1)) parameters)
                 (mognitio.syntax:walk-ast
                  node (lambda (child)
                         (when (and (typep child 'token)
                                    (find (token-text child) parameters :key #'token-text :test #'equal))
                           (emit child "typeParameter"))))))))
          (mognitio.syntax:walk-ast program #'visit)))
      ;; Role is determined by resolved declaration before Function structure.
      (maphash
       (lambda (node symbol)
         (let* ((mut (mognitio.semantic::local-symbol-mutability symbol))
                (role (cond ((member mut '(:parameter :receiver)) "parameter")
                            ((mognitio.semantic:function-type-p (mognitio.semantic:local-symbol-type symbol)) "function")
                            (t "variable")))
                (declaration (typep node '(or local-binding parameter)))
                (token (typecase node
                         (local-binding (local-binding-name node)) (parameter (parameter-name node))
                         (variable-reference (variable-reference-name node)) (assignment (assignment-name node))))
                (mods (+ (if declaration 1 0) (if (eq mut :var) 0 2)
                         (if (eq (mognitio.source::source-origin
                                  (span-source (mognitio.semantic::local-symbol-span symbol))) :standard) 4 0))))
           (emit token role mods)))
       (mognitio.semantic::checked-program-symbols checked))
      (dolist (module (mognitio.project::project-modules project))
        (let* ((source (mognitio.project::source-module-source module))
               (tokens (mognitio.frontend:lex-source source)) (namespace nil))
          (mognitio.syntax:walk-ast (mognitio.project::source-module-program module) #'visit)
          (dolist (import (mognitio.project::source-module-imports module))
            (let* ((decl (mognitio.project::module-import-target import))
                   (kind (mognitio.project::module-declaration-kind decl))
                   (symbol (find (mognitio.project::module-declaration-key decl)
                                 (mognitio.semantic:checked-program-bindings checked)
                                 :key #'mognitio.semantic::local-symbol-name :test #'equal))
                   (role (case kind
                           (:contract "interface") ((:type :alias) "type") (:template "function")
                           (otherwise (if (and symbol (mognitio.semantic:function-type-p
                                                       (mognitio.semantic:local-symbol-type symbol)))
                                          "function" "variable"))))
                   (span (mognitio.project::module-import-span import))
                   (mods (+ (if (eq (mognitio.project::module-declaration-origin decl) :standard) 4 0)
                            (if (and symbol (not (eq (mognitio.semantic:local-symbol-mutability symbol) :var))) 2 0))))
              (loop for token across tokens
                    when (and (eq (token-kind token) :identifier)
                              (<= (span-start span) (span-start (token-span token)))
                              (<= (span-end (token-span token)) (span-end span)))
                      do (emit token role mods))))
          (loop for token across tokens do
            (cond ((member (token-kind token) '(:namespace :use)) (setf namespace (token-kind token)))
                  ((eq (token-kind token) :left-brace) (setf namespace nil))
                  ((eq (token-kind token) :semicolon) (setf namespace nil))
                  ((and namespace (eq (token-kind token) :identifier)) (emit token "namespace" (if (eq namespace :namespace) 1 0))))
            (when (rassoc (token-kind token) mognitio.frontend::*keywords*) (emit token "keyword")))
          (setf (gethash (source-path source) output)
                (coerce (sort (gethash source by-source) #'< :key (lambda (row) (aref row 0))) 'vector)))))
    output))
