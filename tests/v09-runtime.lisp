(in-package #:mognitio.tests)

(deftest v09-native-conformance
  (dolist (fixture *v09-positive-fixtures*)
    (handler-case
        (dolist (options '(nil (:stress t :validate t :arena-unit 4096 :cap 65536)))
          (v06-expect-native (second fixture) :true options))
      (error (condition) (error "Native fixture ~A: ~A" (first fixture) condition)))))

(deftest v09-runtime-diagnostics
  (dolist (case '(("panic{\"stop\"}" "panic: stop")
                 ("panic{\"\"}" "panic: ")
                 ("panic{\"日\\0\\nline\"}" "panic: 日<NUL><LF>line")
                 ("panic{\"line\\n\"}" "panic: line<LFEND>")
                 ("panic{panic{\"inner\"}}" "panic: inner")
                 ("(1/0)+(panic{\"later\"})==0" "runtime error: division by zero")
                 ("9223372036854775807+1==0" "runtime error: integer overflow")
                 ("-9223372036854775808-1==0" "runtime error: integer overflow")
                 ("3037000500*3037000500==0" "runtime error: integer overflow")
                 ("let n:Int=-9223372036854775808;-n==0" "runtime error: integer overflow")
                 ("-9223372036854775808/(-1)==0" "runtime error: integer overflow")
                 ("1/0==0" "runtime error: division by zero")
                 ("1%0==0" "runtime error: division by zero")))
    (let* ((source (put-text (fresh-path) (first case)))
           (expected (cond ((search "<NUL>" (second case)) (format nil "panic: 日~C~%line~%" #\Null))
                           ((search "<LFEND>" (second case)) (format nil "panic: line~%~%"))
                           (t (format nil "~A~%" (second case))))))
      (multiple-value-bind (out err code) (cli-result (list "run" (namestring source)))
        (same 4 code) (same "" out) (same expected err))
      ;; Building a failing program succeeds without executing it.
      (let ((artifact (build-text (first case))))
        (multiple-value-bind (out err code) (process-result (list (namestring artifact)))
          (same 4 code) (same "" out) (same expected err))))))

(defparameter *v09-allocation-fixtures*
  '(("product" "type P=product{x:String;};P{x:\"a\"+\"b\"}->x==\"ab\"")
    ("sum" "type S=sum{A(String);};branch on S::A(\"a\"+\"b\"){S::A(x:String)=>x==\"ab\"}")
    ("closure" "let s:String=\"a\"+\"b\";let f:Function():String=function():String{s};f()==\"ab\"")
    ("package" "contract C{get(self:Self):String;}witness Evidence1 = String implements C{get(self:Self):String{self}}let p:C=C(\"a\"+\"b\");p->get()==\"ab\"")
    ("list-result" "let a:List<String>=List<String>[\"a\"+\"b\"];branch on a->at(0){Result<String,IndexError>::Ok(s:String)=>s==\"ab\",Result<String,IndexError>::Err=>false}")
    ("index-error" "branch on List<String>[]->at(-1){Result<String,IndexError>::Ok=>false,Result<String,IndexError>::Err(e:IndexError)=>e->index==(-1)&&e->length==0}")
    ("slice-result" "branch on (\"a\"+\"b\")->slice(0,1){Result<String,SliceError>::Ok(s:String)=>s==\"a\",Result<String,SliceError>::Err=>false}")
    ("slice-error" "branch on \"abc\"->slice(3,1){Result<String,SliceError>::Ok=>false,Result<String,SliceError>::Err(e:SliceError)=>e->start==3&&e->end==1&&e->length==3}")
    ("buffer" "let a:List<String>=List<String>[\"a\"+\"b\",\"c\"+\"d\"];var s:String=\"\";loop over(a as x:String){s=s+x;};s==\"abcd\"")))

(deftest v09-allocation-failure-at-every-stage
  (dolist (fixture *v09-allocation-fixtures*)
    (let* ((source (second fixture)) (compiled (compile-program (check-program (parse-text source))))
           (count 0))
      (let ((mognitio.runtime::*allocation-hook* (lambda (kind) (declare (ignore kind)) (incf count))))
        (same :true (execute-program compiled)))
      (is (plusp count))
      (loop for ordinal from 1 to count do
        (let ((seen 0)
              (mognitio.runtime::*allocation-hook* nil))
          (setf mognitio.runtime::*allocation-hook*
                (lambda (kind) (declare (ignore kind))
                  (when (= (incf seen) ordinal) (error 'storage-condition))))
          (let ((failure (handler-case (execute-program compiled)
                           (mognitio.runtime:program-runtime-failure (c) c))))
            (is (typep failure 'mognitio.runtime:program-runtime-failure))
            (same :allocation-failed (mognitio.runtime::failure-kind failure)))))
      ;; Native storage can differ, so enumerate until the first untriggered
      ;; fault. Every preceding allocation must fail with the specified status.
      (loop for ordinal from 1 to 30 do
        (multiple-value-bind (out err code)
            (process-result (list (namestring
              (v06-runtime-artifact source (list :stress t :validate t :fail-allocation ordinal)))))
          (cond ((zerop code) (same (format nil "true~%") out) (same "" err) (return))
                (t (same 4 code) (same "" out) (same (format nil "runtime error: allocation failure~%") err))))
        finally (error "Allocation enumeration did not terminate: ~A" (first fixture))))))

(deftest v09-failed-append-keeps-old-list
  (let* ((old (mognitio.value::list-literal 1 2))
         (mognitio.runtime::*allocation-hook* (lambda (kind) (declare (ignore kind)) (error 'storage-condition))))
    (signals mognitio.runtime:program-runtime-failure (mognitio.value::list-append-value old 3))
    (same 2 (mognitio.value::list-value-length old))
    (same 2 (mognitio.value::list-value-element old))
    (same 1 (mognitio.value::list-value-element (mognitio.value::list-value-previous old)))))

(deftest v09-length-overflow-before-allocation
  (let ((calls 0))
    (let ((mognitio.runtime::*allocation-hook* (lambda (kind) (declare (ignore kind)) (incf calls))))
      (let ((failure (handler-case
                       (mognitio.value::list-append-value
                         (mognitio.value::%make-list-value mognitio.integer:+maximum+ nil nil) 0)
                       (mognitio.runtime:program-runtime-failure (c) c))))
        (same :list-length-overflow (mognitio.runtime::failure-kind failure)))
      (let ((failure (handler-case
                       (mognitio.text:text-concat
                         (mognitio.text::%make-text-value #(65) mognitio.integer:+maximum+)
                         (mognitio.text::%make-text-value #(65) 1))
                       (mognitio.runtime:program-runtime-failure (c) c))))
        (same :string-size-overflow (mognitio.runtime::failure-kind failure)))
      (same 0 calls))))

(deftest v09-rename-outcome-uncertainty
  (dolist (replace-first '(nil t))
    (let* ((source (put-text (fresh-path) "true"))
           (output (put-text (fresh-path ".elf") "previous"))
           (original (fdefinition 'mognitio.artifact::replace-image)))
      (replacing (mognitio.artifact::replace-image
                  (lambda (temporary destination)
                    (when replace-first (funcall original temporary destination))
                    (error 'sb-posix:syscall-error :name "rename" :errno sb-posix:eio)))
        (multiple-value-bind (out err code) (driver-result (build-args source output))
          (same 2 code) (same "" out)
          (is (search "replacement outcome is unknown" err))))
      (if replace-first (expect-artifact output :true)
          (same "previous" (uiop:read-file-string output)))
      (same nil (temporary-images)))))

(deftest v09-short-write-precommit
  (let ((source (put-text (fresh-path) "true")) (output (put-text (fresh-path ".elf") "previous")))
    (replacing (mognitio.artifact::write-image
                (lambda (image stream) (write-sequence image stream :end 8)))
      (expect-driver (build-args source output) 2))
    (same "previous" (uiop:read-file-string output))
    (same nil (temporary-images))))
