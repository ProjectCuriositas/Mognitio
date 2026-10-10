(in-package #:mognitio.native.runtime)

(defun numeric-word (value)
  (if (> value mognitio.integer:+maximum+) (- value (ash 1 64)) value))

(defun numeric-operation-forms (data fresh)
  (let* ((op (first data)) (type (second data)) (width (second (second type)))
         (signed (eq :signed (third type))) (safe (funcall fresh)) (done (funcall fresh)))
    (when (member op '(:eq :ne :lt :le :gt :ge))
      (return-from numeric-operation-forms
        `((:cmp) (:set-bool ,(if signed op
                                (or (cdr (assoc op '((:lt . :ult) (:le . :ule) (:gt . :ugt) (:ge . :uge)))) op))))))
    (append
      (if signed
          (case op
            ((:neg :add :sub :mul) `((,op) (:jo :overflow)))
            ((:div :rem)
             (append '((:test-rcx) (:jz :division-by-zero))
               `((:cmp-rcx-minus-one) (:jnz ,safe)
                 (:imm-rdx ,mognitio.integer:+minimum+) (:cmp-rax-rdx))
               (if (eq op :div) '((:jz :overflow))
                   `((:jnz ,safe) (:imm-rax 0) (:jmp ,done)))
               `((:label ,safe) (:cqo) (:idiv))
               (when (eq op :rem) '((:mov-rax-rdx)))
               `((:label ,done)))))
          (case op
            (:neg '((:test) (:jnz :overflow)))
            ((:add :sub) `((,op) (:jb :overflow)))
            (:mul '((:umul) (:cmp-imm :rdx 0) (:jnz :overflow)))
            ((:div :rem)
             (append '((:test-rcx) (:jz :division-by-zero) (:imm-rdx 0) (:div-rcx))
                     (when (eq op :rem) '((:mov-rax-rdx)))))))
      (when (< width 64)
        (multiple-value-bind (lo hi) (mognitio.semantic::numeric-range type)
          (if signed
              `((:imm-rcx ,lo) (:cmp) (:jl :overflow)
                (:imm-rcx ,hi) (:cmp-reg :rcx :rax) (:jl :overflow))
              `((:imm-rcx ,hi) (:cmp) (:ja :overflow))))))))

(defun numeric-mask-forms (width)
  (unless (= width 64) `((:imm-rcx ,(1- (ash 1 width))) (:and-rcx))))

(defun conversion-check-forms (source target)
  (let* ((signed (mognitio.semantic::integer-signed-p source))
         (dest-signed (mognitio.semantic::integer-signed-p target))
         (width (second (mognitio.semantic::integer-width target)))
         (hi (1- (ash 1 (if dest-signed (1- width) width))))
         (lo (if dest-signed (- (ash 1 (1- width))) 0)))
    (append
      (when signed
        (if dest-signed `((:imm-rcx ,lo) (:cmp) (:jl :invalid))
            '((:test) (:js :invalid))))
      (if (and signed dest-signed)
          `((:imm-rcx ,hi) (:cmp-reg :rcx :rax) (:jl :invalid))
          (unless (= hi (1- (ash 1 64)))
            `((:imm-rcx ,(numeric-word hi)) (:cmp) (:ja :invalid)))))))

(defun numeric-method-unit (inst context)
  (let* ((op (mognitio.ir:instruction-op inst)) (source (mognitio.ir:instruction-value inst))
         (result (mognitio.ir:instruction-type inst))
         (parts (mognitio.semantic::canonical-result-arguments context result))
         (success (first parts)) (error (second parts))
         (width (second (mognitio.semantic::integer-width source))))
    (runtime-unit (second (value-helper-name inst))
      (append (helper-frame 10)
        (when parts (helper-root-link 1))
        '((:load-frame :rax 16))
        (case op
          (:integer.convert (conversion-check-forms source success))
          (:integer.to-bits (numeric-mask-forms width))
          (:bits.integer
           (when (and (eq :signed (third result)) (< width 64))
             `((:imm-rcx ,(- 64 width)) (:shl-cl) (:sar-cl))))
          (:bits.length `((:imm-rax ,width)))
          (:bits.and '((:load-frame :rcx 24) (:and-rcx)))
          (:bits.or '((:load-frame :rcx 24) (:or-rcx)))
          (:bits.xor '((:load-frame :rcx 24) (:xor-rcx)))
          (:bits.not (append '((:not-rax)) (numeric-mask-forms width)))
          ((:bits.left :bits.right :bits.at)
           (append
             `((:load-frame :rcx 24) (:cmp-imm :rcx ,width) (:jae :invalid))
             (case op
               (:bits.left (append '((:shl-cl)) (numeric-mask-forms width)))
               (:bits.right '((:shr-cl)))
               (:bits.at '((:shr-cl) (:and-imm :rax 1)))))))
        (when parts
          (append
            '((:store-frame -32 :rax))
            (result-construction :ok result 0 -32)
            '((:jmp :done) (:label :invalid))
            (allocate-object :error (list :descriptor (second error) 0) 1 (if (eq op :integer.convert) 0 2))
            (unless (eq op :integer.convert)
              `((:load-frame :rax 24) (:store-word :rdx 32 :rax)
                (:imm-rax ,width) (:store-word :rdx 40 :rax)))
            '((:store-frame -8 :rdx))
            (result-construction :err result 1 -8)
            '((:label :done))
            (helper-root-unlink 1)))
        (helper-return)) :helper)))
