(in-package #:mognitio.native.runtime)

;; Test-only extension of the runtime context: stage, sequence, kind, site, exit.
;; All helpers are nonallocating. Returning helpers preserve the native callee saves.
(defun test-image-p () (and *runtime-module* (mognitio.ir::module-test-ordinal *runtime-module*)))
(defun event-header (tag)
  (+ #x544e474d (ash mognitio.testing::+protocol-version+ 32) (ash (mognitio.testing::event-number mognitio.testing::*event-tags* tag) 48)))
(defun event-call (tag kind &optional (site -1))
  `((:imm-rax ,(event-header tag)) (:imm-rcx ,kind) (:imm-rdx ,site) (:call (:helper :test.event))))

(defun test-context-unit (name forms &optional (kind :runtime))
  (runtime-unit name
    (mapcar (lambda (form)
      (let ((copy (copy-list form)))
        (cond ((and (eq (first copy) :store-word) (eq (second copy) :r15))
               (setf (third copy) (context-field-offset
                 (ecase (third copy) (288 :test-stage) (296 :test-sequence) (304 :test-kind) (312 :test-site) (320 :test-exit)) t)))
              ((and (eq (first copy) :load-word) (eq (third copy) :r15))
               (setf (fourth copy) (context-field-offset
                 (ecase (fourth copy) (288 :test-stage) (296 :test-sequence) (304 :test-kind) (312 :test-site) (320 :test-exit)) t)))) copy)) forms) kind))

(defun test-helper-units ()
  (when (test-image-p)
    (list
     (test-context-unit :test.event
       (append (helper-frame 8)
         ;; RAX=header, RCX=kind, RDX=site; five aligned words form the wire record.
         `((:store-frame -40 :rax) (:store-frame -8 :rdx)
           (:imm-rax ,(test-image-p)) (:store-frame -32 :rax)
           (:load-word :rax :r15 296) (:store-frame -24 :rax)
           (:add-imm :rax 1) (:store-word :r15 296 :rax)
           (:imm-rax 4294967296) (:mul) (:load-word :rcx :r15 288) (:add-reg :rax :rcx)
           (:store-frame -16 :rax) (:lea-base :rsi :rbp -40) (:store-frame -48 :rsi)
           (:imm-rax 40) (:store-frame -56 :rax) (:imm-rax 16) (:store-frame -64 :rax)
           (:label :write) (:load-frame :rsi -48) (:load-frame :rdx -56)
           (:mov-edi 3) (:mov-eax 1) (:syscall) (:cmp-eintr) (:jz :retry)
           (:test) (:jle :transport) (:load-frame :rsi -48) (:add-rsi) (:store-frame -48 :rsi)
           (:load-frame :rdx -56) (:sub-rdx) (:store-frame -56 :rdx)
           (:jz :done) (:imm-rax 16) (:store-frame -64 :rax) (:jmp :write)
           (:label :retry) (:load-frame :rax -64) (:add-imm :rax -1) (:store-frame -64 :rax)
           (:test) (:jnz :write) (:label :transport) (:mov-edi 124) (:mov-eax 60) (:syscall) (:ud2)
           (:label :done) (:imm-rax 0)) (helper-return)) :helper)
     (test-context-unit :test.bootstrap
       (append (helper-frame 6)
         ;; Ignore SIGPIPE so the private transport status reports EPIPE.
         '((:imm-rax 1) (:store-frame -48 :rax) (:lea-base :rsi :rbp -48)
           (:mov-edi 13) (:imm-rdx 0) (:mov-r10d 8) (:mov-eax 13) (:syscall)
           (:test) (:jl :transport))
         (event-call :ready 0)
         '((:imm-rax 16) (:store-frame -16 :rax)
           (:label :gate) (:mov-edi 4) (:lea-base :rsi :rbp -8) (:mov-edx 1)
           (:mov-eax 0) (:syscall) (:cmp-eintr) (:jz :retry)
           (:cmp-imm :rax 1) (:jnz :transport)
           (:load-byte :rax :rbp -8) (:cmp-imm :rax 1) (:jnz :transport)
           (:mov-edi 4) (:mov-eax 3) (:syscall) (:test) (:jl :transport)
           (:imm-rax 1) (:store-word :r15 288 :rax))
         (event-call :stage 0) (helper-return)
         '((:label :retry) (:load-frame :rax -16) (:add-imm :rax -1) (:store-frame -16 :rax)
           (:test) (:jnz :gate) (:label :transport) (:mov-edi 124) (:mov-eax 60) (:syscall) (:ud2))) :helper)
     (test-context-unit :test.stage
       (append (helper-frame 0) '((:imm-rax 2) (:store-word :r15 288 :rax))
               (event-call :stage 0) (helper-return)) :helper)
     (test-context-unit :test.terminal
       (append (helper-frame 0)
         `((:store-word :r15 320 :rdi) (:imm-rax ,(event-header :terminal))
           (:load-word :rcx :r15 304) (:load-word :rdx :r15 312) (:call (:helper :test.event))
           (:load-word :rdi :r15 320) (:mov-eax 60) (:syscall) (:ud2))) :helper))))

(defun test-runtime-forms ()
  (append
   '((:label :print) (:imm-rax 0) (:store-word :r15 304 :rax)
     (:imm-rax -1) (:store-word :r15 312 :rax) (:mov-edi 0) (:jmp (:helper :test.terminal)))
   (loop for (kind . number) in mognitio.testing::*event-kinds* when (>= number 3) append
     `((:label ,kind)
       ,@(when (io-image-p) '((:call (:runtime :io.cleanup-all))))
       (:imm-rax ,number) (:store-word :r15 304 :rax)
       (:imm-rax -1) (:store-word :r15 312 :rax)
       (:lea-rsi (:data ,kind)) (:mov-edx ,(length (mognitio.runtime:failure-octets kind)))
       (:mov-r8d 4) (:jmp :write-setup)))
   '((:label :write-setup) (:mov-r10d 16)
     (:label :write-loop) (:mov-edi 5) (:mov-eax 1) (:syscall) (:cmp-eintr) (:jz :interrupted)
     (:test) (:jle :transport) (:add-rsi) (:sub-rdx) (:jz :done) (:mov-r10d 16) (:jmp :write-loop)
     (:label :interrupted) (:dec-r10d) (:jnz :write-loop)
     (:label :transport) (:mov-edi 124) (:mov-eax 60) (:syscall) (:ud2)
     (:label :done) (:mov-edi-r8d) (:jmp (:helper :test.terminal)))
   (loop for (kind . number) in mognitio.testing::*event-kinds* when (>= number 3) append
     (list (list :label (list :data kind)) (cons :bytes (coerce (mognitio.runtime:failure-octets kind) 'list))))))
