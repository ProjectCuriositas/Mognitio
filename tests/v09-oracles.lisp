(in-package #:mognitio.tests)
(defun v09-string-source (text)
  (with-output-to-string (out)
    (write-char #\" out)
    (loop for c across text do (format out "\\u{~X}" (char-code c)))
    (write-char #\" out)))
(deftest v09-independent-sequence-oracles
  (let ((state 9622) (scalars #(0 65 233 769 26085 128512 1114111)))
    (labels ((next (n) (setf state (mod (+ (* state 1664525) 1013904223) 4294967296)) (mod state n)))
      (dotimes (case 48)
        (let* ((items (loop repeat (next 12) collect (- (next 21) 10)))
               (index (- (next (+ 3 (length items))) 1))
               (suffix (- (next 21) 10))
               (expected (append items (list suffix)))
               (source (format nil
                 "let old:List<Int>=List<Int>[~{~D~^,~}];let xs:List<Int>=old->append(~D);var total:Int=0;loop over(xs as n:Int){total=total+n;};old->length()==~D&&total==~D&&(branch on xs->at(~D){Result<Int,IndexError>::Ok(n:Int)=>~A,Result<Int,IndexError>::Err(e:IndexError)=>~A})"
                 items suffix (length items) (reduce #'+ expected) index
                 (if (<= 0 index (1- (length expected))) (format nil "n==~D" (nth index expected)) "false")
                 (if (<= 0 index (1- (length expected))) "false"
                     (format nil "e.index==~D&&e.length==~D" index (length expected))))))
          (handler-case (same :true (compiled-result source)) (compiler-failure (c) (error "Oracle source ~S: ~A" source (diagnostic-message (failure-diagnostic c))))) (v06-expect-native source :true '(:stress t :validate t)))
        (let* ((text (coerce (loop repeat (next 9) collect (code-char (aref scalars (next (length scalars))))) 'string))
               (start (- (next (+ 3 (length text))) 1)) (end (- (next (+ 3 (length text))) 1))
               (valid (<= 0 start end (length text)))
               (source (format nil
                 "let s:String=~A;s->length()==~D&&(branch on s->slice(~D,~D){Result<String,SliceError>::Ok(part:String)=>~A,Result<String,SliceError>::Err(e:SliceError)=>~A})"
                 (v09-string-source text) (length text) start end
                 (if valid (format nil "part==~A" (v09-string-source (subseq text start end))) "false")
                 (if valid "false" (format nil "e.start==~D&&e.end==~D&&e.length==~D" start end (length text))))))
          (handler-case (same :true (compiled-result source)) (compiler-failure (c) (error "Oracle source ~S: ~A" source (diagnostic-message (failure-diagnostic c))))) (v06-expect-native source :true '(:stress t :validate t)))))))

(deftest v09-precommit-preserves-executable
  (let ((source (put-text (fresh-path) "true")) (output (build-text "false")))
    (let ((before (read-bytes output)) (mode (sb-posix:stat-mode (sb-posix:stat output))))
      (dolist (name '(mognitio.artifact::write-image mognitio.artifact::flush-image mognitio.artifact::set-executable
                     mognitio.artifact::close-image mognitio.artifact::verify-image mognitio.artifact::replace-image))
        (let ((old (fdefinition name)))
          (unwind-protect
              (progn (setf (fdefinition name) (lambda (&rest args) (declare (ignore args)) (error 'file-error :pathname output)))
                     (expect-driver (build-args source output) 2))
            (setf (fdefinition name) old)))
        (same before (read-bytes output)) (same mode (sb-posix:stat-mode (sb-posix:stat output)))
        (expect-artifact output :false) (same nil (temporary-images))))))
