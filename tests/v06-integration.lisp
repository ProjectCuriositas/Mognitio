(in-package #:mognitio.tests)

(deftest v06-native-artifact-and-output-faults
  (check-native-relocation *v06-gc-source* :true)
  (let* ((source "let s: string=\"a\"+\"日\"; s->slice(0,3)==\"\"")
         (artifact (build-text source)))
    (dolist (mode '("partial-eintr" "zero" "error" "eintr-budget"))
      (multiple-value-bind (out err code)
          (process-result (list "python3" (namestring (root-path "tests/runtime-syscalls.py"))
                                (namestring artifact) mode "runtime"))
        (same 4 code) (same "" out)
        (same (if (string= mode "partial-eintr")
                  (format nil "runtime: string_index_out_of_bounds~%") "") err)))
    (let ((before (read-bytes artifact)) (path (put-text (fresh-path) source)))
      (replacing (mognitio.elf:make-image (lambda (&rest args) (declare (ignore args)) (error "Image fault")))
        (expect-driver (build-args path artifact) 3 "internal:"))
      (same before (read-bytes artifact))
      (same nil (temporary-images)))))

(deftest v06-integration-source-rejections
  (dolist (pair (append
                 (mapcar (lambda (text) (list (sb-ext:string-to-octets text :external-format :utf-8) "lex"))
                         (list "\"abc" "\"abc\\" "\"a\\q\""
                               (format nil "\"a~C\"" #\Newline) (format nil "\"a~C\"" #\Return)))
                 (mapcar (lambda (bytes) (list bytes "source"))
                         '(#(34 237 160 128 34) #(34 192 128 34)
                           #(239 187 191 239 187 191 34 34)))))
    (let ((source (put-bytes (fresh-path) (coerce (first pair) '(vector (unsigned-byte 8)))))
          (output (put-text (fresh-path ".elf") "previous")))
      (dolist (args (list (list "run" (namestring source)) (build-args source output)))
        (multiple-value-bind (out err code) (driver-result args)
          (same 1 code) (same "" out) (is (search (format nil ": ~A:" (second pair)) err))
          (is (search (namestring source) err))))
      (same "previous" (uiop:read-file-string output))))
  (let ((source (format nil "~C~A" (code-char #xfeff) "\"A\"->length()==1")))
    (v03-reject source "source")))

(deftest v06-integration-lifetime-and-composition
  (dolist (source
    '("\"\"!=\"x\"" "\"A\\0B\"!=\"A\\0C\"" "(\"a\"+\"b\")!=(\"a\"+\"c\")"
      "(\"a\"+\"b\")==\"abc\"->slice(0,2)"
      "let f:function():string=function():string{branch when{(true)=>{return \"x\"+\"日\";},else=>{\"\"}}}; let alias: string=f(); var original: string=alias; original=\"replacement\"+\"!\"; let part: string=alias->slice(1,2); let unused: string=\"new\"+\"value\"; branch when{(part==\"日\")=>{alias==\"x日\"},else=>{false}}"
      "let s: string={let inner: string=\"a\"+\"b\"; inner->slice(1,2)}; let x: string=\"other\"+\"value\"; s==\"b\""
      "let f:function():string=function():string{\"a\"+\"b\"}; (branch when{(false)=>{\"\"},else=>{f()}})->slice(0,2)->length()==2"
      "let string_slice:function(string,int,int):string=function(s:string,a:int,b:int):string{s->slice(a,b)}; let alias:function(string,int,int):string=string_slice; let length: int=1; let slice: int=2; alias(\"A日😀\",length,slice)==\"日\""))
    (expect-source source :true)
    (v06-expect-native source :true '(:stress t :validate t :arena-unit 65536 :cap 65536))))
