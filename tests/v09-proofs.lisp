(in-package #:mognitio.tests)
(deftest v09-r09-specialization-runtime
  (dolist (arguments '("Int,Int" "Int,String" "Int,Number"))
    (dolist (flag '("true" "false"))
      (let* ((source (format nil "alias Number=Int;template probe<T,U>=function(flag:Bool):Int{1+(branch when{flag=>List<T>[panic{\"left\"}],else=>List<U>[panic{\"right\"}]})};discard probe<~A>(~A);true" arguments flag))
             (expected (format nil "panic: ~A~%" (if (string= flag "true") "left" "right"))))
        (multiple-value-bind (out err code) (driver-result (list "run" (namestring (put-text (fresh-path) source))))
          (same 4 code) (same "" out) (same expected err))
        (multiple-value-bind (out err code) (process-result (list (namestring (build-text source))))
          (same 4 code) (same "" out) (same expected err))))))

(deftest v09-noncompletion-structure-runtime
  (dolist (expression '("1+panic{\"stop\"}"
                        "({Result<Int,IndexError>::Ok(panic{\"stop\"})})"
                        "branch when{true=>Result<Int,IndexError>::Ok(panic{\"stop\"}),else=>Result<Int,IndexError>::Err(panic{\"other\"})}"))
    (let ((source (if (char= (char expression 0) #\1)
                      (concatenate 'string expression ";")
                      (format nil "let f:Function():Result<Int,IndexError>=function():Result<Int,IndexError>{Result<Int,IndexError>::Ok(try ~A)};discard f();true" expression))))
      (multiple-value-bind (out err code) (driver-result (list "run" (namestring (put-text (fresh-path) source))))
        (same 4 code) (same "" out) (same (format nil "panic: stop~%") err))
      (multiple-value-bind (out err code) (process-result (list (namestring (build-text source))))
        (same 4 code) (same "" out) (same (format nil "panic: stop~%") err))))
  (dolist (operand '("branch when{true=>Result<Int,String>::Ok(panic{\"x\"}),else=>List<Int>[panic{\"y\"}]}"
                     "branch when{true=>Result<Int,String>::Ok(panic{\"x\"}),else=>panic{\"y\"}}"))
    (signals compiler-failure
      (check-program (parse-text (format nil "let f:Function():Result<Int,String>=function():Result<Int,String>{Result<Int,String>::Ok(try ~A)};true" operand))))))

(deftest v09-specialization-table-and-loop-mutations
  (dolist (mutation '(:method :receiver :loop :foreign :builtin))
    (let* ((source "contract C{f(self:Self):Int;}implement Int against C{f(self:Self):Int{self}}var n:Int=0;loop over(List<Int>[1] as x:Int){n=n+C(x)->f();};n==1")
           (concrete (mognitio.semantic::prepare-runtime-program (check-program (parse-text source))))
           (values (checked-program-values concrete)))
      (ecase mutation
        (:method (setf (mognitio.semantic::requirement-result
                        (first (type-info-methods (find :interface (value-context-types values) :key #'type-info-kind)))) :bool))
        (:receiver (loop for sig across (checked-program-signatures concrete) when (signature-receiver sig)
                         do (setf (signature-receiver sig) nil)))
        (:loop (maphash (lambda (node info) (declare (ignore node)) (setf (loop-info-normal-type info) :int))
                        (mognitio.semantic::checked-program-loops concrete)))
        (:foreign (setf (gethash (make-boolean-literal :value :true)
                                (mognitio.semantic::checked-program-operations concrete))
                        (mognitio.semantic::make-operation-info :kind :add)))
        (:builtin (let* ((proof (mognitio.semantic::checked-program-specialization concrete))
                         (symbolic (mognitio.semantic::specialization-proof-source proof))
                         (info (aref (value-context-types (checked-program-values symbolic)) 0)))
                    (setf (type-info-fields info) '(("index" . :bool) ("length" . :int))))))
      (signals internal-failure (mognitio.semantic::verify-specialization concrete)))))

(deftest v09-core-and-root-mutations
  (dolist (mutation '(:capture :element :negative-index :unguarded :cycle))
    (let* ((module (native-ir "type P=product{x:Int;};let unused:P=P{x:0};discard unused;let n:Int=1;let f:Function():Int=function():Int{n};var total:Int=0;loop over(List<Int>[1,2] as x:Int){total=total+x+f();};total==5"))
           (instructions (v06-core-instructions module)) (get (v06-core-op module :buffer.get)))
      (ecase mutation
        (:capture (setf (mognitio.ir::ir-function-capture-types (second (mognitio.ir:module-functions module))) '(:bool)))
        (:element (setf (mognitio.ir:instruction-type get) :bool))
        (:negative-index
         (let* ((index (second (mognitio.ir:instruction-operands get)))
                (fn (first (mognitio.ir:module-functions module)))
                (header (find-if (lambda (b) (assoc index (mognitio.ir:basic-block-parameters b))) (mognitio.ir:ir-function-blocks fn)))
                (pos (position index (mognitio.ir:basic-block-parameters header) :key #'car))
                (entry (find-if (lambda (b) (let ((term (mognitio.ir:basic-block-terminator b)))
                             (and (eq (first term) :jump) (= (second term) (mognitio.ir:basic-block-id header))
                                  (find (nth pos (third term)) (mognitio.ir:basic-block-instructions b)
                                        :key #'mognitio.ir:instruction-result))))
                            (mognitio.ir:ir-function-blocks fn)))
                (zero (find (nth pos (third (mognitio.ir:basic-block-terminator entry))) instructions :key #'mognitio.ir:instruction-result)))
           (setf (mognitio.ir:instruction-value zero) -1)))
        (:unguarded (setf (mognitio.ir:instruction-op (find :lt instructions :key #'mognitio.ir:instruction-op)) :le))
        (:cycle (let ((p (find "P" (value-context-types (mognitio.ir:module-values module)) :key #'type-info-name :test #'string=)))
                  (setf (type-info-fields p) (list (cons "x" (list :list (canonical-type p))))))))
      (signals internal-failure (mognitio.ir:verify-module module))))
  (let* ((module (native-ir *v09-lifetime-source*)) (plans (mognitio.roots:analyze-roots module)))
    (replacing (mognitio.roots::analyze-function-roots (lambda (&rest args) (declare (ignore args)) (error "Producer used")))
      (is (mognitio.roots:verify-roots module plans)))
    (let ((site (loop for p in plans thereis
                       (find-if (lambda (s) (mognitio.roots:root-site-values s)) (mognitio.roots:root-plan-sites p)))))
      (is site) (pop (mognitio.roots:root-site-values site))
      (signals internal-failure (mognitio.roots:verify-roots module plans)))))

(deftest v09-native-metadata-mutations
  (dolist (mutation '(:closure :list :buffer :package :table))
    (let ((original (fdefinition 'mognitio.native.runtime::descriptors)))
      (if (eq mutation :table)
          (let* ((module (native-ir *v09-lifetime-source*)) (code (mognitio.machine:lower-module module)))
            (multiple-value-bind (bytes symbols) (mognitio.amd64:encode code)
              (let ((offset (mognitio.object:image-symbol-offset (gethash '(:method-table 0) symbols))))
                (setf (aref bytes (+ offset 24)) (logxor 1 (aref bytes (+ offset 24)))))
              (signals internal-failure (mognitio.backend.native::verify-native-metadata module bytes symbols))))
          (replacing (mognitio.native.runtime::descriptors
                      (lambda (context)
                        (let* ((rows (copy-tree (funcall original context)))
                               (kind (ecase mutation (:closure 4) (:list 5) (:buffer 6) (:package 3)))
                               (row (find-if (lambda (r) (and (= (second r) kind)
                                   (if (= kind 6) (seventh r) (sixth r)))) rows)))
                          (is row)
                          (if (= kind 6) (setf (seventh row) nil) (setf (sixth row) nil))
                          rows)))
            (is (handler-case (progn (native-image *v09-lifetime-source*) nil) (internal-failure () t)) (format nil "Metadata mutation escaped: ~A" mutation)))))))

(defun v09-record-host-allocations (compiled)
  (let ((names '(mognitio.value::list-append-value mognitio.value::closure mognitio.value:construct
                 mognitio.value:pack mognitio.text::allocate-text))
        (old nil) (weak nil))
    (unwind-protect
        (progn
          (dolist (name names)
            (let ((original (fdefinition name)))
              (push (cons name original) old)
              (setf (fdefinition name)
                    (lambda (&rest args)
                      (let ((value (apply original args)))
                        (push (sb-ext:make-weak-pointer value) weak) value)))))
          (same :true (execute-program compiled)))
      (dolist (pair old) (setf (fdefinition (car pair)) (cdr pair))))
    weak))
(deftest v09-host-bounded-lifetime
  (let* ((compiled (compile-program (check-program (parse-text *v09-lifetime-source*))))
         (weak (v09-record-host-allocations compiled)))
    (is (> (length weak) 14000))
    (sb-ext:gc :full t)
    (same 0 (count-if #'sb-ext:weak-pointer-value weak))))
