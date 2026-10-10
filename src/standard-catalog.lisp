(in-package #:mognitio.project)

(defstruct standard-catalog program declarations (namespace "Std\\Io") extensions)

(defun standard-namespace-p (name)
  (equal "Std" (first (namespace-parts name))))
(defun standard-key (name) (concatenate 'string "standard:Std\\Io#" name))

(defun make-io-catalog ()
  ;; This compiler-owned source identity is diagnostic provenance, never a file
  ;; in project discovery or initialization ordering.
  (let* ((text "public type IoOperation = sum { ReadTextFile; WriteTextFile; ReadStdin; WriteStdout; WriteStderr; JoinPath; ReadDirectory; CreateDirectory; };
public type IoErrorKind = sum { InvalidPath; InvalidEncoding; NotFound; PermissionDenied; UnsupportedTarget; BrokenPipe; ResourceExhausted; Other; };
public type IoError = product { operation: IoOperation; kind: IoErrorKind; subject: String; phase: IoErrorPhase; };
public type DirectoryEntryKind = sum { File; Directory; Symlink; Other; };
public type DirectoryEntry = product { name: String; kind: DirectoryEntryKind; };
public type IoErrorPhase = sum { Input; Target; Body; Cleanup; };
public let readTextFile: Function(String): Result<String,IoError> = function(path:String): Result<String,IoError> { panic { \"compiler body\" } };
public let writeTextFile: Function(String,String): Result<Unit,IoError> = function(path:String,text:String): Result<Unit,IoError> { panic { \"compiler body\" } };
public let readStdin: Function(): Result<String,IoError> = function(): Result<String,IoError> { panic { \"compiler body\" } };
public let writeStdout: Function(String): Result<Unit,IoError> = function(text:String): Result<Unit,IoError> { panic { \"compiler body\" } };
public let writeStderr: Function(String): Result<Unit,IoError> = function(text:String): Result<Unit,IoError> { panic { \"compiler body\" } };
public let joinPath: Function(String,String): Result<String,IoError> = function(base:String,relative:String): Result<String,IoError> { panic { \"compiler body\" } };
public let readDirectory: Function(String): Result<List<DirectoryEntry>,IoError> = function(path:String): Result<List<DirectoryEntry>,IoError> { panic { \"compiler body\" } };
public let createDirectory: Function(String): Result<Unit,IoError> = function(path:String): Result<Unit,IoError> { panic { \"compiler body\" } };")
         (source (decode-source "standard:Std\\Io@0.14.0" (utf8 text)))
         (program (mognitio.frontend:parse-program source (mognitio.frontend:lex-source source)))
         (declarations nil))
    (setf (mognitio.source::source-origin source) :standard)
    (loop for binding across (program-statements program)
          for index from 0
          for operation = (or (cdr (assoc (raw-name (local-binding-name binding))
                                    '(("readTextFile" . :read-file) ("writeTextFile" . :write-file)
                                      ("readStdin" . :read-stdin) ("writeStdout" . :write-stdout)
                                      ("writeStderr" . :write-stderr) ("joinPath" . :join-path)
                                      ("readDirectory" . :read-directory) ("createDirectory" . :create-directory))
                                    :test #'equal)) (internal-error "Unknown standard I/O binding")) do
      (let* ((function (local-binding-initializer binding))
             (body (mognitio.syntax::make-io-expression :operation operation
                     :arguments (map 'vector (lambda (p) (make-variable-reference :name (parameter-name p) :span (node-span p)))
                                     (function-expression-parameters function))
                     :result-type (function-expression-result-type function) :span (node-span function))))
        (setf (aref (program-statements program) index)
              (mognitio.semantic::rebuild-syntax-node binding
                (list (cons 'mognitio.syntax::initializer
                  (mognitio.semantic::rebuild-syntax-node function (list (cons 'mognitio.syntax::body body)))))))))
    (dolist (node (append (coerce (program-declarations program) 'list) (coerce (program-statements program) 'list)))
      (let* ((token (if (typep node 'local-binding) (local-binding-name node) (mognitio.semantic::declaration-name node)))
             (name (raw-name token)))
        (push (make-module-declaration :origin :standard :name name :kind (if (typep node 'local-binding) :let :type)
                                      :public t :token token :node node :key (standard-key name)) declarations)))
    (syntax-walk program
      (lambda (token)
        (let ((name (raw-name token)))
          (unless (member name *predeclared* :test #'equal)
            (setf (mognitio.syntax::token-resolved-name token) (standard-key name))))))
    (make-standard-catalog :program program :declarations (nreverse declarations)
                           :extensions (list (make-numeric-catalog)))))

(defun standard-exports (project)
  (let ((table (make-hash-table :test #'equal)))
    (dolist (catalog (project-catalogs project))
      (dolist (decl (standard-catalog-declarations catalog))
        (setf (gethash (cons (standard-catalog-namespace catalog) (module-declaration-name decl)) table) decl)))
    table))

(defun standard-declarations (project)
  (loop for catalog in (project-catalogs project)
        append (coerce (program-declarations (standard-catalog-program catalog)) 'list)))
(defun standard-prelude (project)
  (loop for catalog in (project-catalogs project)
        append (coerce (program-statements (standard-catalog-program catalog)) 'list)))

(defun verify-standard-catalog (project)
  ;; Check the supplied records against the closed language surface, without
  ;; rerunning the catalog producer or accepting its cached exports as evidence.
  (let* ((catalog (project-standard project)) (program (standard-catalog-program catalog))
         (source (program-source program)) (decls (standard-catalog-declarations catalog)))
    (flet ((check (ok) (unless ok (internal-error "Invalid standard catalog provenance or body"))))
      (check (and (equal (standard-catalog-namespace catalog) "Std\\Io")
                  (eq (mognitio.source::source-origin source) :standard)
                  (equal (source-path source) "standard:Std\\Io@0.14.0")
                  (null (program-root program)) (= (length decls) 14)
                  (= (length (program-declarations program)) 6) (= (length (program-statements program)) 8)))
      (loop for decl in decls for name in '("IoOperation" "IoErrorKind" "IoError" "DirectoryEntryKind" "DirectoryEntry" "IoErrorPhase" "readTextFile" "writeTextFile" "readStdin" "writeStdout" "writeStderr" "joinPath" "readDirectory" "createDirectory")
            for index from 0 for node = (module-declaration-node decl) do
        (check (and (eq (module-declaration-origin decl) :standard) (null (module-declaration-module decl))
                    (module-declaration-public decl) (equal name (module-declaration-name decl))
                    (equal (module-declaration-key decl) (concatenate 'string "standard:Std\\Io#" name))
                    (eq (span-source (node-span node)) source)
                    (eq node (if (< index 6) (aref (program-declarations program) index)
                                 (aref (program-statements program) (- index 6))))))
        (if (< index 6)
            (check (and (eq (module-declaration-kind decl) :type) (typep node 'data-declaration)))
            (let* ((function (local-binding-initializer node)) (body (function-expression-body function))
                   (parameters (function-expression-parameters function)))
              (check (and (eq (module-declaration-kind decl) :let) (typep body 'mognitio.syntax::io-expression)
                          (eq (mognitio.syntax::io-expression-operation body)
                              (nth (- index 6) '(:read-file :write-file :read-stdin :write-stdout :write-stderr :join-path :read-directory :create-directory)))
                          (= (length parameters) (nth (- index 6) '(1 2 0 1 1 2 1 1)))
                          (= (length parameters) (length (mognitio.syntax::io-expression-arguments body)))))
              (loop for parameter across parameters for argument across (mognitio.syntax::io-expression-arguments body) do
                (check (and (typep argument 'variable-reference) (eq (variable-reference-name argument) (parameter-name parameter))))))))))
  (verify-standard-shapes (project-standard project))
  (let ((extensions (standard-catalog-extensions (project-standard project))))
    (unless (= 1 (length extensions)) (internal-error "Missing numeric catalog"))
    (verify-numeric-catalog (first extensions)))
  t)

(in-package #:mognitio.semantic)

(defun io-signature (context operation)
  (let* ((error-type (gethash "standard:Std\\Io#IoError" (value-context-names context)))
         (entry-type (gethash "standard:Std\\Io#DirectoryEntry" (value-context-names context)))
         (success (case operation ((:read-file :read-stdin :join-path) :string)
                    (:read-directory (list :list entry-type)) (otherwise :void)))
         (arguments (ecase operation (:read-file '(:string)) (:write-file '(:string :string))
                       (:read-stdin nil) ((:write-stdout :write-stderr :read-directory :create-directory) '(:string))
                       (:join-path '(:string :string)))))
    (unless (nominal-type-p error-type :struct) (internal-error "Missing standard IoError identity"))
    (unless (nominal-type-p entry-type :struct) (internal-error "Missing standard DirectoryEntry identity"))
    (values arguments success error-type)))

(defun c-io-expression (node)
  (let* ((operation (mognitio.syntax::io-expression-operation node))
         (args (coerce (mognitio.syntax::io-expression-arguments node) 'list))
         (children (mapcar #'c-expression args))
         (result (resolve-type-token (c-context) (mognitio.syntax::io-expression-result-type node))))
    (multiple-value-bind (parameters success error-type) (io-signature (c-context) operation)
      (unless (and (= (length parameters) (length args))
                   (equal (canonical-result-arguments (c-context) result) (list success error-type)))
        (internal-error "Invalid standard I/O signature"))
      (loop for arg in args for child in children for type in parameters do (c-context-check arg child type))
      (c-operation node operation args parameters result)
      (c-summary node result (every #'c-normal children) children))))

(defun v-io-expression (node)
  (let* ((args (coerce (mognitio.syntax::io-expression-arguments node) 'list))
         (operation (mognitio.syntax::io-expression-operation node))
         (result (v-resolve (mognitio.syntax::io-expression-result-type node)))
         (info (checked-operation (v-program) node)))
    (mapc #'v-visit args)
    (multiple-value-bind (parameters success error-type) (io-signature (v-context) operation)
      (v-check (and (= (length args) (length parameters)) (equal (canonical-result-arguments (v-context) result) (list success error-type))
                    (eq (operation-info-kind info) operation) (equal (operation-info-operands info) args)
                    (equal (operation-info-parameter-types info) parameters) (equal (operation-info-result-type info) result))
               "Invalid I/O body proof")
      (loop for arg in args for type in parameters do (v-exact arg type))
      (v-finish node result (every #'v-normal args) args))))
