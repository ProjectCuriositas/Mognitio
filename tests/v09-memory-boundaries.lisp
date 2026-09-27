(in-package #:mognitio.tests)

(defun v06-raw-result (forms &optional options)
  (let ((mognitio.native.runtime::*test-options* options))
    (v05-cross-abi "let x: String=\"a\"+\"b\"; true" 0
      (append (v06-raw-frame) forms
        '((:mov-reg :rsp :rbp) (:pop-rbp) (:ret))))))


(deftest v06-native-invalid-root-pointers
  (dolist (kind '(:interior :free :outside))
    (let* ((forms (append (v06-raw-allocate 1)
                   (case kind
                     (:interior '((:add-imm :rax 8)))
                     (:free '((:store-frame -8 :rax) (:call (:runtime :collect)) (:load-frame :rax -8)))
                     (:outside '((:lea-base :rax :rbp -64))))
                   '((:store-frame -32 :rax) (:call (:runtime :collect)) (:imm-rax 1)))))
      (multiple-value-bind (out err code) (v06-raw-result forms '(:validate t))
        (same 3 code) (same "" out) (same "" err)))))


(deftest v06-native-interior-root-static-bit
  (multiple-value-bind (out err code)
      (v06-raw-result
        (append (v06-raw-allocate 4)
                '((:add-imm :rax 8) (:store-frame -32 :rax)
                  (:call (:runtime :collect)) (:imm-rax 1)))
        '(:validate t))
    (same 3 code) (same "" out) (same "" err)))


(deftest v06-native-root-address-classification
  ;; Known empty and nonempty literal starts are accepted without writing RX
  ;; storage. Zero slots and duplicate dynamic roots survive repeated marking.
  (multiple-value-bind (out err code)
      (v06-raw-result
        (append
          (loop for id below 3 append
            `((:lea-text (:text ,id)) (:store-frame -32 :rax) (:call (:runtime :collect))))
          (v06-raw-allocate 4)
          '((:store-frame -32 :rax) (:store-frame -24 :rax)
            (:call (:runtime :collect)) (:load-frame :rax -32)
            (:load-word :rax :rax 8) (:cmp-imm :rax 1) (:set-bool :eq)))
        '(:validate t))
    (same 0 code) (same (format nil "true~%") out) (same "" err))
  (dolist (kind '(:literal-interior :unmapped :fake-static :free-interior :heap-static))
    (multiple-value-bind (out err code)
        (v06-raw-result
          (append
            (case kind
              (:literal-interior '((:lea-text (:text 1)) (:add-imm :rax 8)))
              (:unmapped '((:imm-rax 1)))
              (:fake-static '((:lea-base :rax :rbp -64) (:imm-rcx 5) (:store-word :rax 8 :rcx)))
              (:free-interior
               (append (v06-raw-allocate 4)
                       '((:store-frame -8 :rax) (:call (:runtime :collect))
                         (:load-frame :rax -8) (:add-imm :rax 8))))
              (:heap-static
               (append (v06-raw-allocate 4) '((:imm-rcx 5) (:store-word :rax 8 :rcx)))))
            '((:store-frame -32 :rax) (:call (:runtime :collect)) (:imm-rax 1)))
          '(:validate t))
      (same 3 code) (same "" out) (same "" err))))

(deftest v09-native-length-boundaries
  (dolist (field '(16 24))
    (let ((forms
            (append
              (loop for base in '(-64 -32) append
                (list (list :lea-base :r8 :rbp base) '(:imm-rax 32) '(:store-word :r8 0 :rax)
                  '(:imm-rax 5) '(:store-word :r8 8 :rax)
                  '(:imm-rax 1) '(:store-word :r8 16 :rax) '(:store-word :r8 24 :rax)))
              (list '(:lea-base :r8 :rbp -64) '(:imm-rax 9223372036854775807)
                (list :store-word :r8 field :rax) '(:store-out 0 :r8)
                '(:lea-base :r9 :rbp -32) '(:store-out 8 :r9)
                '(:call (:helper :text.concat)) '(:jmp :division-by-zero)))))
      (multiple-value-bind (out err code) (v06-raw-result forms '(:mmap-fail t))
        (same 4 code) (same "" out)
        (same (format nil "runtime error: ~A~%" (if (= field 24) "string length overflow" "allocation failure")) err))))
  (dolist (kind '(:list.append :list.buffer))
    (let* ((source "let a:List<Int>=List<Int>[1];discard a->append(2);loop over(a as x:Int){discard x;};true")
           (module (native-ir source))
           (name (mognitio.native.runtime::value-helper-name (v06-core-op module kind)))
           (caller (append (v06-raw-frame)
                     (list '(:lea-base :rax :rbp -64) '(:imm-rcx 9223372036854775807)
                           '(:store-word :rax 32 :rcx) '(:store-out 0 :rax) '(:imm-rax 1) '(:store-out 8 :rax)
                           (list :call name))
                     (v06-raw-finish)))
           (mognitio.native.runtime::*test-options* '(:mmap-fail t)))
      (multiple-value-bind (out err code) (v05-cross-abi source 0 caller)
        (same 4 code) (same "" out)
        (same (format nil "runtime error: ~A~%" (if (eq kind :list.append) "list length overflow" "allocation failure")) err))))
  (dolist (n '(-1 -32 -38))
    (multiple-value-bind (out err code)
        (v06-raw-result (list (list :imm-rax n) '(:store-out 0 :rax) '(:call (:runtime :physical-size))))
      (same 4 code) (same "" out) (same (format nil "runtime error: allocation failure~%") err))))

(deftest v09-buffer-count-corruption
  (let ((original (fdefinition 'mognitio.native.runtime::list-buffer-unit)))
    (replacing (mognitio.native.runtime::list-buffer-unit
                (lambda (instruction)
                  (let ((unit (funcall original instruction)))
                    (setf (mognitio.object:code-unit-instructions unit)
                          (loop for i in (mognitio.object:code-unit-instructions unit)
                                append (if (and (eq :store-word (mognitio.machine:instruction-opcode i))
                                                (equal '(:rdx 32 :rcx) (mognitio.machine:instruction-operands i)))
                                           (append (machine '(:imm-rcx 9223372036854775807)) (list i)) (list i))))
                    unit)))
      (multiple-value-bind (out err code)
          (process-result (list (namestring (v06-runtime-artifact *v09-lifetime-source* '(:stress t :validate t)))))
        (same 3 code) (same "" out) (same "" err)))))
