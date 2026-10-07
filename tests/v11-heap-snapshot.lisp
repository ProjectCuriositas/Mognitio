(in-package #:mognitio.tests)

(defun v110-head-fault (profile fault)
  (let ((offset (if profile 336 288)))
    (ecase fault
      ((nil) nil)
      (:zero `((:imm-reg :r11 0) (:store-word :r15 ,offset :r11)))
      (:middle `((:load-word :r11 :r15 ,offset) (:load-word :r11 :r11 16)
                 (:store-word :r15 ,offset :r11))))))

(defun v110-inline-writes (forms)
  (let ((serial 0))
    (loop for form in forms append
      (if (equal form '(:call :snap-write))
          (let* ((id (incf serial))
                 (again (intern (format nil "SNAP-WRITE-~D" id) :keyword))
                 (retry (intern (format nil "SNAP-RETRY-~D" id) :keyword))
                 (done (intern (format nil "SNAP-DONE-~D" id) :keyword)))
            `((:imm-reg :r10 16)
              (:label ,again) (:mov-edi 6) (:mov-eax 1) (:syscall)
              (:cmp-eintr) (:jz ,retry) (:test) (:jle :snap-bad)
              (:add-rsi) (:sub-rdx) (:jz ,done)
              (:imm-reg :r10 16) (:jmp ,again)
              (:label ,retry) (:add-imm :r10 -1) (:cmp-imm :r10 0)
              (:jnz ,again) (:jmp :snap-bad) (:label ,done)))
          (list form)))))

(defun v110-snapshot-forms (profile point ordinal fault)
  ;; Terminal observer: only its fixed stack scratch is written. No heap,
  ;; context scratch, allocation, collection, or public I/O helpers are used.
  (v110-inline-writes (append
    (v110-head-fault profile fault)
    (mognitio.native.runtime::helper-frame 24)
    (loop for value in (list #x31534831314e474d 1 7 (if profile 1 0)
                            (if profile 352 304) point ordinal)
          for offset from -72 by 8 append
      `((:imm-rax ,value) (:store-frame ,offset :rax)))
    '((:load-word :r8 :r15 8) (:imm-reg :r9 0) (:imm-reg :r10 0)
      (:label :snap-count) (:cmp-imm :r8 0) (:jz :snap-header)
      (:add-imm :r9 1) (:cmp-imm :r9 64) (:ja :snap-bad)
      (:load-word :rax :r8 8) (:add-reg :r10 :rax) (:jb :snap-bad)
      (:cmp-imm :r10 67108864) (:ja :snap-bad)
      (:load-word :r8 :r8 0) (:jmp :snap-count)
      (:label :snap-header) (:store-frame -16 :r9) (:store-frame -8 :r10)
      (:lea-base :rsi :rbp -72) (:imm-rdx 72) (:call :snap-write)
      (:mov-reg :rsi :r15))
    `((:imm-rdx ,(if profile 352 304)))
    '((:call :snap-write) (:load-word :r8 :r15 8)
      (:label :snap-arena) (:cmp-imm :r8 0) (:jz :snap-exit)
      (:store-frame -112 :r8) (:load-word :rax :r8 8) (:store-frame -104 :rax)
      (:lea-base :rsi :rbp -112) (:imm-rdx 16) (:call :snap-write)
      (:mov-reg :rsi :r8) (:load-word :rdx :r8 8) (:call :snap-write)
      (:load-word :r8 :r8 0) (:jmp :snap-arena)
      (:label :snap-exit) (:mov-edi 0) (:mov-eax 60) (:syscall) (:ud2)
      (:label :snap-bad) (:mov-edi 97) (:mov-eax 60) (:syscall) (:ud2)))))

(defun v110-snapshot-hook (profile point ordinal fault)
  (append
    `((:load-word :r11 :r15 ,(if (= point 2) 48 32)))
    (unless (= point 2) '((:add-imm :r11 1)))
    `((:cmp-imm :r11 ,ordinal) (:jnz :snap-skip))
    (v110-snapshot-forms profile point ordinal fault)
    '((:label :snap-skip))))

(defun v110-instrument-snapshot (name forms profile point ordinal fault)
  (let ((target (ecase point (1 :find-free) (2 :collect) (3 :allocate-block))))
    (if (eq name target)
        (let* ((marker (ecase point
                         (1 '(:ret))
                         (2 '(:mov-reg :rsp :rbp))
                         (3 '(:label :found))))
               (at (position marker forms :test #'equal)))
          (is at "Snapshot capture marker missing")
          (append (subseq forms 0 at) (v110-snapshot-hook profile point ordinal fault)
                  (subseq forms at)))
        forms)))

(defun v110-raw-caller (payload)
  (append (v06-raw-frame)
    (v06-raw-allocate (if (= payload -1) 4032 64))
    (v06-raw-allocate 64) '((:store-frame -32 :rax))
    (v06-raw-allocate 64)
    '((:call (:runtime :collect)))
    (v06-raw-allocate payload)
    (v06-raw-finish)))

(defun v110-snapshot-artifact (profile point ordinal fault payload)
  (let ((original (fdefinition 'mognitio.native.runtime::runtime-unit))
        (layout (fdefinition 'mognitio.object:layout-units)))
    (replacing (mognitio.native.runtime::runtime-unit
                 (lambda (name forms &optional (kind :runtime))
                   (funcall original name
                     (v110-instrument-snapshot name forms profile point ordinal fault) kind)))
      (replacing (mognitio.object:layout-units
                   (lambda (units)
                     (setf (mognitio.object:code-unit-instructions
                             (find 0 units :key #'mognitio.object:code-unit-owner))
                           (apply #'machine (v110-raw-caller payload)))
                     (funcall layout units)))
        (if profile
            (let* ((manifest (v11-manifest "discard \"x\"+\"y\";unit"))
                   (plan (v11-plan manifest))
                   (mognitio.ir::*test-ordinal* 0)
                   (checked (check-program (mognitio.project::project-program
                              (mognitio.testing::test-plan-project plan)
                              (mognitio.testing::test-case-declaration
                                (aref (mognitio.testing::test-plan-cases plan) 0)))))
                   (mognitio.native.runtime::*test-options* '(:arena-unit 4096 :cap 16384))
                   (path (put-bytes (fresh-path ".elf")
                           (mognitio.backend.native:compile-program checked (mognitio.target:linux-amd64)))))
              (sb-posix:chmod (namestring path) #o700) path)
            (v06-runtime-artifact "\"x\"+\"y\"==\"xy\"" '(:arena-unit 4096 :cap 16384)))))))

(deftest v110-free-list-snapshots
  ;; Split, exact fit, a 32-byte allocated block, sweep and a new arena.
  (dolist (profile '(nil t))
    (dolist (case '((1 4 8) (1 4 24) (1 4 32) (1 4 64) (1 4 0) (1 4 80) (1 4 3840) (2 2 8) (3 1 8) (3 1 -1) (3 4 4096)))
      (destructuring-bind (point ordinal payload) case
        (let* ((image (v110-snapshot-artifact profile point ordinal nil payload))
               (zero (when (and (= point 1) (= payload 8))
                       (v110-snapshot-artifact profile point ordinal :zero payload)))
               (middle (when zero (v110-snapshot-artifact profile point ordinal :middle payload))))
          (multiple-value-bind (out err code)
              (process-result
                (append (list "python3" (namestring (root-path "tests/v11-heap-run.py"))
                              (namestring image) (if profile "1" "0")
                              (princ-to-string point) (princ-to-string ordinal))
                        (when zero (list (namestring zero) (namestring middle)))) :timeout 60)
            (same 0 code) (same "" err) (is (search "HEAP_SNAPSHOT_OK" out)))))))
  (dolist (profile '(nil t))
    (dolist (fault '(:zero :middle))
      (let ((forms (v110-head-fault profile fault)))
        (same 1 (count :store-word forms :key #'first))
        (is (every (lambda (form) (member (first form) '(:load-word :imm-reg :store-word))) forms))
        (same (list :store-word :r15 (if profile 336 288) :r11) (car (last forms)))))))
