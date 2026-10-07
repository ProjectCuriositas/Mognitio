(in-package #:mognitio.native.runtime)

(defun text-length-unit ()
  (runtime-unit :text.length
    '((:load-word :rax :rsp 8) (:load-word :rax :rax 24) (:ret)) :helper))

(defun text-equality-unit (op)
  (runtime-unit op
    `((:load-word :r8 :rsp 8) (:load-word :r9 :rsp 16)
      (:cmp-reg :r8 :r9) (:jz :equal)
      (:load-word :rcx :r8 16) (:load-word :rdx :r9 16)
      (:cmp-reg :rcx :rdx) (:jnz :different)
      (:add-imm :r8 32) (:add-imm :r9 32)
      (:label :loop) (:test-rcx) (:jz :equal)
      (:load-byte :rax :r8 0) (:load-byte :rdx :r9 0)
      (:cmp-rax-rdx) (:jnz :different)
      (:add-imm :r8 1) (:add-imm :r9 1) (:dec-rcx) (:jmp :loop)
      (:label :equal) (:imm-rax ,(if (eq op :text.equal) 1 0)) (:ret)
      (:label :different) (:imm-rax ,(if (eq op :text.equal) 0 1)) (:ret)) :helper))

(defun checked-sum-unit ()
  ;; Both lengths are nonnegative int64 values. Test the difference BEFORE add.
  (runtime-unit :sum
    '((:load-word :rdx :rsp 8) (:load-word :rcx :rsp 16)
      (:imm-rax 9223372036854775807) (:sub)
      (:cmp-rax-rdx) (:jb :string-size-overflow)
      (:mov-reg :rax :rdx) (:add) (:ret))))

(defun copy-forms (label)
  ;; RSI/RCX identify the valid source bytes; RDI advances through destination.
  `((:label ,label) (:test-rcx) (:jz ,(intern (format nil "~A-END" label) :keyword))
    (:load-byte :rdx :rsi 0) (:store-byte :rdi 0 :rdx)
    (:add-imm :rsi 1) (:add-imm :rdi 1) (:dec-rcx) (:jmp ,label)
    (:label ,(intern (format nil "~A-END" label) :keyword))))

(defun text-concat-unit ()
  (runtime-unit :text.concat
    (append (helper-frame 6)
      '((:load-frame :rax 16) (:load-word :rdx :rax 24) (:store-out 0 :rdx)
        (:load-frame :rax 24) (:load-word :rdx :rax 24) (:store-out 8 :rdx)
        (:call (:runtime :sum)) (:store-frame -16 :rax)
        (:load-frame :rax 16) (:load-word :rax :rax 16)
        (:load-frame :rdx 24) (:load-word :rdx :rdx 16)
        (:add-reg :rax :rdx) (:jb :allocation-failed) (:js :allocation-failed)
        (:store-frame -8 :rax)
        (:load-frame :rax -8) (:test) (:jz :empty)
        (:store-out 0 :rax) (:load-frame :rax -16) (:store-out 8 :rax)
        (:call (:runtime :allocate)) (:store-frame -24 :rax)
        (:lea-base :rdi :rax 32)
        (:load-frame :rsi 16) (:load-word :rcx :rsi 16) (:add-imm :rsi 32))
      (copy-forms :left)
      '((:load-frame :rsi 24) (:load-word :rcx :rsi 16) (:add-imm :rsi 32))
      (copy-forms :right)
      '((:load-frame :rax -24) (:jmp :done) (:label :empty) (:lea-text (:text 0)) (:label :done))
      (helper-return)) :helper))

(defun text-slice-unit ()
  (runtime-unit :text.slice
    (append (helper-frame 8)
      '((:load-frame :rax 24) (:test) (:js :string-index-out-of-bounds)
        (:load-frame :rcx 32) (:cmp) (:ja :string-index-out-of-bounds)
        (:load-frame :rdx 16) (:load-word :rdx :rdx 24)
        (:cmp-reg :rcx :rdx) (:ja :string-index-out-of-bounds)
        (:cmp) (:jz :empty)
        (:mov-reg :rdx :rcx) (:sub-reg :rdx :rax) (:store-frame -8 :rdx)
        (:load-frame :rsi 16) (:add-imm :rsi 32) (:imm-reg :r8 0)
        (:label :scan)
        (:load-frame :rax 24) (:cmp-reg :r8 :rax) (:jnz :not-start)
        (:store-frame -16 :rsi)
        (:label :not-start) (:load-frame :rax 32) (:cmp-reg :r8 :rax) (:jz :found)
        ;; Advance over one leading byte, then its continuation bytes.
        (:add-imm :rsi 1) (:add-imm :r8 1)
        (:load-frame :rax 16) (:load-word :rdx :rax 16) (:add-imm :rax 32) (:add-reg :rax :rdx)
        (:label :continuation) (:cmp-reg :rsi :rax) (:jae :scan)
        (:load-byte :rdx :rsi 0) (:and-imm :rdx 192) (:cmp-imm :rdx 128) (:jnz :scan)
        (:add-imm :rsi 1) (:jmp :continuation)
        (:label :found) (:load-frame :rdx -16) (:sub-reg :rsi :rdx) (:store-frame -24 :rsi)
        (:store-out 0 :rsi) (:load-frame :rax -8) (:store-out 8 :rax)
        (:call (:runtime :allocate)) (:store-frame -32 :rax)
        (:lea-base :rdi :rax 32) (:load-frame :rsi -16) (:load-frame :rcx -24))
      (copy-forms :copy)
      '((:load-frame :rax -32) (:jmp :done) (:label :empty) (:lea-text (:text 0)) (:label :done))
      (helper-return)) :helper))

(defun text-allocation-unit ()
  (runtime-unit :allocate
    (append (helper-frame 2)
      '((:load-frame :rax 16) (:store-out 0 :rax) (:call (:runtime :allocate-block))
        (:load-frame :rcx 16) (:store-word :rax 16 :rcx)
        (:load-frame :rcx 24) (:store-word :rax 24 :rcx)) (helper-return))))

(defun text-helper-units (operations literal-count &optional context allocating-values)
  (when (and (option :gc-counters) (option :trace))
    (internal-error "GC counters and lifecycle trace use separate observation builds"))
  (append
    (loop for op in operations collect
      (ecase op
        (:text.length (text-length-unit))
        ((:text.equal :text.not-equal) (text-equality-unit op))
        (:text.concat (text-concat-unit)) (:text.slice (text-slice-unit))))
    (when (or allocating-values (intersection operations '(:text.concat :text.slice)))
      (list (checked-sum-unit) (physical-size-unit) (find-free-unit)
            (validate-root-unit literal-count) (gc-workspace-unit) (gc-release-unit) (gc-mark-unit) (collect-unit context) (allocate-unit) (text-allocation-unit)))))
