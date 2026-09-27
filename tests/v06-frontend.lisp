(in-package #:mognitio.tests)

(defun v06-checked (source)
  (verify-checked-program (check-program (parse-text source))))

(deftest v06-literal-tokens-and-locations
  (let* ((source (text-source " \"Aあ😀\\0\\n\\r\\t\\\"\\\\\"->length() == 9"))
         (tokens (lex-source source)) (token (aref tokens 0))
         (payload (token-payload token)))
    (same :string-literal (token-kind token))
    (same 9 (text-payload-scalar-count payload))
    (same #(65 227 129 130 240 159 152 128 0 10 13 9 34 92) (text-payload-octets payload))
    (same 1 (span-start (token-span token)))
    (same :arrow (token-kind (aref tokens 1))))
  (dolist (pair (list (list "  \"abc" 3) (list "  \"abc\\" 3)
                     (list "  \"a\\q\"" 5) (list "  \"a\\u0041\"" 5)
                     (list "  \"a\\x41\"" 5)))
    (let ((diag (diagnostic-of (lambda () (lex-source (text-source (first pair)))))))
      (same :lex (diagnostic-phase diag)) (same 1 (diagnostic-line diag))
      (same (second pair) (diagnostic-column diag))))
  (dolist (code '(10 13))
    (let* ((source (format nil "  ~Cabc~C~C" #\" (code-char code) #\"))
           (diag (diagnostic-of (lambda () (lex-source (text-source source))))))
      (same :lex (diagnostic-phase diag)) (same 7 (diagnostic-column diag))))
  (dolist (bytes '(#(34 237 160 128 34) #(34 192 128 34)
                   #(239 187 191 239 187 191 34 34)))
    (same :source (diagnostic-phase (diagnostic-of (lambda () (decode-source "literal.mgn" bytes))))))
  (same :source (diagnostic-phase
                 (diagnostic-of
                  (lambda () (v06-checked (format nil "~C~A" (code-char #xfeff)
                                                 "\"A\"->length()==1")))))))

(deftest v06-postfix-and-static-contracts
  (is (typep (local-binding-annotation (aref (program-statements (parse-text "let a:string=\"a\"; true")) 0)) 'token))
  (let* ((checked (v06-checked "\"Aあ😀\"->slice(1,3)->length()==2"))
         (outer (binary-expression-left (program-root (checked-program-program checked))))
         (inner (method-call-receiver outer)))
    (is (typep inner 'method-call))
    (same :text.length (operation-info-kind (checked-operation checked outer)))
    (same :text.slice (operation-info-kind (checked-operation checked inner)))
    (same :string (checked-normal-type checked inner)))
  (dolist (source
    '("let f:function(string):string=function(x:string):string {x}; let a: string=f(\"a\"); var b: string=a; b=\"b\"; a==\"a\""
      "let length: int=1; let slice: int=2; let string_length:function(string):int=function(x:string):int {x->length()}; let string_slice:function(string):int=string_length; string_slice(\"a\")==1"
      "let class: int=1; class==1"
      "let f:function():string=function():string {branch when{(true)=>{return \"a\";},else=>{\"b\"}}}; f()==\"a\""
      "loop {break \"a\";}==\"a\""
      "let f:function():int=function():int {({return 7;})->unknown(1,2)}; f()==7"
      "let f:function():int=function():int {\"a\"->slice({return 7;},1)->length()}; f()==7"
      "let f:function():int=function():int {({return 7;})+\"a\"}; f()==7"))
    (is (v06-checked source)))
  (dolist (source
    '("\"a\"+1==0" "1+\"a\"==0" "\"a\"==1" "true!=\"a\""
      "\"a\"-\"b\"==0" "\"a\"*1==0" "\"a\"/1==0" "\"a\"%1==0" "-\"a\"==0"
      "\"a\"<\"b\"" "\"a\"<=\"b\"" "\"a\">\"b\"" "\"a\">=\"b\""
      "\"a\"" "\"a\"; true" "1->length()==0" "true->length()==0" "void->length()==0"
      "(function():string {\"a\"})->length()==0" "\"a\"->Length()==1" "\"a\"->unknown()==1"
      "\"a\"->length(1)==1" "\"a\"->slice(0)==\"a\"" "\"a\"->slice(0,1,2)==\"a\""
      "\"a\"->slice(false,1)==\"a\"" "\"a\"->slice(0,\"a\")==\"a\""
      "string_length(\"a\")==1" "string_slice(\"a\",0,1)==\"a\""
      "let a: string=\"a\"; let f:function():string=function():string {a}; true"
      "let f:function():string=function():string {f()}; true" "var a: string=\"a\"; a=1; true"
      "branch when{(true)=>{\"a\"},else=>{1}}" "loop {branch when{(true)=>{break \"a\";}}; break 1;}==\"a\""
      "loop {branch when{(true)=>{break;}}; break \"a\";}; true"
      "let f:function():string=function():string {return;}; true"
      "let f:function():int=function():int {({return 7;})->unknown(missing)}; true"
      "let f:function():int=function():int {\"a\"->slice({return 7;},false)}; true"
      "let f:function():int=function():int {\"a\"->length({return 7;})}; true"
      "let f:function():int=function():int {({return 7;})+true}; true"
      "branch when{(true)=>{true},else=>{\"a\"->slice(0,false)==\"a\"}}"))
    (v03-reject source "semantic"))
  (dolist (source '("\"a\"->length" "(\"a\"->length)()")) (v03-reject source "semantic"))
  (dolist (source '("let string=1; true" "let f:function(int):int=function(string:int):int {1}; true"
                    "string::length" "string::length(\"a\")"
                    "\"a\" \"b\""))
    (v03-reject source "parse"))
  (dolist (source '("'a'" "\"a\"[0]" "\"a\".length()")) (v03-reject source "lex")))

(deftest v06-checked-operation-corruption
  (dolist (mutate
    (list (lambda (c n op) (declare (ignore op)) (remhash n (mognitio.semantic::checked-program-operations c)))
          (lambda (c n op) (declare (ignore c n)) (setf (mognitio.semantic::operation-info-kind op) :text.concat))
          (lambda (c n op) (declare (ignore c n)) (setf (mognitio.semantic::operation-info-operands op) (reverse (operation-info-operands op))))
          (lambda (c n op) (declare (ignore c n)) (setf (mognitio.semantic::operation-info-parameter-types op) '(:string :bool :int)))
          (lambda (c n op) (declare (ignore c n)) (setf (mognitio.semantic::operation-info-result-type op) :int))
          (lambda (c n op) (declare (ignore n)) (setf (gethash (make-symbol "EXTRA") (mognitio.semantic::checked-program-operations c)) op))))
    (let* ((c (v06-checked "\"abc\"->slice(0,1)==\"a\""))
           (n (binary-expression-left (program-root (checked-program-program c))))
           (op (checked-operation c n)))
      (funcall mutate c n op) (signals internal-failure (verify-checked-program c))))
  (let* ((c (v06-checked "let f:function():int=function():int {({return 7;})->unknown(1)}; f()==7"))
         (function (local-binding-initializer (aref (program-statements (checked-program-program c)) 0)))
         (method (sequence-node-terminal (function-expression-body function))))
    (setf (gethash method (mognitio.semantic::checked-program-operations c))
          (mognitio.semantic::make-operation-info :kind :text.length :operands (list (method-call-receiver method))
                                                :parameter-types '(:string) :result-type :int))
    (signals internal-failure (verify-checked-program c))))


(deftest v06-checked-literal-and-exit-corruption
  (dolist (payload (list (make-text-payload :octets (make-array 1 :element-type '(unsigned-byte 8) :initial-element 255) :scalar-count 1)
                        (make-text-payload :octets (make-array 1 :element-type '(unsigned-byte 8) :initial-element 65) :scalar-count 2)))
    (let* ((source (text-source "\"A\"==\"A\""))
           (tokens (lex-source source)) (old (aref tokens 0)))
      (setf (aref tokens 0) (make-token :kind :string-literal :span (token-span old) :payload payload))
      (signals internal-failure (verify-checked-program (check-program (parse-program source tokens))))))
  (let* ((checked (v06-checked "let f:function():int=function():int {\"a\"->slice({return 7;},1)->length()}; f()==7"))
         (function (local-binding-initializer (aref (program-statements (checked-program-program checked)) 0)))
         (outer (sequence-node-terminal (function-expression-body function)))
         (summary (checked-completion checked outer)))
    (setf (mognitio.semantic::completion-exits summary) nil
          (mognitio.semantic::completion-may-return summary) nil)
    (signals internal-failure (verify-checked-program checked)))
  (dolist (pair '(("\"abc\"->missing() == 1" 8) ("1->length()==0" 4)
                  ("\"a\"->slice(0,false)==\"a\"" 14)))
    (let ((diag (diagnostic-of (lambda () (check-program (parse-text (first pair)))))))
      (same :semantic (diagnostic-phase diag)) (same (second pair) (diagnostic-column diag)))))
