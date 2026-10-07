(in-package #:mognitio.tests)

(defun v110-index-caller (fault)
  (append (v06-raw-frame)
    (v06-raw-allocate 64) '((:store-frame -32 :rax))
    (v06-raw-allocate 64) (v06-raw-allocate 64)
    '((:call (:runtime :gc.workspace)) (:store-frame -8 :rax))
    (when fault
      (append
        '((:load-word :rdx :rax 8) (:add-reg :rdx :rax)
          (:load-word :rdx :rdx 48))
        (ecase fault
          (:missing '((:imm-rax 0) (:store-byte :rdx 4 :rax)))
          (:interior '((:imm-rax 1) (:store-byte :rdx 5 :rax)))
          (:free '((:imm-rax 1) (:store-byte :rdx 40 :rax))))))
    '((:load-frame :rax -8) (:store-frame -64 :rax)
      (:load-word :rdx :rax 0) (:store-frame -56 :rdx)
      (:lea-base :rsi :rbp -64) (:imm-rdx 16))
    (mapcar (lambda (form) (if (equal form '(:mov-edi 6)) '(:mov-edi 2) form))
      (v110-inline-writes '((:call :snap-write))))
    '((:load-frame :rsi -8) (:load-word :rdx :rsi 0)
      (:label :index-write) (:mov-edi 2) (:mov-eax 1) (:syscall)
      (:test) (:jle :snap-bad) (:add-rsi) (:sub-rdx) (:jnz :index-write)
      (:load-frame :rax -8) (:store-out 0 :rax) (:call (:runtime :gc.release)))
    (v06-raw-finish)
    '((:label :snap-bad) (:mov-edi 97) (:mov-eax 60) (:syscall) (:ud2))))

(deftest v110-independent-membership-index
  (dolist (fault '(nil :missing :interior :free))
    (let ((image (v06-gc-artifact "\"a\"+\"b\"==\"ab\""
                   '(:arena-unit 4096 :cap 4096) (v110-index-caller fault))))
      (multiple-value-bind (out err code)
          (process-result (list "python3" (namestring (root-path "tests/v11-index-check.py"))
                               (namestring image) (if fault "reject" "accept")))
        (same 0 code) (same "" err) (is (search "INDEX_CHECK_OK" out))))))

(deftest v110-workspace-failure-boundaries
  (let ((source "let keep:String=\"a\"+\"b\";let other:String=\"c\"+\"d\";keep==\"ab\"&&other==\"cd\""))
    (v06-expect-native source :true '(:stress t :arena-unit 4096 :cap 4096))
    (multiple-value-bind (out err code)
        (process-result (list (namestring (v06-runtime-artifact source
          '(:stress t :arena-unit 4096 :cap 4096 :gc-workspace-fail t)))))
      (same "" out) (same 4 code)
      (same (format nil "runtime error: allocation failure~%") err)))
  ;; A capacity corrupted after successful acquisition must never overflow.
  (let ((original (fdefinition 'mognitio.native.runtime::runtime-unit)))
    (replacing (mognitio.native.runtime::runtime-unit
      (lambda (name forms &optional (kind :runtime))
        (funcall original name
          (if (eq name :gc.workspace)
              (loop for form in forms append
                (append (list form)
                  (when (equal form '(:label :indexed))
                    '((:load-frame :rax -24) (:imm-rdx 0) (:store-word :rax 8 :rdx)))))
              forms) kind)))
      (multiple-value-bind (out err code)
          (process-result (list (namestring (v06-runtime-artifact
            "let keep:String=\"a\"+\"b\";discard \"c\"+\"d\";keep==\"ab\""
            '(:stress t :arena-unit 4096 :cap 4096)))))
        (same "" out) (same "" err) (same 3 code)))))

(deftest v110-worklist-cycle
  (let* ((forms (v09-chain-forms 32 t))
         (cycle (mapcar (lambda (form)
                   (if (equal form '(:lea-object (:static-object :list (:list :int))))
                       '(:load-frame :rax -8) form)) forms)))
    (v09-check-heap
      (v06-gc-artifact "let a:List<Int>=List<Int>[1];true"
        '(:arena-unit 65536 :cap 65536 :validate t) cycle) "cycle" 32)))

(deftest v110-workspace-maps-released
  (let* ((source "var i:Int=0;loop while(i<128){discard \"a\"+\"b\";i=i+1;};true")
         (image (v06-runtime-artifact source '(:stress t :arena-unit 4096 :cap 4096))))
    (multiple-value-bind (out err code)
        (process-result (list "python3" (namestring (root-path "tests/v11-map-check.py"))
                             (namestring image)))
      (same 0 code) (same "" err) (is (search "WORKSPACE_MAPS_OK" out)))))

(deftest v110-workspace-test-profile-failure
  (let ((manifest (v11-manifest "let keep:String=\"a\"+\"b\";discard \"c\"+\"d\";assert keep==\"ab\";" 1)))
    (let ((mognitio.native.runtime::*test-options* '(:stress t :arena-unit 4096 :cap 4096)))
      (multiple-value-bind (out err code) (v11-driver manifest)
        (same 0 code) (same "" err) (is (search "passed=1" out))))
    (let ((mognitio.native.runtime::*test-options* '(:stress t :arena-unit 4096 :cap 4096 :gc-workspace-fail t)))
      (multiple-value-bind (out err code) (v11-driver manifest)
        (same 4 code) (is (search "errors=1" out))
        (is (search "allocation failure" err))))))

(deftest v110-retry-reloads-free-head
  ;; The old free head is the short tail of a soon-to-be-coalesced arena.
  ;; Reusing that candidate after collection misses the newly reclaimed space.
  (let ((forms (append (v06-raw-allocate 3500) (v06-raw-allocate 1000) '((:imm-rax 1))))
        (options '(:arena-unit 4096 :cap 4096)))
    (multiple-value-bind (out err code) (v06-raw-result forms options)
      (same 0 code) (same (format nil "true~%") out) (same "" err))
    (let ((runtime (fdefinition 'mognitio.native.runtime::runtime-unit)))
      (replacing (mognitio.native.runtime::runtime-unit
        (lambda (name instructions &optional (kind :runtime))
          (funcall runtime name
            (cond
              ((eq name :allocate-block)
               (loop for form in instructions append
                 (append
                   (when (equal form '(:call (:runtime :collect)))
                     '((:load-word :rdx :r15 288) (:store-word :r15 136 :rdx)))
                   (list form))))
              ((eq name :find-free)
               (substitute '(:load-word :r9 :r15 136)
                           '(:load-word :r9 :r11 0) instructions :test #'equal :count 1))
              (t instructions)) kind)))
        (multiple-value-bind (out err code) (v06-raw-result forms options)
          (same 4 code) (same "" out)
          (same (format nil "runtime error: allocation failure~%") err))))))
