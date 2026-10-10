(in-package #:mognitio.native.runtime)

;; Directory scratch uses the existing 64-byte ownership ABI. Raw helpers never
;; allocate managed objects; all addresses live in ordinary frame homes at calls.
(defun directory-map-unit ()
  ;; Return the raw syscall result to the owning operation. It must classify an
  ;; impossible argument failure before selecting cleanup and a terminal path.
  (runtime-unit :directory.map
    '((:load-word :rsi :rsp 8) (:imm-reg :rdi 0) (:imm-rdx 3)
      (:imm-reg :r10 34) (:imm-reg :r8 -1) (:imm-reg :r9 0)
      (:mov-eax 9) (:syscall) (:ret))))

(defun directory-errno-unit ()
  (runtime-unit :directory.errno
    (append
      (loop for (kind . numbers) in '((0 36) (2 2) (3 13 1 30) (4 20 21) (6 24 23 28 122 12 31)) append
        (loop for number in numbers append `((:cmp-imm :rax ,(- number)) (:jz ,(intern (format nil "KIND-~D" kind) :keyword)))))
      '((:imm-rax 7) (:ret))
      (loop for kind in '(0 2 3 4 6) append
        `((:label ,(intern (format nil "KIND-~D" kind) :keyword)) (:imm-rax ,kind) (:ret))))))

(defun directory-cleanup-unit (&optional (name :directory.cleanup))
  (runtime-unit name
    (append (helper-frame 8)
      (when (eq name :io.cleanup)
        (append '((:load-frame :rax 16) (:load-word :rcx :rax 8)
                  (:cmp-imm :rcx -2) (:jnz :ordinary-record)
                  (:store-out 0 :rax) (:call (:runtime :publication.cleanup)))
                (helper-return) '((:label :ordinary-record))))
      '((:load-frame :rax 16) (:store-frame -8 :rax) (:store-out 0 :rax)
        (:load-word :rdx :rax 8) (:cmp-imm :rdx -1) (:jl :bad-fd) (:jmp :close)
        (:label :bad-fd) (:imm-rdx -1) (:store-word :rax 8 :rdx)
        (:imm-rdx 1) (:store-frame -24 :rdx) (:label :close)
        (:call (:runtime :io.close)) (:test) (:jz :maps)
        (:cmp-imm :rax -9) (:jz :bad-close) (:cmp-imm :rax -4095) (:jb :bad-close)
        (:store-frame -16 :rax) (:jmp :maps)
        (:label :bad-close) (:imm-rax 1) (:store-frame -24 :rax) (:label :maps))
      (loop for pair in '((16 24) (32 40) (48 56)) for i from 0 append
        (scoped-forms (intern (format nil "MAP-~D" i) :keyword)
          `((:load-frame :rdx -8) (:load-word :rdi :rdx ,(first pair))
            (:cmp-imm :rdi 0) (:jz :next) (:load-word :rsi :rdx ,(second pair))
            (:imm-rax 0) (:store-word :rdx ,(first pair) :rax)
            (:cmp-imm :rdi 0) (:jl :bad) (:cmp-imm :rsi 0) (:jle :bad) (:mov-reg :rax :rdi) (:and-imm :rax 4095) (:test) (:jnz :bad)
            (:mov-eax 11) (:syscall)
            ,@(when (option :directory-cleanup-fault) `((:imm-rax ,(option :directory-cleanup-fault))))
            (:test) (:jz :next)
            (:cmp-imm :rax -22) (:jz :bad) (:cmp-imm :rax -14) (:jz :bad)
            (:cmp-imm :rax -4095) (:jl :bad) (:test) (:js :external) (:jmp :bad)
            (:label :external) (:load-frame :rcx -16) (:test-rcx) (:jnz :next)
            (:store-frame -16 :rax) (:jmp :next)
            (:label :bad) (:imm-rax 1) (:store-frame -24 :rax) (:label :next))))
      '((:load-frame :rax -16) (:load-frame :rdx -24)) (helper-return))))

(defun directory-compare-unit (&optional names-only)
  ;; Compare unsigned UTF-8 bytes, then byte length, then observation ordinal.
  ;; Valid UTF-8 has exactly the same lexical order as Unicode scalar values.
  (runtime-unit (if names-only :directory.name-compare :directory.compare)
    (append '((:load-word :r8 :rsp 8) (:load-word :r9 :rsp 16) (:load-word :r10 :rsp 24)
      (:load-word :rsi :r8 0) (:add-reg :rsi :r10) (:load-word :rdi :r9 0) (:add-reg :rdi :r10)
      (:load-word :rcx :r8 8) (:load-word :rdx :r9 8) (:cmp-reg :rcx :rdx) (:jbe :length)
      (:mov-reg :rcx :rdx) (:label :length) (:test-rcx) (:jz :prefix)
      (:load-byte :rax :rsi 0) (:load-byte :rdx :rdi 0) (:cmp-rax-rdx) (:jb :less) (:ja :greater)
      (:add-imm :rsi 1) (:add-imm :rdi 1) (:dec-rcx) (:jmp :length)
      (:label :prefix) (:load-word :rax :r8 8) (:load-word :rcx :r9 8) (:cmp) (:jb :less) (:ja :greater)
)
      (unless names-only '((:load-word :rax :r8 32) (:load-word :rcx :r9 32) (:cmp) (:jb :less) (:ja :greater)))
      '(      (:imm-rax 0) (:ret) (:label :less) (:imm-rax -1) (:ret) (:label :greater) (:imm-rax 1) (:ret)))))

(defun directory-row-address (slot target)
  `((:load-frame :rax ,slot) (:imm-rcx 40) (:mul) (:load-frame ,target -8) (:add-reg ,target :rax)))
(defun directory-compare-rows (a b)
  (append (directory-row-address a :rdx) '((:store-out 0 :rdx))
          (directory-row-address b :rdx) '((:store-out 8 :rdx) (:load-frame :rax -16)
            (:store-out 16 :rax) (:call (:runtime :directory.compare)))))
(defun directory-swap-rows (a b)
  (append (directory-row-address a :r8) (directory-row-address b :r9)
    (loop for offset from 0 below 40 by 8 append
      `((:load-word :rax :r8 ,offset) (:load-word :rcx :r9 ,offset)
        (:store-word :r8 ,offset :rcx) (:store-word :r9 ,offset :rax)))))
(defun directory-sift-unit ()
  (runtime-unit :directory.sift
    (append (helper-frame 12)
      '((:load-frame :rax 16) (:store-frame -8 :rax) (:load-frame :rax 24) (:store-frame -16 :rax)
        (:load-frame :rax 32) (:store-frame -24 :rax) (:load-frame :rax 40) (:store-frame -32 :rax)
        (:label :loop) (:load-frame :rax -32) (:add-reg :rax :rax) (:add-imm :rax 1)
        (:load-frame :rcx -24) (:cmp) (:jae :done) (:store-frame -40 :rax)
        (:add-imm :rax 1) (:store-frame -48 :rax) (:cmp) (:jae :child))
      (directory-compare-rows -40 -48)
      '((:cmp-imm :rax -1) (:jnz :child) (:load-frame :rax -48) (:store-frame -40 :rax) (:label :child))
      (directory-compare-rows -32 -40)
      '((:cmp-imm :rax -1) (:jnz :done)) (directory-swap-rows -32 -40)
      '((:load-frame :rax -40) (:store-frame -32 :rax) (:jmp :loop) (:label :done)) (helper-return))))
(defun directory-sort-unit ()
  (runtime-unit :directory.sort
    (append (helper-frame 12)
      '((:load-frame :rax 16) (:store-frame -8 :rax) (:load-frame :rax 24) (:store-frame -16 :rax)
        (:load-frame :rax 32) (:store-frame -24 :rax) (:shr-imm :rax 1) (:store-frame -32 :rax)
        (:label :build) (:load-frame :rax -32) (:test) (:jz :extract)
        (:add-imm :rax -1) (:store-frame -32 :rax) (:store-out 24 :rax))
      (directory-sort-call-forms)
      '((:jmp :build) (:label :extract) (:load-frame :rax -24) (:cmp-imm :rax 1) (:jbe :done)
        (:add-imm :rax -1) (:store-frame -24 :rax) (:imm-rax 0) (:store-frame -32 :rax))
      (directory-swap-rows -32 -24)
      '((:imm-rax 0) (:store-out 24 :rax)) (directory-sort-call-forms)
      '((:jmp :extract) (:label :done)) (helper-return))))
(defun directory-sort-call-forms ()
  '((:load-frame :rax -8) (:store-out 0 :rax) (:load-frame :rax -16) (:store-out 8 :rax)
    (:load-frame :rax -24) (:store-out 16 :rax) (:call (:runtime :directory.sift))))

(defun directory-internal-unit ()
  (let* ((message (format nil "mgn: internal error: invalid directory runtime state~%"))
         (bytes (sb-ext:string-to-octets message :external-format :utf-8)))
    (runtime-unit :directory.internal
      (append (helper-frame 12) '((:call (:runtime :io.cleanup-all)))
        (unless (test-image-p)
          (append
            (loop for start from 0 below (length bytes) by 8 append
              `((:imm-rax ,(loop for j below (min 8 (- (length bytes) start)) sum (ash (aref bytes (+ start j)) (* j 8))))
                (:store-frame ,(+ -96 start) :rax)))
            `((:lea-base :rsi :rbp -96) (:imm-rdx ,(length bytes)) (:imm-reg :r8 8)
              (:label :write) (:mov-edi 2) (:mov-eax 1) (:syscall) (:cmp-eintr) (:jnz :written)
              (:add-imm :r8 -1) (:cmp-imm :r8 0) (:jnz :write) (:jmp :exit)
              (:label :written) (:test) (:jle :exit) (:add-reg :rsi :rax) (:sub-reg :rdx :rax)
              (:cmp-imm :rdx 0) (:jnz :write))))
        `((:label :exit) (:mov-edi ,(if (test-image-p) mognitio.testing::+internal-child-status+ 3))
          (:mov-eax 60) (:syscall) (:ud2))))))

(defun directory-runtime-units ()
  (list (directory-map-unit) (directory-errno-unit) (directory-cleanup-unit) (directory-compare-unit) (directory-compare-unit t)
        (directory-sift-unit) (directory-sort-unit) (directory-internal-unit)))
