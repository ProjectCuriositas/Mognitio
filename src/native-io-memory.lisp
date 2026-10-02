(in-package #:mognitio.native.runtime)

;; One record owns fd, current/old staging maps and NUL-terminated path storage.
;; Its previous link is published before the first acquisition. No field is a
;; managed heap reference; the helper has a separate ordinary root frame.
(defconstant +io-record-offset+ -128)
(defun io-image-p ()
  (and *runtime-module*
       (some (lambda (function)
               (some (lambda (block) (find :io.call (mognitio.ir:basic-block-instructions block) :key #'mognitio.ir:instruction-op))
                     (mognitio.ir:ir-function-blocks function))) (mognitio.ir:module-functions *runtime-module*))))

(defun io-signal-unit ()
  (runtime-unit :io.signals
    (append (helper-frame 4)
      (loop for signal in '(13 25) append
        `((:imm-rax 1) (:store-frame -32 :rax) (:lea-base :rsi :rbp -32)
          (:mov-edi ,signal) (:imm-rdx 0) (:mov-r10d 8) (:mov-eax 13) (:syscall)
          (:test) (:jl :failed)))
      (helper-return)
      `((:label :failed) (:mov-edi ,(if (test-image-p) 124 3)) (:mov-eax 60) (:syscall) (:ud2)))))

(defun io-map-unit ()
  (runtime-unit :io.map
    '((:load-word :rsi :rsp 8) (:imm-reg :rdi 0) (:imm-rdx 3)
      (:imm-reg :r10 34) (:imm-reg :r8 -1) (:imm-reg :r9 0)
      (:mov-eax 9) (:syscall) (:cmp-imm :rax -4095) (:jae :allocation-failed) (:ret))))

(defun io-close-unit ()
  (runtime-unit :io.close
    '((:load-word :rdx :rsp 8) (:load-word :rdi :rdx 8)
      (:cmp-imm :rdi 0) (:jl :absent)
      ;; Linux close is attempted once; EINTR does not retain ownership.
      (:imm-rax -1) (:store-word :rdx 8 :rax) (:mov-eax 3) (:syscall) (:ret)
      (:label :absent) (:imm-rax 0) (:ret))))

(defun io-cleanup-unit ()
  (runtime-unit :io.cleanup
    (append (helper-frame 6)
      '((:load-frame :rax 16) (:store-frame -8 :rax) (:store-out 0 :rax)
        (:call (:runtime :io.close)) (:store-frame -16 :rax))
      (loop for pair in '((16 24) (32 40) (48 56)) for index from 0 append
        (let ((next (intern (format nil "CLEANUP-NEXT-~D" index) :keyword)))
          `((:load-frame :rdx -8) (:load-word :rdi :rdx ,(first pair))
            (:cmp-imm :rdi 0) (:jz ,next) (:load-word :rsi :rdx ,(second pair))
            (:imm-rax 0) (:store-word :rdx ,(first pair) :rax)
            (:cmp-imm :rsi 0) (:jle ,(intern (format nil "CLEANUP-BAD-~D" index) :keyword))
            (:mov-reg :rax :rdi) (:and-imm :rax 4095) (:test) (:jnz ,(intern (format nil "CLEANUP-BAD-~D" index) :keyword))
            (:cmp-imm :rdi 0) (:jl ,(intern (format nil "CLEANUP-BAD-~D" index) :keyword))
            (:mov-eax 11) (:syscall)
            ,@(when (option :directory-cleanup-fault) `((:imm-rax ,(option :directory-cleanup-fault))))
            (:test) (:jz ,next)
            (:jmp ,(intern (format nil "CLEANUP-ERROR-~D" index) :keyword))
            (:label ,(intern (format nil "CLEANUP-BAD-~D" index) :keyword)) (:imm-rax -22)
            (:label ,(intern (format nil "CLEANUP-ERROR-~D" index) :keyword))
            (:load-frame :rcx -16) (:test-rcx) (:jnz ,next) (:store-frame -16 :rax)
            (:label ,next))))
      '((:load-frame :rax -16)) (helper-return))))

(defun io-cleanup-all-unit ()
  (runtime-unit :io.cleanup-all
    (append (helper-frame 2)
      `((:label :next) (:load-word :rax :r15 ,+cleanup-head+) (:test) (:jz :done)
        ;; A primary language failure must not follow a malformed/cyclic chain.
        ;; Records are aligned stack objects ordered toward the initial stack.
        (:mov-reg :rdx :rax) (:and-imm :rdx 7) (:cmp-imm :rdx 0) (:jnz :corrupt)
        (:cmp-reg :rax :rbp) (:jbe :corrupt) (:load-word :r8 :r15 ,+initial-stack+)
        (:add-imm :r8 -64) (:cmp-reg :rax :r8) (:ja :corrupt)
        (:load-word :rcx :rax 0) (:test-rcx) (:jz :pop)
        (:cmp-reg :rcx :rax) (:jbe :corrupt) (:cmp-reg :rcx :r8) (:ja :corrupt)
        (:label :pop) (:store-word :r15 ,+cleanup-head+ :rcx)
        (:store-out 0 :rax) (:call (:runtime :io.cleanup)) (:jmp :next)
        (:label :corrupt) (:imm-rax 0) (:store-word :r15 ,+cleanup-head+ :rax) (:label :done))
      (helper-return))))

(defun io-errno-unit ()
  (runtime-unit :io.errno
    (append
      ;; Input RAX is a negative Linux errno, output RAX is IoErrorKind ordinal.
      (loop for (kind . numbers) in '((2 2 20) (3 13 1 30) (4 21) (5 32) (6 24 23 28 122 12)) append
        (loop for number in numbers append `((:cmp-imm :rax ,(- number)) (:jz ,(intern (format nil "KIND-~D" kind) :keyword)))))
      '((:imm-rax 7) (:ret))
      (loop for kind in '(2 3 4 5 6) append
        `((:label ,(intern (format nil "KIND-~D" kind) :keyword)) (:imm-rax ,kind) (:ret))))))

(defun io-runtime-units ()
  (append (list (io-signal-unit))
          (when (io-image-p)
            (append (unless (argument-image-p) (list (utf8-feed-unit) (utf8-count-unit)))
                    (list (io-map-unit) (io-close-unit) (io-cleanup-unit) (io-cleanup-all-unit) (io-errno-unit))
                    (directory-runtime-units)))))
