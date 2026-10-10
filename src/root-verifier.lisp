(in-package #:mognitio.roots)

(defun verify-function-roots (function plan)
  ;; This checker solves an instruction graph directly. It neither calls the
  ;; block-summary producer nor reads any of its use/def or liveness tables.
  ;; Safepoints are reconstructed from operations, not supplied annotations.
  (let ((nodes (make-hash-table :test #'equal)) (before (make-hash-table :test #'equal))
        (blocks (make-hash-table)) (types (make-hash-table)) (keys nil))
    (dolist (b (ir-function-blocks function))
      (setf (gethash (basic-block-id b) blocks) b)
      (dolist (p (basic-block-parameters b)) (setf (gethash (car p) types) (cdr p)))
      (loop for i in (basic-block-instructions b) for index from 0
            for key = (list (basic-block-id b) index) do
        (setf (gethash key nodes) i (gethash (instruction-result i) types) (instruction-type i))
        (push key keys))
      (let ((key (list (basic-block-id b) (length (basic-block-instructions b)))))
        (setf (gethash key nodes) (basic-block-terminator b)) (push key keys)))
    (loop with changed = t while changed do
      (setf changed nil)
      (dolist (key keys)
        (let* ((node (gethash key nodes))
               (in
                 (if (typep node 'instruction)
                     (reduce (lambda (live value) (adjoin value live)) (instruction-operands node)
                             :initial-value (remove (instruction-result node)
                                                    (gethash (list (first key) (1+ (second key))) before)))
                     (ecase (first node)
                       ((:trap :assert-fail) nil) ((:return :panic) (list (second node)))
                       (:branch (adjoin (second node)
                                        (union (gethash (list (third node) 0) before)
                                               (gethash (list (fourth node) 0) before))))
                       (:jump
                        (let ((params (basic-block-parameters (gethash (second node) blocks))) (live nil))
                          (dolist (value (gethash (list (second node) 0) before))
                            (let ((position (position value params :key #'car)))
                              (pushnew (if position (nth position (third node)) value) live)))
                          live))))))
          (unless (and (subsetp in (gethash key before)) (subsetp (gethash key before) in))
            (setf (gethash key before) in changed t)))))
    (let ((remaining (copy-list (root-plan-sites plan))) (capacity 0))
      (dolist (b (sort (copy-list (ir-function-blocks function)) #'< :key #'basic-block-id))
        (loop for inst in (basic-block-instructions b) for index from 0 do
          (when (member (instruction-op inst) '(:bytes.from-ints :bytes.from-bits :bytes.at :bytes.append :bytes.concat :bytes.slice :bytes.to-bits :bits.to-bytes :integer.convert :bits.left :bits.right :bits.at :io.call :call :call.value :text.concat :text.slice :struct.make :enum.make :interface.pack :call.interface :closure.make :closure.call :list.append :list.at :list.buffer :text.scalars :text.join :text.slice.result))
            (let* ((site (pop remaining))
                   (expected (sort (loop for value in (gethash (list (basic-block-id b) index) before)
                                         when (mognitio.semantic:reference-type-p (gethash value types)) collect value) #'<)))
              (unless (and (root-site-p site) (eql (root-site-block-id site) (basic-block-id b))
                           (eql (root-site-instruction-index site) index)
                           (equal (root-site-values site) expected))
                (internal-error "Incorrect safepoint root slots"))
              (setf capacity (max capacity (length expected)))))))
      (unless (and (null remaining) (eql capacity (root-plan-capacity plan)))
        (internal-error "Incorrect root frame capacity or extra safepoints"))))
  plan)

(defun verify-roots (module plans)
  (handler-case
      (progn
        (verify-module module)
        (let ((functions (sort (copy-list (module-functions module)) #'< :key #'ir-function-id)))
          (unless (= (length functions) (length plans)) (internal-error "Incorrect root plan count"))
          (loop for function in functions for plan in plans do
            (unless (and (root-plan-p plan) (eql (root-plan-function-id plan) (ir-function-id function)))
              (internal-error "Incorrect root plan owner"))
            (verify-function-roots function plan)))
        plans)
    (internal-failure (c) (error c))
    (error () (internal-error "Malformed root plan"))))
