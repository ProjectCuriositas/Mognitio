(in-package #:mognitio.tests)

(deftest v014-checked-and-core-proofs
  (dolist (mutation '(:receiver :result :operation))
    (let ((checked (project-checked (v13-manifest "discard List<String>[\"x\"]->join(\"\");0"))))
      (maphash (lambda (node op) (declare (ignore node))
                 (when (eq (operation-info-kind op) :text.join)
                   (ecase mutation
                     (:receiver (setf (operation-info-parameter-types op) '((:list :int) :string)))
                     (:result (setf (operation-info-result-type op) '(:list :string)))
                     (:operation (setf (operation-info-kind op) :text.scalars)))))
               (mognitio.semantic::checked-program-operations checked))
      (signals internal-failure (verify-checked-program checked))))
  (dolist (mutation '(:effect :result :arity))
    (let* ((ir (mognitio.ir:lower-program (project-checked (v13-manifest "discard \"xy\"->scalars()->join(\"\");0"))))
           (instruction (loop for fn in (mognitio.ir:module-functions ir) thereis
                          (loop for block in (mognitio.ir:ir-function-blocks fn) thereis
                            (find :text.join (mognitio.ir:basic-block-instructions block) :key #'mognitio.ir:instruction-op)))))
      (ecase mutation
        (:effect (setf (mognitio.ir::instruction-effects instruction) nil))
        (:result (setf (mognitio.ir:instruction-type instruction) :int))
        (:arity (setf (mognitio.ir:instruction-operands instruction) nil)))
      (signals internal-failure (mognitio.ir:verify-module ir)))))

(deftest v014-native-proof-negatives
  (dolist (mutation '(:root :call :phase))
    (let* ((ir (mognitio.ir:lower-program (project-checked (v13-manifest "discard \"xy\"->scalars()->join(\"\");0"))))
           (mognitio.native.runtime::*runtime-module* ir)
           (units (mognitio.native.runtime::value-helper-units ir))
           (unit (find-if (lambda (u) (eq (first (second (mognitio.object:code-unit-entry u)))
                                         (if (eq mutation :phase) :io.call :text.scalars))) units))
           (forms (mognitio.object:code-unit-instructions unit)))
      (labels ((find-form (op operands) (find-if (lambda (i) (and (eq op (mognitio.machine:instruction-opcode i))
                                            (equal operands (mognitio.machine:instruction-operands i)))) forms)))
        (ecase mutation
          (:root (setf (mognitio.machine:instruction-operands (find-form :store-frame '(-24 :rax))) '(-56 :rax)))
          (:call (setf (mognitio.machine:instruction-operands (find-form :call '((:runtime :allocate-block)))) '((:runtime :collect))))
          (:phase (let ((f (or (find-form :store-frame '(-400 :rax)) (find-form :store-frame '(-728 :rax)))))
                    (setf (mognitio.machine:instruction-operands f) '(-56 :rax)))))
        (signals internal-failure
          (if (eq mutation :phase) (mognitio.native.runtime::verify-v014-phase-shape unit)
              (mognitio.native.runtime::verify-text-collection-helper unit)))))))

(deftest v014-text-failure-boundaries
  (let ((mognitio.value::*text-length-limit* 3))
    (signals mognitio.runtime:program-runtime-failure
      (mognitio.value::text-join (mognitio.value::list-literal (v12-text "aa") (v12-text "bb")) (v12-text ""))))
  (let ((image (v12-native (v13-manifest "discard List<String>[\"aa\",\"bb\"]->join(\"\");0") '(:text-length-limit 3))))
    (multiple-value-bind (out err code) (process-result (list (namestring image)))
      (same "" out) (same 4 code) (is (search "string length overflow" err))))
  (loop for ordinal from 1 to 6 do
    (let ((image (v12-native (v13-manifest "discard \"日ab\"->scalars()->join(\"\");0") (list :fail-allocation ordinal))))
      (multiple-value-bind (out err code) (process-result (list (namestring image)))
        (same "" out) (same 4 code) (is (search "allocation failure" err))))))

(deftest v014-native-cost-counters
  (dolist (n '(64 128 256))
    (let* ((text (make-string n :initial-element #\日))
           (body (format nil "discard ~S->scalars()->join(\"😀\");0" text))
           (image (v12-native (v13-manifest body) '(:text-counters t))))
      (multiple-value-bind (out bytes code) (process-result (list (namestring image)) :binary-error t)
        (same "" out) (same 0 code) (same 48 (length bytes))
        (same (list (* n 3) n n (+ (* n 3) (* (1- n) 4)) n n)
          (loop for start from 0 below (length bytes) by 8 collect
            (loop for i below 8 sum (ash (aref bytes (+ start i)) (* i 8)))))))))

(deftest v014-accepted-root-kind
  (let* ((root (v13-directory))
         (body (v14-error-body (format nil "readDirectory(~S)" root) "List<DirectoryEntry>" "ReadDirectory" "UnsupportedTarget" root "Body"))
         (mognitio.io::*operation-hook* (lambda (stage &rest args) (declare (ignore args))
           (when (eq stage :directory-opened) (mognitio.io::directory-reject 4)))))
    (same 0 (v13-host-code body *v14-phase-import*))
    (same 0 (v13-native-code body *v14-phase-import* '(:directory-after-accept-kind t)))))

(deftest v014-stream-latch-proof
  (let* ((ir (mognitio.ir:lower-program (project-checked (v13-manifest "discard readStdin();0"))))
         (mognitio.native.runtime::*runtime-module* ir)
         (units (mognitio.native.runtime::value-helper-units ir))
         (unit (find-if (lambda (u) (let ((name (second (mognitio.object:code-unit-entry u))))
                                    (and (consp name) (eq (third name) :read-stdin)))) units))
         (jump (find-if (lambda (i) (and (eq (mognitio.machine:instruction-opcode i) :jnz)
                                        (equal (mognitio.machine:instruction-operands i) '((:runtime :directory.internal)))))
                         (mognitio.object:code-unit-instructions unit))))
    (is jump)
    (setf (mognitio.machine:instruction-opcode jump) :jz)
    (signals internal-failure (mognitio.native.runtime::verify-v014-stream-cleanup-latch unit))))
