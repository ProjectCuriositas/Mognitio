(in-package #:mognitio.native.runtime)

(defun verify-numeric-operation-forms (data forms)
  ;; Reconstruct the permitted instruction contract without calling the emitter.
  (let* ((op (first data)) (type (second data)) (width (second (second type)))
         (signed (eq :signed (third type))) (comparison (member op '(:eq :ne :lt :le :gt :ge)))
         (labels (loop for form in forms when (eq :label (first form)) collect (second form)))
         (expected nil))
    (cond
      (comparison
       (setf expected
             (list '(:cmp) (list :set-bool
               (if signed op (case op (:lt :ult) (:le :ule) (:gt :ugt) (:ge :uge) (otherwise op)))))))
      ((member op '(:div :rem))
       (if signed
           (progn
             (unless (and (= 2 (length labels)) (not (equal (first labels) (second labels))))
               (internal-error "Invalid checked division labels"))
             (setf expected
               (append '((:test-rcx) (:jz :division-by-zero))
                 (list '(:cmp-rcx-minus-one) (list :jnz (first labels))
                       (list :imm-rdx (- (expt 2 63))) '(:cmp-rax-rdx))
                 (if (eq op :div) '((:jz :overflow))
                     (list (list :jnz (first labels)) '(:imm-rax 0) (list :jmp (second labels))))
                 (list (list :label (first labels)) '(:cqo) '(:idiv))
                 (when (eq op :rem) '((:mov-rax-rdx)))
                 (list (list :label (second labels))))))
           (setf expected (append '((:test-rcx) (:jz :division-by-zero) (:imm-rdx 0) (:div-rcx))
                                  (when (eq op :rem) '((:mov-rax-rdx)))))))
      (signed (setf expected (list (list op) '(:jo :overflow))))
      ((eq op :neg) (setf expected '((:test) (:jnz :overflow))))
      ((eq op :mul) (setf expected '((:umul) (:cmp-imm :rdx 0) (:jnz :overflow))))
      (t (setf expected (list (list op) '(:jb :overflow)))))
    (when (and (not comparison) (< width 64))
      (setf expected
            (append expected
              (if signed
                  (list (list :imm-rcx (- (expt 2 (1- width)))) '(:cmp) '(:jl :overflow)
                        (list :imm-rcx (1- (expt 2 (1- width)))) '(:cmp-reg :rcx :rax) '(:jl :overflow))
                  (list (list :imm-rcx (1- (expt 2 width))) '(:cmp) '(:ja :overflow))))))
    (unless (equal expected forms) (internal-error "Invalid fixed-width native arithmetic contract"))
    forms))
