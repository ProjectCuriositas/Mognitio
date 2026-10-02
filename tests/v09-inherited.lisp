(in-package #:mognitio.tests)

(deftest v06-native-encoding-and-literals
  (same :mognitio-internal-v6 (mognitio.target:target-abi (mognitio.target:linux-amd64)))
  (dolist (pair '(((:load-word :rax :r15 0) "498b8700000000")
                  ((:store-word :r15 0 :rax) "49898700000000")
                  ((:lea-base :rax :rbp -40) "488d85d8ffffff")
                  ((:load-byte :r9 :r12 1) "450fb68c2401000000")
                  ((:store-byte :r13 2 :rdi) "4188bd02000000")
                  ((:add-imm :rdx 8) "4881c208000000")
                  ((:cmp-imm :rax 6) "4881f806000000")))
    (same (hex-bytes (second pair)) (mognitio.amd64:encode (machine (first pair)))))
  (same #(1 0 0 0 0 0 0 0 2) (mognitio.amd64:encode (machine '(:bytes 1) '(:align 8) '(:bytes 2))))
  (let* ((module (native-ir "let a: String=\"A\\0日\"; true"))
         (code (mognitio.machine:lower-module module)))
    (multiple-value-bind (bytes labels) (mognitio.amd64:encode code)
      (dolist (id '(0 1))
        (let ((offset (mognitio.object:image-symbol-offset (gethash (list :text id) labels))))
          (same 0 (mod offset 8))
          (same (if (zerop id) 32 40) (image-integer bytes offset 8))
          (same 5 (image-integer bytes (+ offset 8) 8))
          (same (if (zerop id) 0 5) (image-integer bytes (+ offset 16) 8))
          (same (if (zerop id) 0 3) (image-integer bytes (+ offset 24) 8))
          (when (= id 1) (same #(65 0 230 151 165 0 0 0) (subseq bytes (+ offset 32) (+ offset 40))))))
      (same bytes (mognitio.amd64:encode (mognitio.machine:lower-module (native-ir "let a: String=\"A\\0日\"; true"))))))
  (dolist (forms '(((:lea-text (:function 1)) (:label (:function 1)) (:ret))
                  ((:call (:text 0)) (:label (:text 0)) (:bytes 0))
                  ((:jb (:text 0)) (:label (:text 0)) (:bytes 0))
                  ((:align 3)) ((:load-word :rax :r16 0)) ((:load-byte :rax :r15 2147483648))))
    (signals internal-failure (mognitio.amd64:encode (apply #'machine forms)))))


(defun v06-frame-capture (source)
  (let ((original (fdefinition 'mognitio.frame:verify-sections)) (capture nil))
    (replacing (mognitio.frame:verify-sections
                 (lambda (&rest arguments) (push arguments capture) (apply original arguments)))
      (mognitio.machine:lower-module (native-ir source)))
    (reverse capture)))


(deftest v06-native-frame-verifier-negatives
  (let ((source "let f:Function(String):String=function(s:String):String{s}; let x: String=f(\"x\"); let y: String=f(x); true"))
    (dolist (mutation '(:reserve-size :missing-root :wrong-home :before-call :no-clear :no-unlink :clobber-result :overlap :missing-site :extra-call))
      (destructuring-bind (function allocation roots layout sections body) (first (v06-frame-capture source))
        (let* ((publication (find :publish sections :key #'first))
               (unlink (find :unlink sections :key #'first)))
          (flet ((replace-section (section forms)
                   (setf (third section) forms)
                   (replace body forms :start1 (fourth section))))
            (ecase mutation
              (:reserve-size (let* ((section (find :reserve sections :key #'first)) (forms (copy-tree (third section))))
                               (setf (second (first forms)) 1) (replace-section section forms)))
              (:missing-root (replace-section publication (append (subseq (third publication) 0 2) '((:imm-rax 0) (:store-frame -32 :rax)))))
              (:wrong-home (let ((forms (copy-tree (third publication))))
                             (setf (third forms) '(:mov-reg :rax :r11)) (replace-section publication forms)))
              (:before-call (let ((forms (copy-tree (third publication))))
                              (setf (first forms) '(:call (:function 1))) (replace-section publication forms)))
              (:no-clear (let ((forms (copy-tree (third publication))))
                           (setf (first forms) '(:imm-rax 99)) (replace-section publication forms)))
              (:no-unlink (setf sections (remove unlink sections)))
              (:clobber-result (replace-section unlink (list (list :load-frame :rax (mognitio.frame:layout-root-offset layout)) '(:store-word :r15 0 :rax))))
              (:overlap (setf (mognitio.frame:layout-root-offset layout) (mognitio.frame:layout-temporary layout)))
              (:missing-site (setf sections (remove publication sections)))
              (:extra-call (setf (first body) '(:call (:function 1))))))
          (signals internal-failure (mognitio.frame:verify-sections function allocation roots layout sections body)))))))


(deftest v06-native-frame-unsectioned-context-writes
  (dolist (op '(:load-frame :store-byte))
    (destructuring-bind (function allocation roots layout sections body)
        (first (v06-frame-capture "true"))
      (let ((index (position '(:imm-rax 1) body :test #'equal)))
        (is index)
        (is (notany (lambda (section)
                      (<= (fourth section) index
                          (1- (+ (fourth section) (length (third section)))))) sections))
        (setf (nth index body)
              (if (eq op :load-frame)
                  (list :load-frame :r15 (mognitio.frame:layout-temporary layout))
                  '(:store-byte :r15 0 :rax)))
        (signals internal-failure
          (mognitio.frame:verify-sections function allocation roots layout sections body))))))


(deftest v06-native-frame-runtime-register-writers
  (dolist (form '((:imm-reg :r15 0) (:add-reg :r15 :rax) (:sub-reg :r15 :rax)
                  (:and-imm :r15 0) (:or-imm :r15 1) (:shr-imm :r15 1)))
    (destructuring-bind (function allocation roots layout sections body) (first (v06-frame-capture "true"))
      (setf (nth (position '(:imm-rax 1) body :test #'equal) body) form)
      (signals internal-failure (mognitio.frame:verify-sections function allocation roots layout sections body)))))

(deftest v05-independent-dominance
  ;; Removing a proposed dominator must disconnect the use block from entry.
  ;; This reachability oracle does not use the verifier's dominator equations.
  (labels ((reachable-without (function target removed)
             (let ((pending (list (mognitio.ir:ir-function-entry function))) (seen nil))
               (loop while pending for id = (pop pending) do
                 (unless (or (= id removed) (member id seen))
                   (when (= id target) (return-from reachable-without t))
                   (push id seen)
                   (let* ((block (find id (mognitio.ir:ir-function-blocks function) :key #'mognitio.ir:basic-block-id))
                          (term (mognitio.ir:basic-block-terminator block)))
                     (case (first term)
                       (:jump (push (second term) pending))
                       (:branch (push (third term) pending) (push (fourth term) pending))))))
               nil)))
    (let* ((baseline (v05-loop-module)) (function (first (mognitio.ir:module-functions baseline))) (defs nil))
      (dolist (block (mognitio.ir:ir-function-blocks function))
        (dolist (p (mognitio.ir:basic-block-parameters block)) (push (cons (car p) (mognitio.ir:basic-block-id block)) defs))
        (dolist (i (mognitio.ir:basic-block-instructions block)) (push (cons (mognitio.ir:instruction-result i) (mognitio.ir:basic-block-id block)) defs)))
      (dolist (definition defs)
        (dolist (target (mognitio.ir:ir-function-blocks function))
          (let* ((id (mognitio.ir:basic-block-id target))
                 (dominates (not (reachable-without function id (cdr definition))))
                 (module (v05-loop-module))
                 (block (find id (entry-blocks module) :key #'mognitio.ir:basic-block-id)))
            (setf (mognitio.ir:basic-block-instructions block)
                  (append (mognitio.ir:basic-block-instructions block)
                          (list (mognitio.ir:make-instruction :result 100 :type :bool :op :eq :operands (list (car definition) (car definition))))))
            (if dominates (is (mognitio.ir:verify-module module))
                (signals internal-failure (mognitio.ir:verify-module module)))))))))


(defun v05-cross-abi (source owner handwritten &optional mutate)
  ;; Replace one unit only, after production lowering has generated both sides.
  ;; The opposite side retains production allocation, frame and call lowering.
  (let ((layout (fdefinition 'mognitio.object:layout-units)) (seen nil) code)
    (replacing (mognitio.object:layout-units
                 (lambda (units)
                   (dolist (unit units)
                     (let ((id (mognitio.object:code-unit-owner unit)))
                       (cond
                         ((eql id owner)
                          (is (not seen)) (setf seen t)
                          (setf (mognitio.object:code-unit-instructions unit)
                                (apply #'machine handwritten)))
                         ((and mutate (eql id (- 1 owner)))
                          (setf (mognitio.object:code-unit-instructions unit)
                                (apply #'machine
                                  (funcall mutate
                                    (mapcar (lambda (i)
                                              (cons (mognitio.machine:instruction-opcode i)
                                                    (copy-list (mognitio.machine:instruction-operands i))))
                                            (mognitio.object:code-unit-instructions unit)))))))))
                   (funcall layout units)))
      (setf code (mognitio.machine:lower-module (native-ir source))))
    (is seen)
    (let ((path (put-bytes (fresh-path ".elf")
                  (mognitio.elf:make-image (mognitio.amd64:encode code)))))
      (sb-posix:chmod (namestring path) #o700)
      (process-result (list (namestring path))))))


(defun v06-native-ir (source)
  (handler-case (native-ir source)
    (compiler-failure (c)
      (error "Core fixture ~S: ~A" source (diagnostic-message (failure-diagnostic c))))))


(defun v06-core-instructions (module)
  (loop for function in (mognitio.ir:module-functions module) append
    (loop for b in (mognitio.ir:ir-function-blocks function) append (mognitio.ir:basic-block-instructions b))))

(defun v06-core-op (module op)
  (find op (v06-core-instructions module) :key #'mognitio.ir:instruction-op))

(defun v06-core-snapshot (module)
  (list (loop for p across (mognitio.ir:module-literal-pool module)
              collect (list (text-payload-octets p) (text-payload-scalar-count p)))
        (loop for f in (mognitio.ir:module-functions module) collect
          (loop for b in (mognitio.ir:ir-function-blocks f) collect
            (list (mognitio.ir:basic-block-id b) (mognitio.ir:basic-block-parameters b)
                  (loop for i in (mognitio.ir:basic-block-instructions b) collect
                    (list (mognitio.ir:instruction-result i) (mognitio.ir:instruction-type i)
                          (mognitio.ir:instruction-op i) (mognitio.ir:instruction-value i)
                          (mognitio.ir:instruction-operands i) (mognitio.ir:instruction-effects i)))
                  (mognitio.ir:basic-block-terminator b))))))


(defun v06-i (id type op &rest args)
  (apply #'mognitio.ir:make-instruction :result id :type type :op op args))

(defun v06-test-pool ()
  (vector (make-text-payload :octets (hex-bytes "") :scalar-count 0)
          (make-text-payload :octets (hex-bytes "61") :scalar-count 1)))

(defun v06-root-snapshot (plans)
  (loop for plan in plans collect
    (list (mognitio.roots:root-plan-function-id plan) (mognitio.roots:root-plan-capacity plan)
          (loop for s in (mognitio.roots:root-plan-sites plan) collect
            (list (mognitio.roots:root-site-block-id s) (mognitio.roots:root-site-instruction-index s)
                  (mognitio.roots:root-site-values s))))))


(defun v06-root-loop-fixture (&optional endless)
  (let* ((entry (mognitio.ir:make-basic-block :id 0 :instructions
                  (list (v06-i 0 :string :const.text :value 1)
                        (v06-i 1 :string :const.text :value 1)
                        (v06-i 2 :string :const.text :value 1)
                        (v06-i 3 :int :constant :value 0)
                        (v06-i 4 :bool :constant :value 1)
                        (v06-i 11 :string :text.concat :operands '(1 1)))
                  :terminator '(:jump 1 (0 2))))
         (header (mognitio.ir:make-basic-block :id 1 :parameters '((5 . :string) (6 . :string))
                   :instructions (list (v06-i 7 :string :text.concat :operands '(5 1))) :terminator '(:jump 2 (7))))
         (join (mognitio.ir:make-basic-block :id 2 :parameters '((8 . :string))
                 :instructions (list (v06-i 9 :string :text.slice :operands '(8 3 3))
                                     (v06-i 10 :bool :text.equal :operands '(8 1)))
                 :terminator (if endless '(:jump 3 ()) '(:branch 4 3 4))))
         (back (mognitio.ir:make-basic-block :id 3 :terminator '(:jump 1 (8 6))))
         (exit (mognitio.ir:make-basic-block :id 4 :terminator '(:return 10))))
    (mognitio.ir:make-module :literal-pool (v06-test-pool) :functions
      (list (mognitio.ir:make-ir-function :id 0 :entry 0 :result-type :bool
              :blocks (append (list entry header join back) (unless endless (list exit))))))))


(deftest v06-root-edge-substitution-and-scc
  (dolist (endless '(nil t))
    (let* ((module (v06-root-loop-fixture endless)) (f (first (mognitio.ir:module-functions module)))
           (expected '((0 2 ((0 5 (0 1)) (1 0 (1 5)) (2 0 (1 8)))))))
      (same expected (v06-root-snapshot (mognitio.roots:analyze-roots module)))
      ;; Physical layout and DFS order are not semantic root evidence.
      (setf (mognitio.ir:ir-function-blocks f) (reverse (mognitio.ir:ir-function-blocks f)))
      (same expected (v06-root-snapshot (mognitio.roots:analyze-roots module)))
      (is (mognitio.regalloc:allocate-function f)))))
