(in-package #:mognitio.tests)

(defun v110-workload-project (&optional entry checks)
  (let* ((files (loop for file in '("Core/scan.mgn" "Core/symbols.mgn" "Core/text.mgn")
                      collect (cons file (uiop:read-file-string
                        (root-path (concatenate 'string "examples/compiler-workloads/src/" file))))))
         (manifest (project-fixture
           (append files (when entry (list (cons "app.mgn" entry)))
             (when checks (list (cons "checks.mgn"
                              (uiop:read-file-string (root-path "tests/fixtures/v11-checks.mgn")))))))))
    (put-text manifest (format nil "[project]~%name=\"app\"~%root_namespace=\"Workloads\"~%"))
    manifest))

(deftest v110-workloads-forced-collection
  (let ((manifest (v110-workload-project nil t))
        (mognitio.native.runtime::*test-options* '(:stress t :arena-unit 65536 :cap 65536)))
    (multiple-value-bind (out err code) (v11-driver manifest)
      (same 0 code) (same "" err) (is (search "total=5 passed=5" out)))))

(defun v110-counter-image (manifest)
  (let ((layout (fdefinition 'mognitio.object:layout-units))
        (runtime (fdefinition 'mognitio.native.runtime::runtime-unit)))
    (replacing (mognitio.native.runtime::runtime-unit
      (lambda (name forms &optional (kind :runtime))
        (funcall runtime name
          (if (eq name :text.equal)
              (append '((:load-word :rax :r15 144) (:add-imm :rax 1)
                        (:store-word :r15 144 :rax)) forms)
              forms) kind)))
      (replacing (mognitio.object:layout-units
        (lambda (units)
          (let ((entry (first units)))
            (setf (mognitio.object:code-unit-instructions entry)
              (loop for inst in (mognitio.object:code-unit-instructions entry) append
                (if (and (eq (mognitio.machine:instruction-opcode inst) :jmp)
                         (equal (mognitio.machine:instruction-operands inst) '(:print)))
                    (append (machine '(:store-word :r15 24 :rax) '(:mov-reg :rsi :r15)
                      '(:mov-edx 240) '(:mov-edi 2) '(:mov-eax 1) '(:syscall)
                      '(:cmp-imm :rax 240) '(:jz :counter-done)
                      '(:mov-edi 97) '(:mov-eax 60) '(:syscall) '(:ud2)
                      '(:label :counter-done) '(:load-word :rax :r15 24)) (list inst))
                    (list inst)))))
          (funcall layout units)))
        (v12-native manifest '(:gc-counters t))))))

(deftest v110-symbol-comparison-cost
  ;; The driver has no string equality. Its only equality call site is the
  ;; unmodified lookup helper, so the runtime counter measures name comparisons.
  (dolist (size '(8 32 1024))
    (dolist (width (if (= size 1024) '(8) '(8 64)))
      (let ((names (loop for n below size collect
                    (format nil "~A~D" (make-string width :initial-element
                      (if (= width 8) #\a #\日)) n))))
        (dolist (operation (if (= size 1024) '(:missing) '(:first :middle :last :missing :duplicate)))
          (let* ((index (ecase operation (:first 0) ((:middle :duplicate) (floor size 2))
                         (:last (1- size)) (:missing nil)))
                 (name (if index (nth index names) "absent"))
                 (body (with-output-to-string (s)
                   (format s "namespace Workloads;use Workloads\\Core\\{SymbolTable,Registration,Lookup,emptyTable,register,lookup,decimal};~%")
                   (format s "let main:Function(List<String>):Int=function(args:List<String>):Int{var table:SymbolTable=emptyTable();")
                   (format s "var i:Int=0;loop while(i<~D){table=register(table,\"~A\"+decimal(i))->table;i=i+1;};" size (make-string width :initial-element (if (= width 8) #\a #\日)))
                   (if (eq operation :duplicate)
                       (format s "let result:Registration=register(table,\"~A\");assert result->id==~D;assert result->table->entries->length()==~D;" name index size)
                       (format s "assert branch on lookup(table,\"~A\"){Lookup::Found(id:Int)=>~A,Lookup::NotFound=>~A};"
                         name (if index (format nil "id==~D" index) "false") (if index "false" "true")))
                   (format s "0};")))
                 (image (v110-counter-image (v110-workload-project body))))
            (multiple-value-bind (out bytes code)
                (process-result (list (namestring image)) :binary-error t)
              (same 0 code) (same "" out) (same 240 (length bytes))
              (flet ((word (offset) (loop for i below 8 sum (ash (aref bytes (+ offset i)) (* i 8)))))
                (same (+ (/ (* size (1- size)) 2) (if index (1+ index) size)) (word 144))
                (is (> (word 32) size))
                (format t "SYMBOL_COST size=~D width=~D operation=~A comparisons=~D allocations=~D gc=~D mapped=~D~%"
                  size width operation (word 144) (word 32) (word 48) (word 72))))))))))
