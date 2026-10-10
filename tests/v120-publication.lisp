(in-package #:mognitio.tests)

(defparameter *v120-publication-imports*
  "use Std\\Numeric\\{Bits};use Std\\Binary\\{Bytes,bytesFromBits,publishFile,BinaryFileMode,BinaryOutputError,BinaryOutputErrorKind,BinaryOutputPhase,BinaryPublicationState};")
(defun v120-publication-manifest (body)
  (project-fixture (list (cons "app.mgn" (format nil "namespace App;~Alet main:Function(List<String>):Int=function(args:List<String>):Int{~A};"
                                                   *v120-publication-imports* body)))))
(defun v120-enum-check (expression type names expected)
  (format nil "branch on ~A {~{~A~^,~}}" expression
    (loop for name in names collect (format nil "~A::~A=>~A" type name (if (equal expected name) "true" "false")))))
(defun v120-publication-body (path kind phase state)
  (format nil "let data:Bytes=bytesFromBits(List<Bits<8>>[Bits<8>{0},Bits<8>{128},Bits<8>{255}]);branch on publishFile(~S,data,BinaryFileMode::Data){Result<Unit,BinaryOutputError>::Ok(x:Unit)=>~D,Result<Unit,BinaryOutputError>::Err(e:BinaryOutputError)=>branch when{(~A) && (~A) && (~A) && e->subject==~S =>0,else=>2}}"
    path (if kind 1 0)
    (v120-enum-check "e->kind" "BinaryOutputErrorKind" '("InvalidPath" "AlreadyExists" "NotFound" "PermissionDenied" "UnsupportedTarget" "ResourceExhausted" "Other") kind)
    (v120-enum-check "e->phase" "BinaryOutputPhase" '("Input" "Target" "Body" "Publish" "Cleanup") phase)
    (v120-enum-check "e->publication" "BinaryPublicationState" '("NotPublished" "Published" "Unknown") state) path))
(defun v120-publication-path () (namestring (fresh-path ".binary")))

(deftest v120-publication-faults
  (dolist (row '((:open-parent -2 "NotFound" "Target" "NotPublished")
                 (:target-stat -13 "PermissionDenied" "Target" "NotPublished")
                 (:filesystem -5 "Other" "Target" "NotPublished")
                 (:mount-id -38 "UnsupportedTarget" "Target" "NotPublished")
                 (:open-probe -24 "ResourceExhausted" "Target" "NotPublished")
                 (:read-probe -5 "Other" "Target" "NotPublished")
                 (:close-probe -5 "Other" "Cleanup" "NotPublished")
                 (:open-temp -28 "ResourceExhausted" "Target" "NotPublished")
                 (:temp-stat -5 "Other" "Target" "NotPublished")
                 (:write -28 "ResourceExhausted" "Body" "NotPublished")
                 (:write 0 "Other" "Body" "NotPublished")
                 (:close-file -5 "Other" "Cleanup" "NotPublished")
                 (:commit -17 "AlreadyExists" "Publish" "NotPublished")
                 (:commit -28 "ResourceExhausted" "Publish" "NotPublished")
                 (:commit -38 "UnsupportedTarget" "Publish" "NotPublished")
                 (:commit -5 "Other" "Publish" "Unknown")
                 (:close-parent -5 "Other" "Cleanup" "Published")))
    (destructuring-bind (phase status kind public-phase state) row
      (dolist (native '(nil t))
        (let* ((path (v120-publication-path))
               (manifest (v120-publication-manifest (v120-publication-body path kind public-phase state)))
               (count 0)
               (mognitio.io::*publication-fault-hook*
                 (lambda (at) (when (and (eq phase at) (= 1 (incf count))) status))))
          (multiple-value-bind (out err code)
              (if native
                  (process-result (list (namestring (v12-native manifest (list :publication-faults (list (list phase 1 status)))))))
                  (v12-driver manifest))
            (unless (and (= code 0) (equal out "") (equal err ""))
              (error "Publication fault ~S native=~S: code=~D out=~S err=~S" row native code out err))
            (same 0 code))
          (same (equal state "Published") (not (null (probe-file path))))
          (when (probe-file path) (delete-file path)))))))

(deftest v120-publication-short-write-and-unknown
  (dolist (native '(nil t))
    (let* ((path (v120-publication-path))
           (manifest (v120-publication-manifest (v120-publication-body path nil nil nil)))
           (original (fdefinition 'mognitio.io::publication-syscall)))
      (replacing (mognitio.io::publication-syscall
        (lambda (number a b c d e f)
          (funcall original number a b (if (= number 1) (min 1 c) c) d e f)))
        (multiple-value-bind (out err code)
            (if native (process-result (list (namestring (v12-native manifest '(:publication-faults ((:write 0 1 :limit)))))))
                (v12-driver manifest))
          (same 0 code) (same "" out) (same "" err)))
      (with-open-file (in path :element-type '(unsigned-byte 8))
        (same '(0 128 255) (loop for x = (read-byte in nil) while x collect x)))
      (delete-file path)))
  ;; A real successful commit whose reply is replaced by EIO remains Unknown.
  ;; This checks defensive classification, not a filesystem atomicity proof.
  (dolist (native '(nil t))
    (let* ((path (v120-publication-path))
           (manifest (v120-publication-manifest (v120-publication-body path "Other" "Publish" "Unknown")))
           (original (fdefinition 'mognitio.io::publication-syscall)))
      (replacing (mognitio.io::publication-syscall
        (lambda (number a b c d e f)
          (let ((status (funcall original number a b c d e f)))
            (if (and (= number 316) (= status 0))
                (progn (setf (sb-sys:sap-ref-32 (mognitio.io::directory-errno) 0) 5) -1)
                status))))
        (multiple-value-bind (out err code)
            (if native (process-result (list (namestring (v12-native manifest '(:publication-faults ((:commit 1 -5 t)))))))
                (v12-driver manifest))
          (same 0 code) (same "" out) (same "" err)))
      (is (probe-file path)) (delete-file path))))

(deftest v120-publication-primary-cleanup
  (dolist (native '(nil t))
    (let* ((path (v120-publication-path))
           (manifest (v120-publication-manifest (v120-publication-body path "ResourceExhausted" "Body" "NotPublished")))
           (mognitio.io::*publication-fault-hook* (lambda (at) (case at (:write -28) (:close-file -5) (:close-parent -5)))))
      (multiple-value-bind (out err code)
          (if native (process-result (list (namestring (v12-native manifest '(:publication-faults ((:write 1 -28) (:close-file 1 -5) (:close-parent 1 -5)))))))
              (v12-driver manifest))
        (same 0 code) (same "" out) (same "" err))
      (is (not (probe-file path))))))

(defun v120-host-publication-barrier (manifest)
  (let ((runner (fresh-path ".lisp")) (wrapper (fresh-path ".sh")))
    (put-text runner
      (format nil "(require :asdf)~%(asdf:load-asd ~S)~%(asdf:load-system \"mognitio/tests\")~%
(in-package :mognitio.tests)
(let ((mognitio.io::*publication-fault-hook*
        (lambda (phase)
          (when (eq phase :commit)
            (let ((data (make-array 1 :element-type '(unsigned-byte 8) :initial-element 1)))
              (sb-sys:with-pinned-objects (data)
                (let ((address (sb-sys:sap-int (sb-sys:vector-sap data))))
                  (assert (= 1 (mognitio.io::publication-syscall 1 6 address 1 0 0 0)))
                  (assert (= 1 (mognitio.io::publication-syscall 0 7 address 1 0 0 0)))))))
          nil)))
  (multiple-value-bind (out err code) (v12-driver (pathname ~S))
    (write-string out *standard-output*) (write-string err *error-output*) (uiop:quit code)))~%"
        (namestring (root-path "mognitio.asd")) (namestring manifest)))
    (put-text wrapper (format nil "#!/bin/sh~%exec sbcl --noinform --script '~A'~%" (namestring runner)))
    (sb-posix:chmod (namestring wrapper) #o700)
    wrapper))

(deftest v120-publication-commit-barrier
  (dolist (native '(nil t))
    (dolist (mode '("race" "file" "directory"))
      (let* ((path (v120-publication-path))
             (body (v120-publication-body path "AlreadyExists" "Publish" "NotPublished")))
        (when (equal mode "race")
          (flet ((replace-once (text old new)
                   (let ((at (or (search old text) (error "Missing barrier fixture text ~S" old))))
                     (concatenate 'string (subseq text 0 at) new (subseq text (+ at (length old)))))))
            (setf body (replace-once body "Ok(x:Unit)=>1" "Ok(x:Unit)=>0")
                  body (replace-once body "=>0,else=>2" "=>11,else=>2"))))
        (let* ((manifest (v120-publication-manifest body))
               (image (if native (v12-native manifest '(:publication-barrier t))
                          (v120-host-publication-barrier manifest))))
          (multiple-value-bind (out err code)
              (process-result (list "python3" (namestring (root-path "tests/v120-publication-barrier.py"))
                                   (namestring image) path mode))
            (unless (= code 0)
              (error "Publication barrier ~A native=~S: code=~D out=~S err=~S" mode native code out err))
            (same 0 code) (same "" err) (is (search "PUBLICATION_BARRIER_OK" out))))
        (if (equal mode "directory") (sb-posix:rmdir path) (delete-file path))))))

(deftest v120-publication-machine-proof
  (dolist (mutation '(:roots :frame :flag :cleanup :allocation))
    (let* ((ir (mognitio.ir:lower-program (project-checked (v120-publication-manifest "0"))))
           (mognitio.native.runtime::*runtime-module* ir) (units nil)
           (original (fdefinition 'mognitio.native.runtime::verify-io-units)))
      (replacing (mognitio.native.runtime::verify-io-units (lambda (value) (setf units value) (funcall original value)))
        (mognitio.machine:lower-module ir))
      (let* ((unit (find-if (lambda (u) (let ((entry (mognitio.object:code-unit-entry u)))
                                           (and (consp entry) (consp (second entry)) (eq (first (second entry)) :binary.publish)))) units))
             (instructions (mognitio.object:code-unit-instructions unit)))
        (flet ((matches (op operands)
                 (or (find-if (lambda (i) (and (eq op (mognitio.machine:instruction-opcode i))
                                               (equal operands (mognitio.machine:instruction-operands i)))) instructions)
                     (error "Missing publication mutation target"))))
          (ecase mutation
            (:roots (setf (mognitio.machine:instruction-operands (matches :imm-rax '(6))) '(5)))
            (:frame (setf (mognitio.machine:instruction-operands (matches :store-frame '(-72 :rax))) '(-4096 :rax)))
            (:flag (setf (mognitio.machine:instruction-operands (matches :imm-reg '(:r8 1))) '(:r8 0)))
            (:cleanup (setf (mognitio.object:code-unit-instructions unit)
                            (remove (matches :call '((:runtime :publication.cleanup))) instructions :test #'eq)))
            (:allocation (setf (mognitio.machine:instruction-operands (matches :call '((:runtime :publication.profile)))) '((:runtime :allocate-block)))))
          (signals internal-failure (mognitio.native.runtime::verify-publication-unit unit)))))))

(deftest v120-publication-retries-and-partial-failure
  (dolist (phase '(:open-parent :target-stat :filesystem :mount-id :kernel :open-probe :read-probe :random :open-temp :temp-stat :write))
    (dolist (native '(nil t))
      (let* ((path (v120-publication-path))
             (manifest (v120-publication-manifest (v120-publication-body path nil nil nil)))
             (count 0)
             (mognitio.io::*publication-fault-hook*
               (lambda (at) (when (and (eq phase at) (= 1 (incf count))) -4))))
        (multiple-value-bind (out err code)
            (if native (process-result (list (namestring (v12-native manifest (list :publication-faults (list (list phase 1 -4)))))))
                (v12-driver manifest))
          (unless (= code 0) (error "Retry ~S native=~S: ~D ~S ~S" phase native code out err))
          (same 0 code) (same "" out) (same "" err))
        (with-open-file (in path :element-type '(unsigned-byte 8))
          (same '(0 128 255) (loop for x = (read-byte in nil) while x collect x)))
        (delete-file path))))
  (dolist (failure '(-28 -27 0))
    (dolist (native '(nil t))
      (let* ((path (v120-publication-path))
             (manifest (v120-publication-manifest
                        (v120-publication-body path (if (= failure -28) "ResourceExhausted" "Other") "Body" "NotPublished")))
             (count 0)
             (original (fdefinition 'mognitio.io::publication-syscall))
             (mognitio.io::*publication-fault-hook*
               (lambda (at) (when (and (eq at :write) (= 2 (incf count))) failure))))
        (replacing (mognitio.io::publication-syscall
                     (lambda (number a b c d e f)
                       (funcall original number a b (if (= number 1) (min 1 c) c) d e f)))
          (multiple-value-bind (out err code)
              (if native
                  (process-result (list (namestring (v12-native manifest
                    (list :publication-faults (list (list :write 2 failure) '(:write 0 1 :limit)))))))
                  (v12-driver manifest))
            (same 0 code) (same "" out) (same "" err)))
        (is (not (probe-file path)))))))

(deftest v120-publication-input-without-external-calls
  (dolist (path '("" "/" "missing/" "file//"))
    (let ((calls 0)
          (manifest (v120-publication-manifest (v120-publication-body path "InvalidPath" "Input" "NotPublished"))))
      (let ((mognitio.io::*publication-fault-hook* (lambda (phase) (declare (ignore phase)) (incf calls) -13)))
        (multiple-value-bind (out err code) (v12-driver manifest)
          (same 0 code) (same "" out) (same "" err)))
      (same 0 calls)
      (multiple-value-bind (out err code)
          (process-result (list (namestring (v12-native manifest '(:publication-faults ((:open-parent 0 -13)))))))
        (same 0 code) (same "" out) (same "" err)))))

(deftest v120-publication-result-allocation
  (let* ((path (v120-publication-path))
         (manifest (v120-publication-manifest (v120-publication-body path nil nil nil)))
         (released nil) (before (v11-fd-snapshot))
         (mognitio.io::*publication-observer* (lambda (phase status)
           (declare (ignore status)) (when (eq phase :close-parent) (setf released t)))))
    (let ((mognitio.runtime::*allocation-hook*
            (lambda (kind) (when (and released (eq kind :data)) (error 'storage-condition)))))
      (multiple-value-bind (out err code) (v12-driver manifest)
        (same 4 code) (same "" out) (same (format nil "runtime error: allocation failure~%") err)))
    (is released) (same before (v11-fd-snapshot))
    (is (probe-file path)) (delete-file path))
  ;; Locate the first post-publication allocation, not a guessed allocation count.
  (let ((reached nil))
    (loop for ordinal from 1 to 32 until reached do
      (let* ((path (v120-publication-path))
             (manifest (v120-publication-manifest (v120-publication-body path nil nil nil)))
             (image (v12-native manifest (list :fail-allocation ordinal))))
        (multiple-value-bind (out err code) (process-result (list (namestring image)))
          (when (probe-file path)
            (same 4 code) (same "" out)
            (same (format nil "runtime error: allocation failure~%") err)
            (delete-file path) (setf reached t)))))
    (is reached)))

(deftest v120-publication-certified-errno-table
  (dolist (row '((1 "PermissionDenied") (2 "NotFound") (4 "Other") (11 "Other")
                (12 "ResourceExhausted") (13 "PermissionDenied") (16 "Other")
                (17 "AlreadyExists") (18 "UnsupportedTarget") (20 "UnsupportedTarget")
                (22 "UnsupportedTarget") (28 "ResourceExhausted") (30 "PermissionDenied")
                (36 "Other") (38 "UnsupportedTarget") (39 "AlreadyExists")
                (40 "Other") (95 "UnsupportedTarget") (116 "Other") (122 "ResourceExhausted")))
    (destructuring-bind (errno kind) row
      (dolist (native '(nil t))
        (let* ((path (v120-publication-path))
               (manifest (v120-publication-manifest (v120-publication-body path kind "Publish" "NotPublished")))
               (mognitio.io::*publication-fault-hook* (lambda (phase) (when (eq phase :commit) (- errno)))))
          (multiple-value-bind (out err code)
              (if native
                  (process-result (list (namestring (v12-native manifest
                    (list :publication-faults (list (list :commit 1 (- errno))))))))
                  (v12-driver manifest))
            (same 0 code) (same "" out) (same "" err))
          (is (not (probe-file path))))))))

(deftest v120-publication-staging-collision
  (dolist (native '(nil t))
    (let* ((path (v120-publication-path))
           (manifest (v120-publication-manifest (v120-publication-body path nil nil nil)))
           (attempts 0)
           (mognitio.io::*publication-fault-hook*
             (lambda (phase) (when (and (eq phase :open-temp) (= 1 (incf attempts))) -17))))
      (multiple-value-bind (out err code)
          (if native (process-result (list (namestring (v12-native manifest '(:publication-faults ((:open-temp 1 -17)))))))
              (v12-driver manifest))
        (same 0 code) (same "" out) (same "" err))
      (is (probe-file path)) (delete-file path))))

(deftest v120-publication-lost-profile
  ;; This private observation removes certification after the real profile gate.
  ;; It tests the decision guard, not an enabled unsupported filesystem.
  (dolist (row '((17 "AlreadyExists") (28 "ResourceExhausted")))
    (destructuring-bind (errno kind) row
      (dolist (native '(nil t))
        (let* ((path (v120-publication-path))
               (manifest (v120-publication-manifest (v120-publication-body path kind "Publish" "Unknown")))
               (original (fdefinition 'mognitio.io::publication-classify-commit))
               (forms (fdefinition 'mognitio.native.runtime::publication-write-commit-forms))
               (mognitio.io::*publication-fault-hook* (lambda (at) (when (eq at :commit) (- errno)))))
          (replacing (mognitio.io::publication-classify-commit
                       (lambda (owner status)
                         (setf (mognitio.io::publication-owner-profile owner) nil)
                         (funcall original owner status)))
            (replacing (mognitio.native.runtime::publication-write-commit-forms
                         (lambda ()
                           (loop for form in (funcall forms) append
                             (append (when (equal form '(:publication-syscall :commit 316))
                                       '((:imm-rax 0) (:store-frame -144 :rax))) (list form)))))
              (multiple-value-bind (out err code)
                  (if native (process-result (list (namestring (v12-native manifest
                      (list :publication-faults (list (list :commit 1 (- errno))))))))
                      (v12-driver manifest))
                (same 0 code) (same "" out) (same "" err))))
          (is (not (probe-file path))))))))

(deftest v120-publication-gc-lifetime
  (let ((manifest (v120-publication-manifest
    "let data:Bytes=bytesFromBits(List<Bits<8>>[Bits<8>{255},Bits<8>{0}]);
     let saved:Function():Bytes=function():Bytes{data};var i:Int=0;
     loop while(i<200){
       let outcome:Result<Unit,BinaryOutputError>=publishFile(\"\",saved(),BinaryFileMode::Data);
       let extra:Bytes=data->concat(data);
       assert extra->length()==4;
       assert branch on outcome{Result<Unit,BinaryOutputError>::Ok=>false,Result<Unit,BinaryOutputError>::Err(e:BinaryOutputError)=>e->subject==\"\"};
       assert saved()==data;i=i+1;
     };0")))
    (dolist (stress '(nil t))
      (expect-project manifest (list :stress stress :validate t :arena-unit 4096 :cap 65536)))))
