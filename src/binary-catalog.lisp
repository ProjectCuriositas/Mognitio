(in-package #:mognitio.project)

(defun make-binary-catalog ()
  (let* ((text "public type Bytes=product{};
public type ByteOrder=sum{LittleEndian;BigEndian;};
public type ByteValueError=product{index:Int;value:Int;};
public type BitWidthError=product{width:Int;};
public type BinaryDecodeError=product{width:Int;length:Int;};
public let bytesFromInts:Function(List<Int>):Result<Bytes,ByteValueError>=function(values:List<Int>):Result<Bytes,ByteValueError>{panic{\"compiler body\"}};
public let bytesFromBits:Function(List<Bits<8>>):Bytes=function(values:List<Bits<8>>):Bytes{panic{\"compiler body\"}};
")
         (source (decode-source "standard:Std\\Binary@1.2.0" (utf8 text)))
         (program (mognitio.frontend:parse-program source (mognitio.frontend:lex-source source)))
         (declarations nil))
    (setf (mognitio.source::source-origin source) :standard)
    (loop for binding across (program-statements program) for i from 0
          for op in '(:bytes.from-ints :bytes.from-bits)
          for fn = (local-binding-initializer binding) do
      (let ((body (mognitio.syntax::make-binary-intrinsic
                    :operation op :result-type (function-expression-result-type fn)
                    :arguments (map 'vector (lambda (p) (make-variable-reference :name (parameter-name p) :span (node-span p)))
                                    (function-expression-parameters fn))
                    :span (node-span fn))))
        (setf (aref (program-statements program) i)
              (mognitio.semantic::rebuild-syntax-node binding
                (list (cons 'mognitio.syntax::initializer
                  (mognitio.semantic::rebuild-syntax-node fn (list (cons 'mognitio.syntax::body body)))))))))
    (syntax-walk program
      (lambda (token)
        (let ((name (raw-name token)))
          (unless (member name *predeclared* :test #'equal)
            (setf (mognitio.syntax::token-resolved-name token)
                  (concatenate 'string (if (equal name "Bits") "standard:Std\\Numeric#" "standard:Std\\Binary#") name))))))
    (dolist (node (append (coerce (program-declarations program) 'list) (coerce (program-statements program) 'list)))
      (let* ((token (if (typep node 'local-binding) (local-binding-name node) (data-declaration-name node)))
             (name (raw-name token)))
        (push (make-module-declaration :origin :standard :name name
                :kind (if (typep node 'local-binding) :let :type) :public t
                :token token :node node :key (token-text token)) declarations)))
    (make-standard-catalog :namespace "Std\\Binary" :program program :declarations (nreverse declarations))))

(defun verify-binary-catalog (catalog)
  (let* ((program (standard-catalog-program catalog)) (source (program-source program))
         (types (program-declarations program)) (bindings (program-statements program))
         (decls (standard-catalog-declarations catalog)))
    (labels ((check (ok) (unless ok (internal-error "Invalid binary standard catalog")))
             (shape (node)
               (typecase node
                 (function-type-syntax
                  (list :function (map 'list #'shape (function-type-syntax-parameters node))
                        (shape (function-type-syntax-result node))))
                 (mognitio.syntax::value-argument-syntax
                  (check (and (null (mognitio.syntax::value-argument-syntax-reference node))
                              (not (mognitio.syntax::value-argument-syntax-negative node))))
                  (parse-integer (token-text (mognitio.syntax::value-argument-syntax-digits node))))
                 (type-syntax (cons (shape (type-syntax-name node)) (map 'list #'shape (type-syntax-arguments node))))
                 (token (token-text node)))))
      (check (and (equal "Std\\Binary" (standard-catalog-namespace catalog))
                  (null (standard-catalog-extensions catalog))
                  (eq :standard (mognitio.source::source-origin source))
                  (equal "standard:Std\\Binary@1.2.0" (source-path source))
                  (null (program-root program)) (= 5 (length types)) (= 2 (length bindings)) (= 7 (length decls))))
      (loop for decl in decls for i from 0
            for name in '("Bytes" "ByteOrder" "ByteValueError" "BitWidthError" "BinaryDecodeError" "bytesFromInts" "bytesFromBits")
            for node = (if (< i 5) (aref types i) (aref bindings (- i 5))) do
        (check (and (eq node (module-declaration-node decl)) (eq source (span-source (node-span node)))
                    (eq :standard (module-declaration-origin decl)) (null (module-declaration-module decl))
                    (equal name (module-declaration-name decl)) (module-declaration-public decl)
                    (equal (module-declaration-key decl) (concatenate 'string "standard:Std\\Binary#" name))
                    (eq (module-declaration-kind decl) (if (< i 5) :type :let)))))
      (loop for node across types for i from 0 do
        (check (and (eq (data-declaration-kind node) (if (= i 1) :enum :struct))
                    (zerop (length (data-declaration-type-parameters node))) (null (data-declaration-target node))))
        (check (equal (map 'list (lambda (m) (list (raw-name (named-member-name m))
                                                  (if (= i 1) (named-member-value m) (shape (named-member-value m)))))
                          (data-declaration-members node))
                      (nth i '(nil (("LittleEndian" nil) ("BigEndian" nil))
                               (("index" "Int") ("value" "Int")) (("width" "Int")) (("width" "Int") ("length" "Int")))))))
      (loop for binding across bindings for op in '(:bytes.from-ints :bytes.from-bits)
            for input in '(("List" "Int") ("List" ("standard:Std\\Numeric#Bits" 8)))
            for output in '(("Result" "standard:Std\\Binary#Bytes" "standard:Std\\Binary#ByteValueError") "standard:Std\\Binary#Bytes")
            for fn = (local-binding-initializer binding) for body = (function-expression-body fn) do
        (check (and (eq :let (local-binding-mutability binding))
                    (equal (shape (local-binding-annotation binding)) (list :function (list input) output))
                    (equal (map 'list (lambda (p) (shape (parameter-type p))) (function-expression-parameters fn)) (list input))
                    (equal (shape (function-expression-result-type fn)) output)
                    (zerop (length (function-expression-type-parameters fn)))
                    (typep body 'mognitio.syntax::binary-intrinsic)
                    (eq op (mognitio.syntax::binary-intrinsic-operation body))
                    (equal (shape (mognitio.syntax::binary-intrinsic-result-type body)) output)
                    (= 1 (length (mognitio.syntax::binary-intrinsic-arguments body)))
                    (typep (aref (mognitio.syntax::binary-intrinsic-arguments body) 0) 'variable-reference)
                    (eq (variable-reference-name (aref (mognitio.syntax::binary-intrinsic-arguments body) 0))
                        (parameter-name (aref (function-expression-parameters fn) 0)))))))
    t))
