(require :asdf)
(asdf:load-asd (truename "mognitio.asd"))
(asdf:load-system "mognitio/tests")
(in-package #:mognitio.tests)

;; Bounded whole-artifact observation, separate from the structural counters.
;; Includes process startup; source generation and compilation are outside time.
(defun v14-measured-image (body options)
  (let ((original (fdefinition 'mognitio.object:layout-units)))
    (replacing (mognitio.object:layout-units
                 (lambda (units)
                   (let ((entry (first units)))
                     (setf (mognitio.object:code-unit-instructions entry)
                       (loop for inst in (mognitio.object:code-unit-instructions entry) append
                         (if (and (eq (mognitio.machine:instruction-opcode inst) :jmp)
                                  (equal (mognitio.machine:instruction-operands inst) '(:print)))
                             (append (machine '(:store-word :r15 24 :rax) '(:mov-reg :rsi :r15)
                                              '(:mov-edx 200) '(:mov-edi 2) '(:mov-eax 1) '(:syscall)
                                              '(:load-word :rax :r15 24)) (list inst))
                             (list inst)))))
                   (funcall original units)))
      (v12-native (v13-manifest body) options))))

(deftest v014-resource-observation
(dolist (n '(64 128 256))
  (dolist (small '(nil t))
    (let* ((text (make-string n :initial-element #\日))
           (body (format nil "var i:Int=0;loop while(i<10){assert ~S->scalars()->join(\"\")==~S;i=i+1;};0" text text))
           (image (v14-measured-image body (if small '(:arena-unit 4096 :cap 65536 :validate t) nil)))
           (start (get-internal-real-time)))
      (multiple-value-bind (out bytes code) (process-result (list (namestring image)) :binary-error t)
        (assert (and (= code 0) (equal out "") (= (length bytes) 200)))
        (flet ((word (offset) (loop for i below 8 sum (ash (aref bytes (+ offset i)) (* i 8)))))
          (format t "TEXT_MEASURE n=~D heap=~A allocations=~D allocated_bytes=~D gc=~D mapped_bytes=~D gc_peak_live_bytes=~D elapsed_ms=~,3F~%"
                  n (if small "small" "normal") (word 32) (word 40) (word 48) (word 72) (word 184)
                  (* 1000.0 (/ (- (get-internal-real-time) start) internal-time-units-per-second))))))))
)
(let ((*tests* '(v014-resource-observation))) (run-tests))
