(in-package #:mognitio.tests)

(defun v12-trace (image &optional injection arguments)
  (let ((trace (fresh-path ".trace")))
    (multiple-value-bind (out err code)
        (process-result (append (list "strace" "-qq" "-s" "80" "-e"
                              "trace=open,close,mmap,munmap,read,write,rt_sigaction,newfstatat,fstat,ftruncate" "-o" (namestring trace))
                         (when injection (list "-e" (concatenate 'string "inject=" injection)))
                         (cons (namestring image) arguments)))
      (values out err code (uiop:read-file-string trace)))))

(defun v12-error-assertion (operation kind)
  (format nil "assert branch on ~A{Result<Unit,IoError>::Ok=>false,Result<Unit,IoError>::Err(e:IoError)=>branch on e->kind{~{~A~^,~}}};0"
    operation (loop for name in '("InvalidPath" "InvalidEncoding" "NotFound" "PermissionDenied" "UnsupportedTarget" "BrokenPipe" "ResourceExhausted" "Other")
                    collect (format nil "IoErrorKind::~A=>~A" name (if (equal name kind) "true" "false")))))

(deftest v012-native-syscall-boundaries
  (let* ((path (fresh-path ".txt"))
         (call (format nil "writeTextFile(~S,\"AB\")" (namestring path))))
    (dolist (case '(("write:error=EINTR:when=1" nil) ("write:retval=0:when=1" "Other")
                    ("write:error=EAGAIN:when=1" "Other") ("write:error=EFBIG:when=1" "Other")
                    ("open:error=EACCES:when=1" "PermissionDenied")
                    ("open:error=EMFILE:when=1" "ResourceExhausted")
                    ("fstat:error=EINTR:when=1" nil) ("ftruncate:error=EINTR:when=1" nil)))
      (destructuring-bind (fault kind) case
        (let ((image (v12-native (v12-manifest (if kind (v12-error-assertion call kind)
                                              (format nil "assert branch on ~A{Result<Unit,IoError>::Ok=>true,Result<Unit,IoError>::Err=>false};0" call))))))
          (multiple-value-bind (out err code trace) (v12-trace image fault)
            (same 0 code) (same "" out) (same "" err)
            (is (search "INJECTED" trace))
            (is (search "rt_sigaction(SIGPIPE, {sa_handler=SIG_IGN" trace))
            (is (search "rt_sigaction(SIGXFSZ, {sa_handler=SIG_IGN" trace))
            (unless (search "open:" fault) (is (search "close(3)" trace)))
            (unless kind (same #(65 66) (read-bytes path)))))))))

(deftest v012-native-cleanup-before-fatal
  (let* ((path (put-text (fresh-path ".txt") "ABC"))
         (manifest (v12-manifest (format nil "discard readTextFile(~S);0" (namestring path)))))
    (dolist (case '((nil "mmap:error=ENOMEM:when=3") ((:fail-allocation 2) nil)))
      (destructuring-bind (options injection) case
        (multiple-value-bind (out err code trace) (v12-trace (v12-native manifest options) injection)
          (same 4 code) (same "" out) (is (search "allocation failure" err))
          (let ((close (search "close(3)" trace)) (diagnostic (search "write(2," trace)))
            (is (and close diagnostic (< close diagnostic)) (format nil "Fatal cleanup trace ~S: ~A" case trace))
            (is (search "munmap(" trace :end2 diagnostic) (format nil "Staging cleanup trace ~S: ~A" case trace))))))))

(deftest v012-native-close-failure-precedence
  ;; Run the real Linux close, then inject its reported failure. No fd is leaked
  ;; by a mock that skipped the operation, and the ownership slot is cleared.
  (let ((original (fdefinition 'mognitio.native.runtime::io-close-unit)))
    (replacing (mognitio.native.runtime::io-close-unit
      (lambda () (let ((unit (funcall original)))
        (setf (mognitio.object:code-unit-instructions unit)
          (loop for tail on (mognitio.object:code-unit-instructions unit) for i = (first tail) append
            (if (and (eq (mognitio.machine:instruction-opcode i) :syscall)
                     (eq (mognitio.machine:instruction-opcode (second tail)) :ret))
                (list i (mognitio.machine:make-instruction :opcode :imm-rax :operands '(-28))) (list i)))) unit)))
      (let* ((path (fresh-path ".txt")) (call (format nil "writeTextFile(~S,\"AB\")" (namestring path))))
        (dolist (failure '(nil "write:error=EFBIG:when=1"))
          (multiple-value-bind (out err code trace)
              (v12-trace (v12-native (v12-manifest (v12-error-assertion call (if failure "Other" "ResourceExhausted")))) failure)
            (same 0 code) (same "" out) (same "" err)
            (same 1 (count-if (lambda (line) (search "close(3)" line)) (uiop:split-string trace :separator '(#\Newline))))))))))

(deftest v012-native-gc-and-resource-lifetime
  (let* ((path (put-text (fresh-path ".txt") "kept string"))
         (body (format nil "let kept:String=branch on readTextFile(~S){Result<String,IoError>::Ok(s:String)=>s,Result<String,IoError>::Err=>panic{\"read\"}};
           var i:Int=0;loop while(i<160){discard readTextFile(~S);discard readTextFile(\"missing\"+\"!\");discard List<String>[\"garbage\"+\"!\"];i=i+1;};
           assert kept==\"kept string\";assert args->length()==1;assert branch on args->at(0){Result<String,IndexError>::Ok(s:String)=>s==\"kept argument\",Result<String,IndexError>::Err=>false};0" (namestring path) (namestring path)))
         (image (v12-native (v12-manifest body) '(:arena-unit 4096 :cap 4096 :validate t :stress t))))
    (multiple-value-bind (out err code trace) (v12-trace image nil '("kept argument"))
      (same 0 code) (same "" out) (same "" err)
      (same 161 (count-if (lambda (line) (search "close(3)" line)) (uiop:split-string trace :separator '(#\Newline)))))))

(deftest v012-native-signal-bootstrap-failures
  (dolist (ordinal '(1 2))
    (let* ((marker (fresh-path ".marker"))
           (manifest (v12-manifest "0" (format nil "let init:Unit={discard writeTextFile(~S,\"wrong\");unit};" (namestring marker)))))
      (multiple-value-bind (out err code trace)
          (v12-trace (v12-native manifest) (format nil "rt_sigaction:error=EPERM:when=~D" ordinal))
        (same 3 code) (same "" out) (same "" err) (is (search "INJECTED" trace))
        (is (not (probe-file marker)))))
    (let ((original (fdefinition 'mognitio.native.runtime::io-signal-unit)) (before (v11-fd-snapshot)) (attempt nil))
      (replacing (mognitio.native.runtime::io-signal-unit
        (lambda () (let ((unit (funcall original)) (count 0))
          (setf (mognitio.object:code-unit-instructions unit)
            (loop for i in (mognitio.object:code-unit-instructions unit) append
              (if (and (eq (mognitio.machine:instruction-opcode i) :syscall) (= (incf count) ordinal))
                  (list i (mognitio.machine:make-instruction :opcode :imm-rax :operands '(-1))) (list i)))) unit)))
        (multiple-value-bind (out err code) (v11-driver (v11-manifest "unit" 1)
                                            (lambda (point object) (when (eq point :before-spawn) (setf attempt object))))
          (same 2 code) (same "" out) (is (not (search "tests:" err)))
          (same nil (mognitio.testing::attempt-resources-execution-delegated attempt))))
      (v11-assert-released attempt) (same before (v11-fd-snapshot)))))

(sb-alien:define-alien-routine ("getrlimit" v12-getlimit) sb-alien:int
  (resource sb-alien:int) (limit sb-alien:system-area-pointer))
(sb-alien:define-alien-routine ("setrlimit" v12-setlimit) sb-alien:int
  (resource sb-alien:int) (limit sb-alien:system-area-pointer))
(defun v12-with-file-limit (limit thunk)
  (sb-alien:with-alien ((old (array sb-alien:unsigned-long 2)) (new (array sb-alien:unsigned-long 2)))
    (let ((old-sap (sb-alien:alien-sap (sb-alien:addr old))) (new-sap (sb-alien:alien-sap (sb-alien:addr new))))
      (same 0 (v12-getlimit 1 old-sap))
      (setf (sb-sys:sap-ref-64 new-sap 0) limit (sb-sys:sap-ref-64 new-sap 8) (sb-sys:sap-ref-64 old-sap 8))
      (unwind-protect (progn (same 0 (v12-setlimit 1 new-sap)) (funcall thunk)) (same 0 (v12-setlimit 1 old-sap))))))

(deftest v012-test-child-real-file-limit
  (let* ((path (fresh-path ".txt")) (before (v11-fd-snapshot))
         (assertion (v12-error-assertion (format nil "writeTextFile(~S,\"AB\")" (namestring path)) "Other"))
         (body (subseq assertion 0 (1- (length assertion))))
         (manifest (project-fixture (list (cons "app.mgn" (format nil "namespace App;~A@test let check:Function():Unit=function():Unit{~Aunit};" *v12-imports* body)))))
         (original (fdefinition 'mognitio.testing::raw-spawn)))
    (replacing (mognitio.testing::raw-spawn
      (lambda (&rest args) (v12-with-file-limit 1 (lambda () (apply original args)))))
      (multiple-value-bind (out err code) (v11-driver manifest)
        (same 0 code) (same "" err) (is (search "total=1 passed=1" out))))
    (same #(65) (read-bytes path)) (same before (v11-fd-snapshot))))

(deftest v012-runner-real-file-limit-after-commit
  (let ((path (fresh-path ".report")) (before (v11-fd-snapshot)) (committed nil) (attempt nil))
    (with-open-file (out path :direction :output :if-exists :supersede)
      (sb-posix:lseek (sb-sys:fd-stream-fd out) 1048576 sb-posix:seek-set)
      (let ((err (make-string-output-stream))
            (mognitio.testing::*runner-hook* (lambda (point object)
              (when (eq point :before-spawn) (setf attempt object))
              (when (eq point :result-committed) (push (mognitio.testing::test-case-state object) committed)))))
        (same 2 (v12-with-file-limit 1048576
                  (lambda () (mognitio.driver:run-cli (list "test" (namestring (v11-manifest "unit" 1))) out err))))
        (same '(:passed) committed) (is (search "Cannot write test report" (get-output-stream-string err)))))
    (v11-assert-released attempt) (same before (v11-fd-snapshot))))

(deftest v012-native-error-result-allocation-cleanup
  (let* ((path (put-bytes (fresh-path ".txt") #(255)))
         (manifest (v12-manifest (format nil "discard readTextFile(~S);0" (namestring path)))))
    (loop for ordinal from 2 to 5 do
      (multiple-value-bind (out err code trace) (v12-trace (v12-native manifest (list :fail-allocation ordinal)))
        (same 4 code) (same "" out) (is (search "allocation failure" err))
        (let ((close (search "close(3)" trace)) (report (search "write(2," trace)))
          (is (and close report (< close report)))
          (is (search "munmap(" trace :end2 report)))))))
