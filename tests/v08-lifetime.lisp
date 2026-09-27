(in-package #:mognitio.tests)

(defparameter *v08-gc-source*
  "type Box<T> =struct{value:T;};let discarded:Box<string> =Box<string>{value:\"trash\"+\"!\"};let make:function():Result<int,Box<string>> =function():Result<int,Box<string>>{Result<int,Box<string>>::Err(Box<string>{value:\"keep\"+\"!\"})};let f:function():Result<bool,Box<string>> =function():Result<bool,Box<string>>{let n:int=try make();Result<bool,Box<string>>::Ok(n==42)};let payload:Box<string> =branch on(f()){Result<bool,Box<string>>::Ok(ignoredPayload1)=>Box<string>{value:\"bad\"},Result<bool,Box<string>>::Err(e)=>e};var i:int=0;loop while(i<2000){let dead:Box<string> =Box<string>{value:\"dead\"+\"!\"};i=i+1;};payload->value==\"keep!\"")

(deftest v08-generic-heap-reclamation
  (dolist (stress '(nil t))
    (multiple-value-bind (out err status)
        (process-result (list "python3" (namestring (root-path "tests/v08-heap-check.py"))
                              (namestring (v06-gc-artifact *v08-gc-source*
                                (list :arena-unit 4096 :cap 4096 :trace t :validate t :stress stress)))))
      (is (= 0 status) err) (same "" err) (is (search "GENERIC_GC_OK" out)) (format t "~A" out)))
  (dolist (mutation '(:no-sweep :no-trace))
    (multiple-value-bind (out err status)
        (process-result (list (namestring (v06-runtime-artifact *v08-gc-source*
                              (list :arena-unit 4096 :cap 4096 :validate t :mutation mutation)))))
      (declare (ignore err))
      (is (or (/= status 0) (not (string= out (format nil "true~%")))))))
  (let* ((needle "let payload:Box<string> =branch on(f())")
         (position (search needle *v08-gc-source*))
         (source (concatenate 'string (subseq *v08-gc-source* 0 position)
                   "let parent:Result<bool,Box<string>> =f();let payload:Box<string> =branch on(parent)"
                   (subseq *v08-gc-source* (+ position (length needle)))))
         (tail (search "payload->value==\"keep!\"" source)))
    (setf source (concatenate 'string (subseq source 0 tail)
                  "branch on(parent){Result<bool,Box<string>>::Ok(ignoredPayload2)=>false,Result<bool,Box<string>>::Err(e)=>branch when{e->value==\"keep!\"=>payload->value==\"keep!\",else=>false}}"))
    (multiple-value-bind (out err status)
        (process-result (list "python3" (namestring (root-path "tests/v08-heap-check.py"))
                              (namestring (v06-gc-artifact source '(:stress t :validate t :trace t :arena-unit 4096 :cap 4096)))))
      (same 1 status) (same "" out) (is (search "dead Result parent retained" err) err)))
  (multiple-value-bind (out err status)
      (process-result (list "sbcl" "--dynamic-space-size" "256" "--noinform" "--script"
                            (namestring (root-path "tests/v08-host-gc-entry.lisp"))) :timeout 120)
    (is (= 0 status) err) (same "" err) (is (search "GENERIC_HOST_GC_OK" out)) (format t "~A" out)))
