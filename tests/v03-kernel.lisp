(in-package #:mognitio.tests)

(defun v03-positive (source expected &optional cli)
  (same expected (compiled-result source))
  (expect-artifact (build-text source) expected)
  (when cli (expect-source source expected)))

(defun v03-reject (source phase)
  (let ((path (put-text (fresh-path) source)) (output (fresh-path ".elf")))
    (dolist (existing '(nil t))
      (when existing (put-text output "previous artifact"))
      (dolist (args (list (list "run" (namestring path)) (build-args path output)))
        (multiple-value-bind (out err code) (driver-result args)
          (is (= 1 code) (format nil "Expected rejection: ~A; got ~D: ~A" source code err)) (same "" out)
          (is (search (format nil ": ~A:" phase) err))))
      (if existing (same "previous artifact" (uiop:read-file-string output))
          (is (not (probe-file output)))))))

(defun v03-runtime (source diagnostic &optional cli)
  (let ((path (put-text (fresh-path) source))
        (expected (format nil "runtime: ~A~%" diagnostic))
        (artifact (build-text source)))
    (multiple-value-bind (out err code) (driver-result (list "run" (namestring path)))
      (same 4 code) (same "" out) (same expected err))
    (multiple-value-bind (out err code) (process-result (list (namestring artifact)))
      (same 4 code) (same "" out) (same expected err))
    (when cli
      (multiple-value-bind (out err code) (cli-result (list "run" (namestring path)))
        (same 4 code) (same "" out) (same expected err)))
    artifact))

;; int was a valid v0.3 name; v0.4 reserves it. Rejection coverage is in v04-functions.
(deftest v03-positive-kernel
  (dolist (text
            '("(true)" "let unitPrice: int = 120; var count: int = 2; count = count + 1; count * unitPrice == 360"
              "let a: int = 1 + 2 * 3; let b: int = (1 + 2) * 3; branch when{(a == 7)=>{ b == 9 },else=>{ false }}"
              "10 - 3 - 2 == 5" "24 / 4 / 2 == 3" "-(-1) == 1" "10 == 10" "0 == 0"
              "-9223372036854775808 < 9223372036854775807"
              "- 9223372036854775808 == (-9223372036854775808)"
              "7 / 3 == 2" "-7 / 3 == -2" "7 / -3 == -2" "-7 / -3 == 2"
              "-7 % 3 == -1" "7 % -3 == 1" "-7 % -3 == -1" "0 % 3 == 0"
              "1 < 2 == true" "(1 < 2) == (3 < 4)" "true != false" "1 != 2"
              "let n: int = branch when{(false)=>{ 1 },else=>{ 2 }}; n == 2"
              "let chosen: int = branch when{(true)=>{ let result: int = 1; result },else=>{ let result: int = 2; result }}; chosen == 1"
              "var n: int = 0; let ok: bool = branch when{(true)=>{ n = 2; true },else=>{ n = 9; false }}; branch when{(ok)=>{ n == 2 },else=>{ false }}"
              "var value: int = 1; let sum: int = (branch when{(true)=>{ value = 2; value },else=>{ 0 }}) + value; sum == 4"
              "var value: int = 1; let sum: int = value + (branch when{(true)=>{ value = 2; value },else=>{ 0 }}); sum == 3"
              "var value: int = 8; let n: int = value / (branch when{(true)=>{ value = 2; value },else=>{ 1 }}); n == 4"
              "var value: int = 8; let n: int = value - (branch when{(true)=>{ value = 2; value },else=>{ 1 }}); n == 6"
              "branch when{(false)=>{ 1 / 0 },else=>{ 1 }} == 1"
              "branch when{(true)=>{ 1 },else=>{ 1 % 0 }} == 1"
              "let x: int = 1; let y: int = branch when{(true)=>{ var localX: int = 2; localX = 3; localX },else=>{ 0 }}; branch when{(y == 3)=>{ x == 1 },else=>{ false }}"
              "var ok: bool = false; ok = true; ok"
              "let true1: int = 1; let Let: int = 2; let intValue: int = 3; let _a2: int = 4; true1 + Let + intValue + _a2 == 10"
              "let x: int = 1; let X: int = 2; x + X == 3"
              "let first: int = branch when{(true)=>{ let item: int = 1; item },else=>{ 0 }}; let item: int = 2; branch when{(first == 1)=>{ item == 2 },else=>{ false }}"
              "var a: int = 1; var b: int = 2; let x: int = branch when{(true)=>{ a = 3; b = 4; a + b },else=>{ b = 9; 0 }}; branch when{(x == 7)=>{ a * b == 12 },else=>{ false }}"
              "var a: int = 1; let x: int = branch when{(branch when{(true)=>{ a = 5; true },else=>{ false }})=>{ a },else=>{ 0 }}; x == 5"
              "var a: int = 1; let x: int = branch when{(false)=>{ a = 9; 0 },else=>{ branch when{(true)=>{ a = 2; a },else=>{ 1 }} }}; branch when{(x == 2)=>{ a == 2 },else=>{ false }}"))
    (v03-positive text :true))
  (dolist (text '("1 > 2" "1 >= 2" "2 < 1" "2 <= 1" "1 == 2" "true == false" "false != false"))
    (v03-positive text :false))
  (dolist (text '("1 <= 1" "1 >= 1" "-1 < 0" "0 > -1" "-1 == -1"))
    (v03-positive text :true))
  (v03-positive "let result: int = (2 + 3) * 4; result == 20" :true t))

(deftest v03-rejection-kernel
  (dolist (text '("12abc" "1_000" "$" "$name" "0x10" "let 日本 = 1; true"))
    (v03-reject text "lex"))
  (dolist (text '("let x;" "var x = ; true" "let x = 1 true" "true;" ";true"
                  "let int x = 1; true" "let true = 1; true" "x = y = 1; true"
                  "let x = 1; (x = 2) == 2" "1 < 2 < 3" "true == false == true"
                  "true === true" "1 += 2"  "if(true){true}else branch when{(false)=>{true},else=>{false}}"))
    (v03-reject text "parse"))
  (dolist (text '("let x = x; true" "true1" "truefalse" "x = 1; true"
                  "let y = x; let x = 1; true" "let x: int = 1; let x = 2; true"
                  "let x: int = 1; x = 2; true" "var x: int = 1; x = true; true"
                  "1 + true == 2" "1 == true" "true < false" "branch when{(1)=>{true},else=>{false}}"
                  "branch when{(true)=>{1},else=>{false}}" "42" "1 < (2 < 3)"
                  "9223372036854775808 == 0" "-9223372036854775809 == 0"
                  "-(9223372036854775808) == 0"
                  "branch when{(false)=>{9223372036854775808},else=>{0}} == 0"
                  "let y: int = branch when{(true)=>{let x: int = 1; x},else=>{0}}; x == 1"
                  "let y = branch when{(true)=>{let x: int = 1; x},else=>{x}}; y == 1"
                  "var x = branch when{(true)=>{x = 1; 1},else=>{0}}; true"
                  "let x = branch when{(branch when{(true)=>{let x = 1; true},else=>{false}})=>{1},else=>{0}}; true"
                  "let a = branch when{(true)=>{let b = branch when{(true)=>{let a = 1; a},else=>{0}}; b},else=>{0}}; true"
                  "let x: int = 1; let y = branch when{(false)=>{let z = branch when{(true)=>{var x = false; 0},else=>{0}};z},else=>{0}};true"))
    (v03-reject text "semantic"))
  (dolist (outer '("let" "var"))
    (dolist (inner '("let" "var"))
      (dolist (condition '("true" "false"))
        (v03-reject (format nil "~A x = 1; let y = branch when{(~A)=>{~A x = false; 1},else=>{0}};true"
                            outer condition inner) "semantic")
        (v03-reject (format nil "~A x = branch when{(~A)=>{~A x = 1; x},else=>{0}};true"
                            outer condition inner) "semantic"))))
  (v03-reject (format nil "~A == 0" (make-string 10000 :initial-element #\9)) "semantic")
  (v03-reject (format nil "~A1 == 1" (make-string 10000 :initial-element #\0)) "lex"))

(deftest v03-runtime-arithmetic
  (dolist (expr '("9223372036854775807 + 1" "-9223372036854775808 - 1"
                  "9223372036854775807 * 2" "-(-9223372036854775808)"
                  "-9223372036854775808 / -1" "-9223372036854775808 % -1"
                  "(9223372036854775807 + 1) - 1"))
    (v03-runtime (format nil "~A == 0" expr) "integer overflow")
    (v03-positive (format nil "branch when{(false)=>{~A},else=>{0}} == 0" expr) :true))
  (dolist (expr '("1 / 0" "0 / 0" "1 / 0 + 1 % 0"))
    (v03-runtime (format nil "~A == 0" expr) "division by zero" t))
  (v03-runtime "1 % 0 == 0" "remainder by zero" t)
  (v03-runtime "var n: int = -9223372036854775808; -n == 0" "integer overflow" t)
  (v03-runtime "var n: int = 0; 1 / n == 0" "division by zero")
  (v03-runtime "var n: int = 0; 1 % n == 0" "remainder by zero")
  (v03-runtime "let unused: int = 1 / 0; true" "division by zero")
  (v03-runtime "var n: int = 1; n = 1 % 0; true" "remainder by zero")
  (v03-runtime "branch when{(true)=>{let n: int = 1 / 0; false},else=>{true}}" "division by zero")
  (let ((checked (check-program (parse-text "1 / 0 == 0"))))
    (replacing (mognitio.backend.cl::host-compile
                (lambda (form) (declare (ignore form)) (mognitio.runtime:runtime-error :overflow)))
      (signals internal-failure (compile-program checked)))))

(deftest v03-integer-machine-goldens
  (dolist (pair '(((:imm-rax -9223372036854775808) "48b80000000000000080")
                  ((:imm-rcx 9223372036854775807) "48b9ffffffffffffff7f")
                  ((:imm-rdx -1) "48baffffffffffffffff")
                  ((:load-rax 0) "488b842400000000") ((:load-rcx 256) "488b8c2400010000")
                  ((:store-rax 8) "4889842408000000") ((:push-zero) "6a00")
                  ((:dec-rcx) "48ffc9") ((:test-rcx) "4885c9") ((:neg) "48f7d8")
                  ((:add) "4801c8") ((:sub) "4829c8") ((:mul) "480fafc1")
                  ((:cmp) "4839c8") ((:cqo) "4899") ((:idiv) "48f7f9")
                  ((:cmp-rcx-minus-one) "4883f9ff") ((:cmp-rax-rdx) "4839d0")
                  ((:mov-rax-rdx) "4889d0") ((:set-bool :lt) "0f9cc00fb6c0")
                  ((:set-bool :ge) "0f9dc00fb6c0") ((:mov-r10d 16) "41ba10000000")
                  ((:dec-r10d) "41ffca") ((:mov-edi-r8d) "4489c7") ((:mov-edi-r9d) "4489cf")))
    (same (hex-bytes (second pair)) (mognitio.amd64:encode (machine (first pair)))))
  (same (hex-bytes "0f8000000000")
        (mognitio.amd64:encode (machine '(:jo :end) '(:label :end))))
  (dolist (form '((:imm-rax 9223372036854775808) (:load-rax -8) (:store-rax 1)
                  (:load-rcx 2147483648) (:set-bool :unsigned) (:idiv 1)))
    (signals internal-failure (mognitio.amd64:encode (machine form))))
  (let* ((ir (native-ir "var x: int = 1; let y: int = branch when{(true)=>{x = 2; 3},else=>{4}}; x + y == 5"))
         (join (find-if (lambda (b) (= 2 (length (mognitio.ir:basic-block-parameters b))))
                        (entry-blocks ir))))
    (is join)
    (let* ((edge (find-if (lambda (b) (eq :jump (first (mognitio.ir:basic-block-terminator b))))
                          (entry-blocks ir)))
           (old (mognitio.ir:basic-block-terminator edge)))
      (setf (mognitio.ir:basic-block-terminator edge) (list :jump (second old) nil))
      (signals internal-failure (mognitio.ir:verify-module ir))))
  (let* ((ir (native-ir "1 + 2 == 3"))
         (inst (find :add (mognitio.ir:basic-block-instructions (first (entry-blocks ir)))
                     :key #'mognitio.ir:instruction-op)))
    (is inst)
    (setf (mognitio.ir:instruction-operands inst) '(999 0))
    (signals internal-failure (mognitio.ir:verify-module ir)))
  ;; A frame larger than a page still touches all homes and preserves old values.
  (let ((text (with-output-to-string (out)
                (dotimes (i 600) (format out "let x~D: int = ~D; " i i))
                (write-string "x0 + x599 == 599" out))))
    (v03-positive text :true)))

(deftest v03-runtime-output-faults
  (let ((artifact (build-text "1 / 0 == 0")) (source (put-text (fresh-path) "1 / 0 == 0")))
    (dolist (mode '("partial-eintr" "zero" "error" "eintr-budget"))
      (multiple-value-bind (out err code)
          (process-result (list "python3" (namestring (root-path "tests/runtime-syscalls.py"))
                                (namestring artifact) mode "runtime"))
        (same 4 code) (same "" out)
        (same (if (string= mode "partial-eintr") (format nil "runtime: division by zero~%") "") err)))
    (dolist (argv (list (list (namestring artifact))
                        (list (namestring (root-path "bin/mgn")) "run" (namestring source))))
      (dolist (redirection '("2>/dev/full" "2>&-"))
        (multiple-value-bind (out err code)
            (process-result (append (list "/bin/sh" "-c" (format nil "exec \"$@\" ~A" redirection) "test") argv))
          (same 4 code) (same "" out) (same "" err)))))
  (dolist (results '((-4 2 -4 3 1000) (0) (-5) (-4 -4 -4 -4 -4 -4 -4 -4 -4 -4 -4 -4 -4 -4 -4 -4)))
    (let ((remaining results) (offsets nil) (lengths nil))
      (with-open-file (stream (fresh-path ".stderr") :direction :output)
        (replacing (mognitio.runtime::write-chunk
                    (lambda (fd bytes offset count)
                      (declare (ignore fd bytes))
                      (push offset offsets) (push count lengths)
                      (let ((result (pop remaining)))
                        (unless result (error "Unexpected extra write"))
                        (if (plusp result) (min count result) result))))
          (same 4 (mognitio.runtime:write-runtime-failure
                    (make-condition 'mognitio.runtime:integer-runtime-failure :kind :overflow) stream))))
      (same nil remaining)
      (when (= (length results) 5)
        (same '(0 0 2 2 5) (reverse offsets))
        (same '(26 26 24 24 21) (reverse lengths))))))

(deftest v03-contract-boundaries
  ;; Exercise arithmetic failures through mutable values, including dead branches.
  (dolist (pair '(("var x: int = 9223372036854775807; " "x + 1")
                  ("var x: int = -9223372036854775808; " "x - 1")
                  ("var x: int = 9223372036854775807; " "x * 2")
                  ("var x: int = -9223372036854775808; " "x / -1")
                  ("var x: int = -9223372036854775808; " "x % -1")))
    (v03-runtime (format nil "~A~A == 0" (first pair) (second pair)) "integer overflow")
    (v03-positive (format nil "~Abranch when{true=>{0},else=>{~A}} == 0" (first pair) (second pair)) :true))
  (v03-positive "true == true" :true)
  (dolist (space (list " " (string #\Tab) (string #\Newline) (string #\Return)
                       (format nil "~C~C" #\Return #\Newline)))
    (v03-positive (format nil "let~An: int~A=~A-~A9223372036854775808~A;~An~A<~A0"
                          space space space space space space space space) :true))
  ;; Building a program which later fails still replaces a previous output.
  (let* ((text "var x: int = 0; branch when{(true)=>{1 / x},else=>{2}} == 0")
         (source (put-text (fresh-path) text))
         (output (put-text (fresh-path ".elf") "previous")))
    (expect-cli (build-args source output) 0)
    (let ((bytes (read-bytes output)))
      (same bytes (read-bytes (build-text text))))
    (delete-file source)
    (multiple-value-bind (out err code)
        (process-result (list "env" "-i" "PATH=/nonexistent" "IGNORED=1"
                              (namestring output) "extra" "--ignored"))
      (same 4 code) (same "" out) (same (format nil "runtime: division by zero~%") err)))
  ;; Hand-derived edge arguments: result, then outer symbols in declaration order.
  (let* ((ir (native-ir "var a: int = 10; var b: int = 20; let x: int = branch when{(true)=>{a = 30; b = 40; let local: int = 99; 50},else=>{b = 60; 70}}; a + b == x"))
         (blocks (entry-blocks ir))
         (join (find-if #'mognitio.ir:basic-block-parameters blocks))
         (edges (remove-if-not (lambda (b) (eq :jump (first (mognitio.ir:basic-block-terminator b)))) blocks))
         (constants (make-hash-table)))
    (dolist (b blocks)
      (dolist (i (mognitio.ir:basic-block-instructions b))
        (when (eq :constant (mognitio.ir:instruction-op i))
          (setf (gethash (mognitio.ir:instruction-result i) constants) (mognitio.ir:instruction-value i)))))
    (same '(:int :int :int) (mapcar #'cdr (mognitio.ir:basic-block-parameters join)))
    (same '((50 30 40) (70 10 60))
          (mapcar (lambda (b) (mapcar (lambda (id) (gethash id constants))
                                     (third (mognitio.ir:basic-block-terminator b)))) edges))
    (let ((params (mognitio.ir:basic-block-parameters join)))
      (setf (cdr (first params)) :bool)
      (signals internal-failure (mognitio.ir:verify-module ir))
      (setf (cdr (first params)) :int
            (car (second params)) (car (first params)))
      (signals internal-failure (mognitio.machine:lower-module ir))))
  ;; Overflow flags must be consumed before any following machine operation.
  (let* ((ir (native-ir "let unused: int = -1 + 2 - 3 * 4; true"))
         (code (mognitio.machine:lower-module ir))
         (ops (mapcar #'mognitio.machine:instruction-opcode code)))
    (dolist (op '(:neg :add :sub :mul))
      (let ((tail (member op ops))) (is tail) (same :jo (second tail)))))
  (dolist (source '("let unused: int = 1 / 2; true" "let unused: int = 1 % 2; true"))
    (let* ((code (mognitio.machine:lower-module (native-ir source)))
           (ops (mapcar #'mognitio.machine:instruction-opcode code))
           (division (position :idiv ops)))
      (is division)
      (same '(:test-rcx :jz :cmp-rcx-minus-one :jnz :imm-rdx :cmp-rax-rdx :jz :label :cqo :idiv)
            (subseq ops (- division 9) (1+ division))))))
