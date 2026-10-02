(in-package #:mognitio.native.runtime)

(defun utf8-feed-unit ()
  ;; pointer, byte count, four-word state; no allocation or callee-save writes.
  (runtime-unit :utf8.feed
    (append
      '((:load-word :r8 :rsp 8) (:load-word :r9 :rsp 16) (:load-word :r10 :rsp 24)
        (:label :next) (:cmp-imm :r9 0) (:jz :valid) (:load-byte :r11 :r8 0)
        (:load-word :rax :r10 0) (:test) (:jnz :continuation)
        (:cmp-imm :r11 128) (:jb :scalar))
      (loop for (low high pending minimum mask) in mognitio.runtime::*utf8-leads* append
        (let ((next (intern (format nil "LEAD-~D" pending) :keyword)))
          `((:cmp-imm :r11 ,low) (:jb :invalid) (:cmp-imm :r11 ,high) (:ja ,next)
            (:mov-reg :rax :r11) (:and-imm :rax ,mask) (:store-word :r10 8 :rax)
            (:imm-rax ,pending) (:store-word :r10 0 :rax)
            (:imm-rax ,minimum) (:store-word :r10 16 :rax) (:jmp :advance) (:label ,next))))
      '((:jmp :invalid) (:label :continuation)
        (:cmp-imm :r11 128) (:jb :invalid) (:cmp-imm :r11 191) (:ja :invalid)
        (:load-word :rax :r10 8) (:imm-rcx 64) (:mul)
        (:add-imm :r11 -128) (:add-reg :rax :r11) (:store-word :r10 8 :rax)
        (:load-word :rcx :r10 0) (:dec-rcx) (:store-word :r10 0 :rcx) (:jnz :advance)
        (:load-word :rcx :r10 16) (:cmp) (:jb :invalid)
        (:cmp-imm :rax 1114111) (:ja :invalid) (:cmp-imm :rax 55296) (:jb :scalar)
        (:cmp-imm :rax 57343) (:jbe :invalid)
        (:label :scalar) (:load-word :rax :r10 24) (:add-imm :rax 1) (:jo :string-size-overflow)
        (:store-word :r10 24 :rax)
        (:label :advance) (:add-imm :r8 1) (:add-imm :r9 -1) (:jmp :next)
        (:label :valid) (:imm-rax 0) (:ret) (:label :invalid) (:imm-rax -1) (:ret)))))

(defun utf8-count-unit ()
  (runtime-unit :utf8.count
    (append (helper-frame 8)
      '((:load-frame :rax 16) (:store-out 0 :rax) (:load-frame :rax 24) (:store-out 8 :rax)
        (:lea-base :rax :rbp -32) (:store-out 16 :rax) (:call (:runtime :utf8.feed))
        (:test) (:js :invalid) (:load-frame :rax -32) (:test) (:jnz :invalid)
        (:load-frame :rax -8) (:jmp :done) (:label :invalid) (:imm-rax -1) (:label :done))
      (helper-return))))
