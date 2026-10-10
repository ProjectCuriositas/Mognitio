(in-package #:mognitio.project)

(defun project-catalogs (project)
  (let ((root (project-standard project)))
    (cons root (standard-catalog-extensions root))))

(defun make-numeric-catalog ()
  (let* ((source (decode-source "standard:Std\\Numeric@1.2.0"
                   (utf8 "public type Signed = product {};
public type Unsigned = product {};
public type Bits<N:Int> = product {};
public type IntegerConversionError = product {};
public type BitShiftError = product { count:Int; width:Int; };
")))
         (program (mognitio.frontend:parse-program source (mognitio.frontend:lex-source source)))
         (declarations nil))
    (setf (mognitio.source::source-origin source) :standard)
    (syntax-walk program
      (lambda (token)
        (let ((name (raw-name token)))
          (unless (member name *predeclared* :test #'equal)
            (setf (mognitio.syntax::token-resolved-name token)
                  (concatenate 'string "standard:Std\\Numeric#" name))))))
    (loop for node across (program-declarations program)
          for token = (data-declaration-name node) for name = (raw-name token) do
      (push (make-module-declaration :origin :standard :name name :kind :type :public t
              :token token :node node :key (token-text token)) declarations))
    (make-standard-catalog :namespace "Std\\Numeric" :program program
                           :declarations (nreverse declarations))))

(defun verify-numeric-catalog (catalog)
  ;; Verify independent closed shapes and provenance, not a regenerated catalog.
  (let* ((program (standard-catalog-program catalog)) (source (program-source program))
         (nodes (program-declarations program)) (decls (standard-catalog-declarations catalog)))
    (flet ((check (ok) (unless ok (internal-error "Invalid numeric catalog"))))
      (check (and (equal (standard-catalog-namespace catalog) "Std\\Numeric")
                  (null (standard-catalog-extensions catalog))
                  (eq (mognitio.source::source-origin source) :standard)
                  (equal (source-path source) "standard:Std\\Numeric@1.2.0")
                  (null (program-root program)) (zerop (length (program-statements program)))
                  (= 5 (length nodes) (length decls))))
      (loop for node across nodes for decl in decls for index from 0
            for name in '("Signed" "Unsigned" "Bits" "IntegerConversionError" "BitShiftError")
            for key = (concatenate 'string "standard:Std\\Numeric#" name) do
        (check (and (eq node (module-declaration-node decl))
                    (eq (span-source (node-span node)) source)
                    (eq :standard (module-declaration-origin decl)) (null (module-declaration-module decl))
                    (module-declaration-public decl) (eq :type (module-declaration-kind decl))
                    (equal name (module-declaration-name decl)) (equal key (module-declaration-key decl))
                    (equal key (token-text (data-declaration-name node)))
                    (eq :struct (data-declaration-kind node)) (null (data-declaration-target node))))
        (let ((parameters (data-declaration-type-parameters node)))
          (check (= (length parameters) (if (= index 2) 1 0)))
          (when (= index 2)
            (let ((p (aref parameters 0)))
              (check (and (typep p 'mognitio.syntax::value-parameter-syntax)
                          (equal (raw-name p) "N")
                          (equal (token-text (mognitio.syntax::value-parameter-syntax-domain p)) "Int"))))))
        (check (equal (map 'list (lambda (field)
                                  (list (raw-name (named-member-name field))
                                        (token-text (named-member-value field))))
                                (data-declaration-members node))
                      (when (= index 4) '(("count" "Int") ("width" "Int")))))))
    t))
