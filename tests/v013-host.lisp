(in-package #:mognitio.tests)

(defparameter *v13-imports* "use Std\\Io\\{joinPath,readDirectory,createDirectory,DirectoryEntry,DirectoryEntryKind};")
(defun v13-kind-arms (expected)
  (format nil "~{~A~^,~}"
    (loop for kind in '("InvalidPath" "InvalidEncoding" "NotFound" "PermissionDenied" "UnsupportedTarget" "BrokenPipe" "ResourceExhausted" "Other")
          collect (format nil "IoErrorKind::~A=>~D" kind (if (equal kind expected) 0 2)))))
(defun v13-manifest (body &optional (extra ""))
  (project-fixture (list (cons "app.mgn"
    (format nil "namespace App;~A~A~Alet main:Function(List<String>):Int=function(args:List<String>):Int{~A};"
            *v12-imports* *v13-imports* extra body)))))
(defun v13-host-code (body &optional (extra ""))
  (multiple-value-bind (out err code) (v12-driver (v13-manifest body extra))
    (same "" out) (same "" err) code))
(defun v13-directory ()
  (let ((path (namestring (fresh-path "-directory")))) (sb-posix:mkdir path #o700) path))

(deftest v013-host-join-and-first-class
  (dolist (case '(("a" "b" "a/b") ("a/" "b" "a/b") ("./a//" "../b" "./a//../b")
                  ("/" "x" "/x") ("日本" "語" "日本/語")))
    (destructuring-bind (base relative expected) case
      (same 0 (v13-host-code (format nil "let f:Function(String,String):Result<String,IoError>=joinPath;let value:Result<String,IoError>=f(~S,~S);branch on(value){Result<String,IoError>::Ok(text:String)=>branch when{text==~S=>0,else=>1},Result<String,IoError>::Err(error:IoError)=>2}" base relative expected)))))
  (dolist (case '(("" "" "") ("a" "/b" "/b") ("a" "" "")))
    (destructuring-bind (base relative expected) case
      (same 0 (v13-host-code (format nil "branch on(joinPath(~S,~S)){Result<String,IoError>::Ok(text:String)=>1,Result<String,IoError>::Err(error:IoError)=>branch when{error->subject==~S=>0,else=>2}}" base relative expected)))))
  (let ((calls 0) (mognitio.io::*directory-fault-hook* (lambda (phase) (declare (ignore phase)) (error "Unexpected filesystem access"))))
    (declare (ignore calls))
    (same 0 (v13-host-code "discard joinPath(\"does-not-exist\",\"child\");0"))))

(deftest v013-host-create-and-entries
  (let* ((root (v13-directory)) (child (concatenate 'string root "/nested")))
    (same 0 (v13-host-code (format nil "discard createDirectory(~S);discard createDirectory(~S);0" child child)))
    (put-text (pathname (concatenate 'string root "/a.txt")) "a")
    (sb-posix:symlink "missing" (concatenate 'string root "/link"))
    (sb-posix:mkfifo (concatenate 'string root "/pipe") #o600)
    (same 0 (v13-host-code (format nil "branch on(readDirectory(~S)){Result<List<DirectoryEntry>,IoError>::Err(error:IoError)=>9,Result<List<DirectoryEntry>,IoError>::Ok(entries:List<DirectoryEntry>)=>{assert entries->length()==4;loop over(entries as entry:DirectoryEntry){branch on(entry->kind){DirectoryEntryKind::File=>{assert entry->name==\"a.txt\";},DirectoryEntryKind::Directory=>{assert entry->name==\"nested\";},DirectoryEntryKind::Symlink=>{assert entry->name==\"link\";},DirectoryEntryKind::Other=>{assert entry->name==\"pipe\";}};};0}}" root)))
    (same 0 (v13-host-code (format nil "branch on(readDirectory(~S)){Result<List<DirectoryEntry>,IoError>::Err(error:IoError)=>1,Result<List<DirectoryEntry>,IoError>::Ok(entries:List<DirectoryEntry>)=>branch when{entries->length()==0=>0,else=>2}}" child)))))

(deftest v013-host-collision-and-subject
  (let* ((root (v13-directory)) (target (concatenate 'string root "/dangling")))
    (sb-posix:symlink "missing" target)
    (dolist (case (list (list target "UnsupportedTarget") (list (concatenate 'string target "/") "NotFound")
                       (list (concatenate 'string root "/missing/child") "NotFound")))
      (destructuring-bind (path kind) case
        (same 0 (v13-host-code (format nil "branch on(createDirectory(~S)){Result<Unit,IoError>::Ok=>1,Result<Unit,IoError>::Err(error:IoError)=>{assert error->subject==~S;branch on(error->kind){~A}}}" path path (v13-kind-arms kind))))))))

(deftest v013-host-phase-classification
  (let ((root (v13-directory)))
    (put-text (pathname (concatenate 'string root "/child")) "x")
    (dolist (phase '(:scan :child-stat :close))
      (dolist (errno (if (eq phase :close) '(9) '(9 14 22)))
        (let ((before (v11-fd-snapshot))
              (mognitio.io::*directory-fault-hook* (lambda (at) (when (eq at phase) (- errno)))))
          (signals internal-failure (mognitio.io::scan-directory (v12-text root)))
          (same before (v11-fd-snapshot)))))
    (let ((mognitio.io::*directory-fault-hook* (lambda (phase) (when (eq phase :child-stat) -13))))
      (same 0 (v13-host-code (format nil "branch on(readDirectory(~S)){Result<List<DirectoryEntry>,IoError>::Ok(entries:List<DirectoryEntry>)=>1,Result<List<DirectoryEntry>,IoError>::Err(error:IoError)=>{assert error->subject==~S;branch on(error->kind){IoErrorKind::InvalidPath=>2,IoErrorKind::InvalidEncoding=>2,IoErrorKind::NotFound=>2,IoErrorKind::PermissionDenied=>0,IoErrorKind::UnsupportedTarget=>2,IoErrorKind::BrokenPipe=>2,IoErrorKind::ResourceExhausted=>2,IoErrorKind::Other=>2}}}" root (concatenate 'string root "/child")))))
    (let ((mognitio.io::*directory-fault-hook* (lambda (phase) (when (eq phase :mkdir) -31))))
      (same 0 (v13-host-code (format nil "branch on(createDirectory(~S)){Result<Unit,IoError>::Ok=>1,Result<Unit,IoError>::Err(error:IoError)=>branch on(error->kind){IoErrorKind::InvalidPath=>2,IoErrorKind::InvalidEncoding=>2,IoErrorKind::NotFound=>2,IoErrorKind::PermissionDenied=>2,IoErrorKind::UnsupportedTarget=>2,IoErrorKind::BrokenPipe=>2,IoErrorKind::ResourceExhausted=>0,IoErrorKind::Other=>2}}" (concatenate 'string root "/new")))))
    (let ((mognitio.io::*directory-fault-hook* (lambda (phase) (when (eq phase :mkdir) -22))))
      (same 0 (v13-host-code (format nil "branch on(createDirectory(~S)){Result<Unit,IoError>::Ok=>1,Result<Unit,IoError>::Err(error:IoError)=>branch on(error->kind){IoErrorKind::InvalidPath=>2,IoErrorKind::InvalidEncoding=>2,IoErrorKind::NotFound=>2,IoErrorKind::PermissionDenied=>2,IoErrorKind::UnsupportedTarget=>2,IoErrorKind::BrokenPipe=>2,IoErrorKind::ResourceExhausted=>2,IoErrorKind::Other=>0}}" (concatenate 'string root "/new")))))))

(deftest v013-host-cleanup-primary
  (let ((root (v13-directory)))
    (put-text (pathname (concatenate 'string root "/child")) "x")
    (dolist (close '(-5 -9))
      (let ((mognitio.io::*directory-fault-hook*
              (lambda (phase) (case phase (:child-stat -13) (:close close)))))
        (if (= close -9) (signals internal-failure (mognitio.io::scan-directory (v12-text root)))
            (handler-case (progn (mognitio.io::scan-directory (v12-text root)) (is nil))
              (mognitio.io::directory-failure (condition)
                (same 3 (mognitio.io::io-failure-kind condition))
                (same #(99 104 105 108 100) (mognitio.io::directory-failure-child condition)))))))
    (let ((mognitio.io::*operation-hook*
            (lambda (stage &rest arguments) (declare (ignore arguments))
              (when (eq stage :directory-opened) (mognitio.runtime:runtime-error :allocation-failed))))
          (mognitio.io::*directory-fault-hook* (lambda (phase) (when (eq phase :close) -9))))
      (handler-case (progn (mognitio.io::scan-directory (v12-text root)) (is nil))
        (mognitio.runtime:program-runtime-failure (condition)
          (same :allocation-failed (mognitio.runtime:failure-kind condition)))))))

(deftest v013-host-heap-order-and-invalid-utf8
  (let ((root (v13-directory)))
    (dolist (name '("日本" "b" "a2" "a" "é" "aa"))
      (put-text (pathname (concatenate 'string root "/" name)) name))
    (multiple-value-bind (rows arena) (mognitio.io::scan-directory (v12-text root))
      (same '("a" "a2" "aa" "b" "é" "日本")
            (loop for row across rows collect
              (sb-ext:octets-to-string (subseq arena (aref row 0) (+ (aref row 0) (aref row 1))) :external-format :utf-8))))
    (let ((sb-alien::*default-c-string-external-format* :latin-1)
          (bad (concatenate 'string root "/" (string (code-char 255)))))
      (let ((fd (sb-posix:open bad (logior sb-posix:o-creat sb-posix:o-wronly) #o600))) (sb-posix:close fd))
      (unwind-protect
           (same 0 (v13-host-code (format nil "branch on(readDirectory(~S)){Result<List<DirectoryEntry>,IoError>::Ok(entries:List<DirectoryEntry>)=>1,Result<List<DirectoryEntry>,IoError>::Err(error:IoError)=>{assert error->subject==~S;branch on(error->kind){IoErrorKind::InvalidPath=>2,IoErrorKind::InvalidEncoding=>0,IoErrorKind::NotFound=>2,IoErrorKind::PermissionDenied=>2,IoErrorKind::UnsupportedTarget=>2,IoErrorKind::BrokenPipe=>2,IoErrorKind::ResourceExhausted=>2,IoErrorKind::Other=>2}}}" root root)))
        (sb-posix:unlink bad)))))
