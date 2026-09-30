(in-package #:mognitio.testing)

(defstruct test-case ordinal declaration identity span sites path (fd -1) created
  (state :not-run) kind (stage 0) reported)
(defstruct test-plan project checked cases)
(defstruct preparation-session name directory-owned directory cases)
(sb-alien:define-alien-routine ("mkdtemp" raw-mkdtemp) sb-alien:system-area-pointer
  (name sb-alien:system-area-pointer))
(sb-alien:define-alien-routine ("rmdir" raw-rmdir) sb-alien:int (name sb-alien:system-area-pointer))
(sb-alien:define-alien-routine ("open" raw-open) sb-alien:int
  (name sb-alien:system-area-pointer) (flags sb-alien:int) (mode sb-alien:unsigned-int))

(defun discover-tests (project checked)
  (let ((cases nil))
    (dolist (module (mognitio.project::project-modules project))
      (dolist (decl (mognitio.project::source-module-declarations module))
        (let* ((node (mognitio.project::module-declaration-node decl))
               (attributes (gethash node (mognitio.semantic::checked-program-attributes checked))))
          (when (and attributes (eq :test (mognitio.semantic::checked-attribute-kind attributes)))
            (push (make-test-case :declaration decl :span (mognitio.syntax:declaration-span node)
                    :identity (format nil "~A::~A::~A" (mognitio.project::source-module-path module)
                                      (mognitio.project::source-module-namespace module)
                                      (mognitio.project::module-declaration-name decl))) cases)))))
    (setf cases (sort cases (lambda (a b)
      (let ((ap (mognitio.source:source-path (mognitio.source:span-source (test-case-span a))))
            (bp (mognitio.source:source-path (mognitio.source:span-source (test-case-span b)))))
        (or (string< ap bp) (and (string= ap bp) (< (mognitio.source:span-start (test-case-span a))
                                                   (mognitio.source:span-start (test-case-span b)))))))))
    (loop for test in cases for n from 0 do (setf (test-case-ordinal test) n))
    (coerce cases 'vector)))

(defun make-checked-test-plan (manifest)
  (let* ((project (mognitio.project::resolve-project
                   (mognitio.project::load-project manifest :entry-policy :test-check)))
         (checked (mognitio.semantic:check-program (mognitio.project::project-program project))))
    (mognitio.semantic:verify-checked-program checked)
    (verify-test-plan (make-test-plan :project project :checked checked :cases (discover-tests project checked)))))

(defun compile-test-image (plan test)
  ;; Recheck wrappers against the same resolved, immutable source snapshot.
  ;; Only entry policy changes; no source lookup or discovery is repeated here.
  (let* ((mognitio.ir::*test-ordinal* (test-case-ordinal test))
         (checked (mognitio.semantic:check-program
                    (mognitio.project::project-program (test-plan-project plan) (test-case-declaration test))))
         (ir (mognitio.ir:lower-program checked))
         (machine (mognitio.machine:lower-module (mognitio.ir:verify-module ir))))
    (setf (test-case-sites test) (mognitio.ir::module-assertion-sites ir))
    (multiple-value-bind (code symbols) (mognitio.amd64:encode machine)
      (mognitio.backend.native::verify-native-metadata ir code symbols)
      (mognitio.elf:make-image code))))

(defun prepare-directory (session)
  (let ((name (sb-ext:string-to-octets "/tmp/mgn-test-XXXXXX" :external-format :utf-8 :null-terminate t)))
    (setf (preparation-session-name session) name)
    (sb-sys:with-pinned-objects (name)
      (let ((sap (sb-sys:vector-sap name)))
        (sb-sys:without-interrupts
          (setf (preparation-session-directory-owned session)
                (not (zerop (sb-sys:sap-int (raw-mkdtemp sap))))))))
    (unless (preparation-session-directory-owned session) (runner-io "Cannot create test image directory"))
    (setf (preparation-session-directory session)
          (sb-ext:octets-to-string name :end (1- (length name)) :external-format :utf-8))))

(defun prepare-image (test image)
  (let ((name (sb-ext:string-to-octets (test-case-path test) :external-format :utf-8 :null-terminate t)))
    (sb-sys:with-pinned-objects (name)
      (let ((sap (sb-sys:vector-sap name)))
        (sb-sys:without-interrupts
          (setf (test-case-fd test) (raw-open sap (logior sb-posix:o-wronly sb-posix:o-creat
                                                        sb-posix:o-excl #x80000) #o600)
                (test-case-created test) (>= (test-case-fd test) 0)))))
    (unless (test-case-created test) (runner-io "Cannot create test image"))
    (runner-hook :image-created test)
    (let ((offset 0) (retries 0))
      (loop while (< offset (length image)) do
        (let ((count (mognitio.runtime::write-chunk (test-case-fd test) image offset (- (length image) offset))))
          (cond ((plusp count) (incf offset count) (setf retries 0))
                ((and (= count (- sb-posix:eintr)) (< (incf retries) 16)))
                (t (runner-io "Cannot write test image"))))))
    (sb-posix:fchmod (test-case-fd test) #o700)
    (close-test-image test)))

(defun close-test-image (test)
  (let ((result 0))
    (sb-sys:without-interrupts
      (when (>= (test-case-fd test) 0)
        (setf result (raw-close (test-case-fd test)) (test-case-fd test) -1)))
    (unless (zerop result) (runner-io "Cannot close test image"))))

(defun prepare-suite (session plan)
  (verify-test-plan plan)
  (when (plusp (length (test-plan-cases plan)))
    (prepare-directory session)
    (loop for test across (test-plan-cases plan) do
      (setf (test-case-path test) (format nil "~A/~D" (preparation-session-directory session) (test-case-ordinal test)))
      (mognitio.project::validate-project-output (test-plan-project plan) (test-case-path test))
      (runner-hook :before-compile test)
      (prepare-image test (compile-test-image plan test))
      (runner-hook :image-prepared test)))
  (runner-hook :suite-prepared session))

(defun cleanup-preparation (session)
  (let ((failures nil))
    (flet ((protect (path thunk)
             (handler-case (funcall thunk) (error () (push path failures)))))
      (loop for test across (preparation-session-cases session) do
        (protect (test-case-path test) (lambda () (close-test-image test)))
        (when (test-case-created test)
          (protect (test-case-path test) (lambda ()
            (sb-posix:unlink (test-case-path test)) (setf (test-case-created test) nil)))))
      (when (preparation-session-directory-owned session)
        (protect (or (preparation-session-directory session) "test temporary directory")
          (lambda ()
            (let ((name (preparation-session-name session)))
              (sb-sys:with-pinned-objects (name)
                (unless (zerop (raw-rmdir (sb-sys:vector-sap name))) (runner-io "Cannot remove test directory"))))
            (setf (preparation-session-directory-owned session) nil)))))
    (nreverse failures)))
