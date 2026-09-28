(in-package #:mognitio.tests)

(deftest v01-v02-booleans-and-branches
  (expect-source "true" :true)
  (expect-source "false" :false)
  (dolist (condition '(:true :false))
    (dolist (then '(:true :false))
      (dolist (else '(:true :false))
        (expect-source
         (format nil "branch when{(~(~A~))=>{~(~A~)},else=>{~(~A~)}}" condition then else)
         (if (eq condition :true) then else)))))
  (expect-source "branch when{(branch when{(false)=>{true},else=>{false}})=>{branch when{(true)=>{false},else=>{true}}},else=>{branch when{(false)=>{false},else=>{true}}}}"
                 :true))

(deftest v03-whitespace-and-eof
  (dolist (space (list " " (string #\Tab) (string #\Newline)
                       (string #\Return) (format nil "~C~C" #\Return #\Newline)))
    (let* ((text (format nil "~Abranch~Awhen~A{~Atrue~A=>~Afalse~A,~Aelse~A=>~Atrue~A}~A"
                         space space space space space space space space
                         space space space space))
           (source (text-source text))
           (tokens (lex-source source)))
      (same '(:branch :when :left-brace :true :fat-arrow :false :comma
              :else :fat-arrow :true :right-brace :eof)
            (map 'list #'token-kind tokens))
      (same (length text) (span-start (token-span (aref tokens 11))))
      (same (length text) (span-end (token-span (aref tokens 11))))
      (expect-source text :false))))

(deftest v09-bom-rejection
  (dolist (bytes '(#(239 187 191) #(239 187 191 116 114 117 101)
                   #(239 187 191 239 187 191)))
    (let ((diag (diagnostic-of (lambda () (decode-source "bom.mgn" bytes)))))
      (same :source (diagnostic-phase diag))
      (same 0 (diagnostic-start-byte diag)) (same 3 (diagnostic-end-byte diag)))
    (expect-cli (list "run" (namestring (put-bytes (fresh-path) bytes))) 1 :phase "source"))
  ;; U+FEFF is a scalar inside content, but is not whitespace between tokens.
  (expect-cli (list "run" (namestring (put-bytes (fresh-path) #(116 114 117 101 239 187 191))))
              1 :phase "lex"))

(deftest v05-strict-utf8
  (dolist (bytes '(#(128) #(191) #(192 128) #(193 191) #(194) #(223)
                   #(224) #(224 160) #(224 159 191) #(225 128)
                   #(237 160 128) #(239 187) #(240) #(240 144) #(240 144 128)
                   #(240 143 191 191) #(244 144 128 128) #(245 128 128 128)
                   #(255) #(194 127) #(194 192) #(225 128 127)
                   #(241 128 128 192) #(239)))
    (let ((diag (diagnostic-of (lambda () (decode-source "bytes.mgn" bytes)))))
      (same :source (diagnostic-phase diag))
      (same 1 (diagnostic-line diag))
      (same 1 (diagnostic-column diag)))
    (expect-cli (list "run" (namestring (put-bytes (fresh-path) bytes)))
                1 :phase "source"))
  ;; Entire source is decoded before an earlier invalid token can be lexed.
  (expect-cli (list "run" (namestring (put-bytes (fresh-path) #(59 255))))
              1 :phase "source"))

(deftest v07-location-boundaries
  (dolist (case (list (list (format nil "~C@" #\Tab) 1 2)
                     (list (format nil "true~%@") 2 1)
                     (list (format nil "true~C@" #\Return) 2 1)
                     (list (format nil "true~C~C@" #\Return #\Newline) 2 1)
                     (list (format nil "~C~C~C@" #\Return #\Newline #\Tab) 2 2)))
    (let* ((text (first case)) (source (text-source text))
           (diag (diagnostic-of (lambda () (lex-source source)))))
      (same :lex (diagnostic-phase diag))
      (same (second case) (diagnostic-line diag))
      (same (third case) (diagnostic-column diag))
      (let* ((path (put-text (fresh-path) text))
             (err (expect-cli (list "run" (namestring path)) 1 :phase "lex")))
        (is (search (format nil ":~D:~D: lex:" (second case) (third case)) err)))))
  (let* ((source (text-source (format nil "branch when{true=>false,else=>{~C~C~C"
                                            #\Return #\Newline #\Tab)))
         (diag (diagnostic-of (lambda () (parse-program source (lex-source source))))))
    (same 2 (diagnostic-line diag)) (same 2 (diagnostic-column diag)))
  (let ((diag (diagnostic-of
               (lambda () (decode-source "bad.mgn" #(13 10 9 226 130 0))))))
    (same 2 (diagnostic-line diag)) (same 2 (diagnostic-column diag)))
  (let ((source (text-source (format nil "~C~C~C" #\Return #\Newline #\Tab))))
    (same #(1 2 2 2) (source-lines source))
    (same #(1 1 1 2) (source-columns source)))
  (let ((diag (diagnostic-of
               (lambda () (lex-source (decode-source "tab.mgn" #(9 64)))))))
    (same 1 (diagnostic-line diag)) (same 2 (diagnostic-column diag))))

(deftest v08-valid-unicode
  (dolist (case '((#(0) 0) (#(127) 127) (#(194 128) 128) (#(223 191) 2047)
                  (#(224 160 128) 2048) (#(237 159 191) 55295)
                  (#(238 128 128) 57344) (#(239 191 191) 65535)
                  (#(240 144 128 128) 65536) (#(244 143 191 191) 1114111)
                  (#(194 160) 160) (#(230 151 165) 26085)))
    (let ((source (decode-source "unicode.mgn" (first case))))
      (same (second case) (char-code (char (source-text source) 0)))
      (same (list 0 (length (first case))) (coerce (source-byte-offsets source) 'list))
      (same :lex (diagnostic-phase (diagnostic-of (lambda () (lex-source source))))))
    (expect-cli (list "run" (namestring (put-bytes (fresh-path) (first case))))
                1 :phase "lex")))

(deftest v06-invalid-words-and-characters
  ;; v0.3 identifiers are lexically valid; unresolved names fail semantically.
  (dolist (text '("foo" "truefalse" "trueif" "True" "TRUE" "true1" "1" "null"))
    (expect-invalid text "semantic"))
  (dolist (text '("_" "$x" "@" "#.(quit)")) (expect-invalid text "lex"))
  (dolist (text '(";" "// comment" "/*x*/" "+")) (expect-invalid text "parse"))
  (let* ((source (text-source "truefalse")) (tokens (lex-source source)))
    (same :identifier (token-kind (aref tokens 0)))
    (same 0 (span-start (token-span (aref tokens 0))))
    (same 9 (span-end (token-span (aref tokens 0))))))

(deftest v09-v12-invalid-grammar
  (dolist (text '("" " "  "branch when{(true)=>{true false},else=>{false}}"
                  "if true){true}else{false}" "if(true{true}else{false}"
                  "if(true)true}else{false}" "if(true){true else{false}"
                   "if(true){true}else false}"
                  "if(true){true}else{false" "true)" "true false"
                  "branch when{(true)=>{true},else=>{false}}branch when{(false)=>{false},else=>{true}}"
                  "if(true){true}else branch when{(false)=>{true},else=>{false}}"
                  ))
    (expect-invalid text "parse")))

(deftest frontend-spans
  (let* ((program (parse-text " branch when{(true)=>{false},else=>{true}} "))
         (node (program-root program)))
    (same 1 (span-start (node-span node)))
    (same 42 (span-end (node-span node)))
    (same 13 (span-start (node-span (branch-arm-selector (aref (branch-expression-arms node) 0)))))
    (same 19 (span-end (node-span (branch-arm-selector (aref (branch-expression-arms node) 0)))))))

(deftest v05-legacy-if-type-rejections
  (dolist (text '("branch when{(true)=>{},else=>{false}}" "branch when{(true)=>{true}}" "branch when{(true)=>{true},else=>{}}"))
    (v03-reject text "semantic")))
