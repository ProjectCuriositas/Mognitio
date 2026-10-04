(in-package #:mognitio.tests)

(defun v14-both (body &optional (extra "") options)
  (same 0 (v13-host-code body extra))
  (handler-case (same 0 (v13-native-code body extra options))
    (internal-failure (e) (error "~A" (diagnostic-message (failure-diagnostic e))))))

(deftest v014-text-content
  (dolist (literal '("" "ascii" "日本😀" "e\\u{301}" "\\0\\u{feff}\\r\\n"))
    (v14-both (format nil "let original:String=~A;let parts:List<String>=original->scalars();assert parts->length()==original->length();loop over(parts as scalar:String){assert scalar->length()==1;};assert parts->join(\"\")==original;0"
                     (concatenate 'string "\"" literal "\""))))
  (v14-both "assert List<String>[]->join(\"x\")==\"\";assert List<String>[\"\",\"a\",\"\",\"日\",\"\"]->join(\"😀\")==\"😀a😀😀日😀\";assert List<String>[\"one\"]->join(\"unused\")==\"one\";0"))

(deftest v014-text-lifetime
  (v14-both "let make:Function():List<String>=function():List<String>{let text:String=\"日\"+\"abc😀\";text->scalars()};let old:List<String>=make();let left:List<String>=old->append(\"L\");let right:List<String>=old->append(\"R\");let keep:Function():String=function():String{old->join(\"|\")};var i:Int=0;loop while(i<200){discard (\"dead\"+\"!\")->scalars()->join(\"x\");i=i+1;};assert left->join(\"\")==\"日abc😀L\";assert right->join(\"\")==\"日abc😀R\";assert keep()==\"日|a|b|c|😀\";0"
            "" '(:arena-unit 4096 :cap 16384 :stress t :validate t)))

(deftest v014-text-evaluation
  (v14-both "let receiver:Function():List<String>=function():List<String>{discard writeStdout(\"\");List<String>[]};let separator:Function():String=function():String{discard writeStdout(\"\");\"x\"};assert receiver()->join(separator())==\"\";let stop:Function():Int=function():Int{let value:String=List<String>[]->join(branch when {args->length()==0=>{return 7;},else=>\"unused\"});9};assert stop()==7;0")
  (dolist (source '("discard List<Int>[1]->join(\"\");0" "discard \"x\"->join(\"\");0"
                    "loop over(\"x\" as scalar:String){discard scalar;};0" "discard List<String>[]->join();0" "discard \"x\"->scalars(1);0"
                    "\"x\"->scalars();0" "let f:Function():List<String>=\"x\"->scalars;0"))
    (signals compiler-failure (project-checked (v13-manifest source))))
  (dolist (use '("" "discard genericJoin<String>(List<String>[]);"))
    (signals compiler-failure
      (project-checked (v13-manifest (concatenate 'string use "0")
        "template genericJoin<T>=function(parts:List<T>):String{parts->join(\"\")};"))))
  (v14-both "assert concrete<Int>(1)==\"ab\";assert aliased<Int>(1)==\"xy\";0"
    "alias Texts=List<String>;template concrete<T>=function(value:T):String{List<String>[\"a\",\"b\"]->join(\"\")};template aliased<T>=function(value:T):String{let parts:Texts=List<String>[\"x\",\"y\"];parts->join(\"\")};"))

(deftest v014-host-cost
  (dolist (n '(64 128 256))
    (let* ((events (make-hash-table))
           (mognitio.value::*text-operation-observer* (lambda (kind count) (incf (gethash kind events 0) count)))
           (text (v12-text (make-string n :initial-element #\日)))
           (parts (mognitio.value::text-scalars text))
           (joined (mognitio.value::text-join parts (v12-text "😀"))))
      (same n (gethash :scalar-step events)) (same (* n 3) (gethash :scalar-copy events))
      (same n (gethash :join-size-node events)) (same n (gethash :join-copy-node events))
      (same (+ (* n 3) (* (1- n) 4)) (gethash :join-copy events))
      (same 1 (gethash :join-allocation events)) (same (1- (* 2 n)) (mognitio.text:text-length joined)))))
