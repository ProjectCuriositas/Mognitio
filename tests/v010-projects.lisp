(in-package #:mognitio.tests)

(defun project-fixture (files)
  (let* ((root (uiop:ensure-directory-pathname (fresh-path "-project")))
         (manifest (merge-pathnames "mognitio.toml" root)))
    (ensure-directories-exist manifest)
    (put-text manifest (format nil "[project]~%name=\"app\"~%root_namespace=\"App\"~%"))
    (dolist (file files)
      (let ((path (merge-pathnames (concatenate 'string "src/" (car file)) root)))
        (ensure-directories-exist path) (put-text path (cdr file))))
    manifest))

(defun project-checked (manifest)
  (mognitio.driver::checked-project (mognitio.project::load-project (namestring manifest))))

(defun project-oracle (text &optional (expected "true"))
  ;; Preserve the old expression oracle, but execute it through the current
  ;; declaration-only module and argument/status entry contract.
  (let ((program (parse-text text)))
    (labels ((fragment (node)
               (let ((span (node-span node))) (subseq text (span-start span) (span-end span)))))
      (format nil "namespace App;~%~{~A~%~}let main: Function(List<String>): Int = function(args: List<String>): Int {~%~{~A~%~}branch when { (~A) == ~A => 0, else => panic {\"fixture mismatch\"} } };~%"
              (map 'list #'fragment (program-declarations program))
              (map 'list #'fragment (program-statements program))
              (fragment (program-root program)) expected))))

(defun expect-project (manifest &optional options)
  (let* ((checked (project-checked manifest))
         (mognitio.native.runtime::*test-options* options)
         (path (put-bytes (fresh-path ".elf")
                         (mognitio.backend.native:compile-program checked (mognitio.target:linux-amd64)))))
    (same 0 (execute-program (compile-program checked)))
    (sb-posix:chmod (namestring path) #o700)
    (multiple-value-bind (out err code) (process-result (list (namestring path)))
      (same 0 code) (same "" out) (same "" err))))

(deftest v010-current-entry-language-matrix
  (dolist (fixture *v09-positive-fixtures*)
    (handler-case
        (expect-project (project-fixture (list (cons "app.mgn" (project-oracle (second fixture))))))
      (error (e) (error "Project fixture ~A: ~A" (first fixture) e)))))

(deftest v010-project-lifetime
  (dolist (stress '(nil t))
    (expect-project (project-fixture (list (cons "app.mgn" (project-oracle *v09-lifetime-source*))))
                    (list :arena-unit 4096 :cap 4096 :validate t :stress stress))))

(deftest v010-project-proof-mutations
  (dolist (mutation '(:identity :public :import :alias :dependency :order :module :plan :resolved :entry :source-order))
    (let* ((manifest (project-fixture
                       '(("app.mgn" . "namespace App; use App\\{value}; let main: Function(List<String>): Int = function(args: List<String>): Int { discard value; 0 };")
                         ("lib.mgn" . "namespace App; public let value: Int = 42; let other:Int=0;"))))
           (checked (project-checked manifest)) (program (checked-program-program checked))
           (project (mognitio.syntax::program-project program))
           (entry (mognitio.project::project-entry project))
           (lib (second (mognitio.project::project-modules project)))
           (decl (first (mognitio.project::source-module-declarations lib)))
           (import (first (mognitio.project::source-module-imports entry))))
      (ecase mutation
        (:identity (setf (mognitio.project::module-declaration-key decl) "forged"))
        (:public (setf (mognitio.project::module-declaration-public decl) nil))
        (:import (setf (mognitio.project::module-import-target import) nil))
        (:alias (setf (gethash "foreign" (mognitio.project::source-module-names entry)) decl))
        (:dependency (setf (mognitio.project::source-module-dependencies entry) nil))
        (:order (setf (mognitio.project::project-order project) (reverse (mognitio.project::project-order project))))
        (:module (pop (mognitio.syntax::program-modules program)))
        (:plan (rotatef (aref (program-statements program) 0) (aref (program-statements program) 1)))
        (:resolved (setf (mognitio.syntax::token-resolved-name (mognitio.project::module-declaration-token decl)) "forged"))
        (:entry (setf (mognitio.project::project-entry project) lib))
        (:source-order (let ((statements (program-statements (mognitio.project::source-module-program lib))))
                         (rotatef (aref statements 0) (aref statements 1)))))
      (signals internal-failure (verify-checked-program checked))))
  (let ((checked (project-checked (project-fixture '(("app.mgn" . "namespace App; let main:Function(List<String>): Int=function(args: List<String>): Int{0};"))))))
    (replacing (mognitio.project::resolve-project (lambda (&rest args) (declare (ignore args)) (error "Resolver called")))
      (is (verify-checked-program checked)))))

(deftest v010-special-files-before-reader
  (dolist (kind '(:fifo :socket))
    (let* ((manifest (project-fixture '(("app.mgn" . "namespace App; let main:Function(List<String>): Int=function(args: List<String>): Int{0};"))))
           (root (uiop:pathname-directory-pathname manifest))
           (path (merge-pathnames "src/special.mgn" root))
           (original (fdefinition 'mognitio.source::read-octets)) (called nil))
      (if (eq kind :fifo) (sb-posix:mkfifo (namestring path) #o600)
          (uiop:run-program (list "python3" "-c" "import socket,sys;s=socket.socket(socket.AF_UNIX);s.bind(sys.argv[1])" (namestring path))))
      (replacing (mognitio.source::read-octets
                    (lambda (source)
                      (when (equal source (namestring path)) (setf called t) (error "Special reader reached"))
                      (funcall original source)))
        (signals usage-or-io-failure (mognitio.project::load-project (namestring manifest))))
      (is (not called)))))

(deftest v010-publication-faults
  (let* ((manifest (project-fixture '(("app.mgn" . "namespace App; let main:Function(List<String>): Int=function(args: List<String>): Int{0};"))))
         (source (merge-pathnames "src/app.mgn" (uiop:pathname-directory-pathname manifest)))
         (before (read-bytes source)) (output (fresh-path ".elf")))
    (dolist (name '(mognitio.ir:lower-program mognitio.ir:verify-module mognitio.machine:lower-module
                   mognitio.amd64:encode mognitio.elf:make-image
                   mognitio.artifact::write-image mognitio.artifact::flush-image
                   mognitio.artifact::set-executable mognitio.artifact::close-image mognitio.artifact::replace-image))
      (put-text output "keep")
      (let ((original (fdefinition name)))
        (unwind-protect
            (progn
              (setf (fdefinition name) (lambda (&rest args) (declare (ignore args)) (error "Injected")))
              (let ((out (make-string-output-stream)) (err (make-string-output-stream)))
                (is (member (mognitio.driver:run-cli (list "build" (namestring manifest) "-o" (namestring output)) out err) '(2 3)))
                (same "" (get-output-stream-string out))))
          (setf (fdefinition name) original)))
      (same "keep" (uiop:read-file-string output)) (same before (read-bytes source))
      (same nil (temporary-images)))))

(deftest v010-cross-module-lifetime
  (let ((manifest (project-fixture
                    '(("app.mgn" . "namespace App; use App\\{left,right,readLeft}; let main:Function(List<String>): Int=function(args: List<String>): Int{var i:Int=0;loop while(i<800){discard List<String>[\"dead\"+\"!\"];i=i+1;};branch when{left->read()==\"left!\"&&right->read()==\"right!\"&&readLeft()==\"left!\"=> 0,else=>panic{\"lifetime\"}}};")
                      ("contract.mgn" . "namespace App; public contract Read{read(self:Self):String;}")
                      ("left.mgn" . "namespace App; use App\\{Read}; type Hidden=product{text:String;}; witness Proof=Hidden implements Read{read(self:Self):String{self->text}} let text:String=\"left\"+\"!\"; public let left:Read=Read(Hidden{text:text}); public let readLeft:Function():String=function():String{text};")
                      ("right.mgn" . "namespace App; use App\\{Read}; type Hidden=product{text:String;}; witness Proof=Hidden implements Read{read(self:Self):String{self->text}} public let right:Read=Read(Hidden{text:\"right\"+\"!\"});")))))
    (dolist (stress '(nil t))
      (expect-project manifest (list :arena-unit 4096 :cap 4096 :validate t :stress stress)))))

(deftest v010-symbolic-public-signature-proof
  ;; Bypass the producer check to create a malformed proof, then require the
  ;; verifier to reject it. Visibility uses a shared walker; the source type
  ;; records and module provenance are verified separately.
  (let* ((manifest (project-fixture
                     '(("app.mgn" . "namespace App;let main:Function(List<String>): Int=function(args: List<String>): Int{0};")
                       ("lib.mgn" . "namespace App;type Hidden<T>=product{value:T;};public alias Exposed<T>=Hidden<T>;"))))
         (checked (replacing (mognitio.project::check-public-signatures
                               (lambda (program) (declare (ignore program)) nil))
                    (project-checked manifest))))
    (signals internal-failure (verify-checked-program checked))))
