(in-package #:mognitio.tests)

(defparameter *v14-phase-import* "use Std\\Io\\{IoErrorPhase};")
(defun v14-phase-arms (phase)
  (format nil "~{~A~^,~}" (loop for name in '("Input" "Target" "Body" "Cleanup")
    collect (format nil "IoErrorPhase::~A=>~A" name (if (equal name phase) "true" "false")))))
(defun v14-error-body (call success operation kind subject phase)
  (format nil "branch on ~A{Result<~A,IoError>::Ok=>1,Result<~A,IoError>::Err(error:IoError)=>{assert error->subject==~S;assert branch on error->operation{~A};assert branch on error->phase{~A};branch on error->kind{~A}}}"
          call success success subject (v13-operation-arms operation) (v14-phase-arms phase) (v13-kind-arms kind)))

(deftest v014-phase-surfaces
  (dolist (case '(("joinPath(\"\",\"x\")" "String" "JoinPath" "InvalidPath" "" "Input")
                  ("readTextFile(\"/mognitio-absent-v014/x\")" "String" "ReadTextFile" "NotFound" "/mognitio-absent-v014/x" "Target")
                  ("readDirectory(\"/mognitio-absent-v014/x\")" "List<DirectoryEntry>" "ReadDirectory" "NotFound" "/mognitio-absent-v014/x" "Target")
                  ("createDirectory(\"/mognitio-absent-v014/x\")" "Unit" "CreateDirectory" "NotFound" "/mognitio-absent-v014/x" "Target")))
    (v14-both (apply #'v14-error-body case) *v14-phase-import*))
  (let ((file (put-text (fresh-path ".txt") "kept")))
    (v14-both (v14-error-body (format nil "readDirectory(~S)" (namestring file)) "List<DirectoryEntry>"
                              "ReadDirectory" "UnsupportedTarget" (namestring file) "Target") *v14-phase-import*))
  (signals compiler-failure (project-checked (v13-manifest
    "discard IoError{operation:IoOperation::ReadStdin,kind:IoErrorKind::Other,subject:\"stdin\"};0")))
  (v14-both "let source:IoError=IoError{phase:IoErrorPhase::Body,subject:\"kept\",kind:IoErrorKind::NotFound,operation:IoOperation::ReadDirectory};let propagate:Function():Result<Unit,IoError>=function():Result<Unit,IoError>{try Result<Unit,IoError>::Err(source);Result<Unit,IoError>::Ok(unit)};branch on propagate(){Result<Unit,IoError>::Ok=>1,Result<Unit,IoError>::Err(error:IoError)=>{assert error->subject==\"kept\";assert branch on error->phase{IoErrorPhase::Input=>false,IoErrorPhase::Target=>false,IoErrorPhase::Body=>true,IoErrorPhase::Cleanup=>false};0}}" *v14-phase-import*))

(deftest v014-phase-primary-and-nonmutation
  (let* ((root (v13-directory)) (file (put-text (pathname (concatenate 'string root "/keep")) "unchanged")))
    (dolist (case '((:scan "Body") (:close "Cleanup")))
      (destructuring-bind (stage phase) case
        (let* ((body (v14-error-body (format nil "readDirectory(~S)" root) "List<DirectoryEntry>" "ReadDirectory" "NotFound" root phase))
               (mognitio.io::*directory-fault-hook* (lambda (at) (when (eq at stage) -2))))
          (same 0 (v13-host-code body *v14-phase-import*))
          (same 0 (v13-native-code body *v14-phase-import* (list :directory-faults (list (list stage 1 -2)))))
        (same "unchanged" (uiop:read-file-string file)) (same 1 (length (uiop:directory-files (pathname (concatenate 'string root "/")))))))
    (let* ((body (v14-error-body (format nil "readDirectory(~S)" root) "List<DirectoryEntry>" "ReadDirectory" "NotFound" root "Body"))
           (mognitio.io::*directory-fault-hook* (lambda (at) (case at (:scan -2) (:close -13)))))
      (same 0 (v13-host-code body *v14-phase-import*))
      (same 0 (v13-native-code body *v14-phase-import* '(:directory-faults ((:scan 1 -2) (:close 1 -13))))))))
)

(defun v14-input-trace (image input)
  (let ((trace (fresh-path ".trace")))
    (multiple-value-bind (out err code)
        (process-result (list "strace" "-qq" "-e" "trace=read,close,munmap,write,exit" "-o" (namestring trace) (namestring image)) :input input)
      (values out err code (uiop:read-file-string trace)))))

(deftest v014-stream-scratch-cleanup
  (dolist (invalid '(nil t))
    (let* ((input (put-bytes (fresh-path ".input") (if invalid #(255) #(65))))
           (body (v14-error-body "readStdin()" "String" "ReadStdin" (if invalid "InvalidEncoding" "Other") "stdin" "Body"))
           (image (v12-native (v13-manifest body *v14-phase-import*) '(:directory-cleanup-fault -5))))
      (multiple-value-bind (out err code trace) (v14-input-trace image input)
        (same "" out) (same "" err) (same 0 code)
        (is (search "read(0," trace)) (is (search "munmap(" trace))
        (is (not (search "close(0)" trace)))
        (is (some (lambda (line) (and (search "munmap(" line) (search "= 0" line))) (uiop:split-string trace :separator '(#\Newline)))))))
  (let* ((file (put-text (fresh-path ".txt") "ok"))
         (body (v14-error-body (format nil "readTextFile(~S)" (namestring file)) "String" "ReadTextFile" "Other" (namestring file) "Cleanup")))
    (same 0 (v13-native-code body *v14-phase-import* '(:directory-cleanup-fault -5))))
  (let* ((input (put-text (fresh-path ".input") "ok"))
         (image (v12-native (v13-manifest "discard readStdin();0") '(:directory-cleanup-fault -22))))
    (multiple-value-bind (out err code trace) (v14-input-trace image input)
      (same "" out) (same 3 code) (is (search "internal error" err))
      (is (search "munmap(" trace)) (is (not (search "close(0)" trace))))))
(in-package #:mognitio.tests)

(defun v14-prepare-source (path phase &optional ignore-phase target missing-parent)
  (let ((predicate (format nil "branch on error->operation{~A} && branch on error->kind{~A} && error->subject==path~A"
                     (v13-operation-arms "ReadDirectory")
                     (format nil "~{~A~^,~}" (loop for name in '("NotFound" "PermissionDenied" "BrokenPipe" "InvalidPath" "InvalidEncoding" "UnsupportedTarget" "ResourceExhausted" "Other") collect
                       (format nil "IoErrorKind::~A=>~A" name (if (equal name "NotFound") "true" "false"))))
                     (if ignore-phase "" (format nil " && branch on error->phase{~A}" (v14-phase-arms "Target"))))))
    (format nil "let prepare:Function(String):Result<Unit,IoError>=function(path:String):Result<Unit,IoError>{branch on readDirectory(path){Result<List<DirectoryEntry>,IoError>::Ok=>Result<Unit,IoError>::Ok(unit),Result<List<DirectoryEntry>,IoError>::Err(error:IoError)=>branch when{~A=>{try createDirectory(path);try writeTextFile(path+\"/marker\",\"created\");Result<Unit,IoError>::Ok(unit)},else=>Result<Unit,IoError>::Err(error)}}};branch on prepare(~S){Result<Unit,IoError>::Ok=>~A,Result<Unit,IoError>::Err(error:IoError)=>{assert error->subject==~S;assert branch on error->phase{~A};assert branch on error->operation{~A};0}}"
            predicate path (if (and target (not missing-parent)) "0" "1") path
            (v14-phase-arms phase) (v13-operation-arms (if missing-parent "CreateDirectory" "ReadDirectory")))))

(deftest v014-consumer-absence-guard
  ;; The obsolete three-field predicate must demonstrably write a marker on
  ;; Body/Cleanup NotFound; the four-field consumer preserves the original tree.
  (dolist (backend '(:host :native))
    (dolist (case '((:scan "Body") (:close "Cleanup")))
      (destructuring-bind (stage phase) case
        (dolist (ignore-phase '(nil t))
          (let* ((root (v13-directory))
                 (file (put-text (pathname (concatenate 'string root "/keep")) "unchanged"))
                 (body (v14-prepare-source root phase ignore-phase))
                 (mognitio.io::*directory-fault-hook* (lambda (at) (when (eq at stage) -2))))
            (same (if ignore-phase 1 0)
              (if (eq backend :host) (v13-host-code body *v14-phase-import*)
                  (v13-native-code body *v14-phase-import* (list :directory-faults (list (list stage 1 -2))))))
            (same "unchanged" (uiop:read-file-string file))
            (same (if ignore-phase 2 1) (length (uiop:directory-files (pathname (concatenate 'string root "/")))))))))
    (dolist (missing-parent '(nil t))
      (let* ((root (v13-directory)) (path (concatenate 'string root (if missing-parent "/parent/new" "/new")))
             (body (v14-prepare-source path "Target" nil t missing-parent)))
        (same 0 (if (eq backend :host) (v13-host-code body *v14-phase-import*)
                    (v13-native-code body *v14-phase-import*)))
        (if missing-parent (is (not (probe-file path)))
            (same "created" (uiop:read-file-string (concatenate 'string path "/marker"))))))))

(deftest v014-child-and-decode-phase
  (let* ((root (v13-directory)) (child (concatenate 'string root "/child")))
    (put-text (pathname child) "kept")
    (let ((body (v14-error-body (format nil "readDirectory(~S)" root) "List<DirectoryEntry>"
                                "ReadDirectory" "NotFound" child "Body"))
          (mognitio.io::*directory-fault-hook* (lambda (stage) (when (eq stage :child-stat) -2))))
      (same 0 (v13-host-code body *v14-phase-import*))
      (same 0 (v13-native-code body *v14-phase-import* '(:directory-faults ((:child-stat 1 -2)))))))
  (let ((path (put-bytes (fresh-path ".txt") #(255))))
    (v14-both (v14-error-body (format nil "readTextFile(~S)" (namestring path)) "String"
                             "ReadTextFile" "InvalidEncoding" (namestring path) "Body") *v14-phase-import*)))
