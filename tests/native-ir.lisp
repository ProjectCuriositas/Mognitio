(in-package #:mognitio.tests)

(defun native-ir (text) (mognitio.ir:lower-program (check-program (parse-text text))))
(defun entry-blocks (module)
  (mognitio.ir:ir-function-blocks (first (mognitio.ir:module-functions module))))
(defun native-image (text)
  (mognitio.backend.native:compile-program
   (check-program (parse-text text)) (mognitio.target:linux-amd64)))
(defun machine (&rest forms)
  (mapcar (lambda (form) (mognitio.machine:make-instruction
                         :opcode (first form) :operands (rest form))) forms))
(defun hex-bytes (text)
  (coerce (loop for start from 0 below (length text) by 2
                collect (parse-integer text :start start :end (+ start 2) :radix 16))
          '(vector (unsigned-byte 8))))
(defun image-integer (image offset width)
  (loop for index below width sum (ash (aref image (+ offset index)) (* 8 index))))

(deftest d01-ssa-verifier
  (dolist (text '("true" "branch when{(true)=>{false},else=>{true}}"
                  "branch when{(branch when{(true)=>{false},else=>{true}})=>{branch when{(false)=>{true},else=>{false}}},else=>{true}}"))
    (is (mognitio.ir:verify-module (native-ir text))))
  (dolist (mutation
           (list
            (lambda (ir)
              (setf (mognitio.ir:instruction-type
                     (first (mognitio.ir:basic-block-instructions
                             (first (entry-blocks ir))))) :int))
            (lambda (ir)
              (setf (mognitio.ir:basic-block-terminator
                     (first (entry-blocks ir))) '(:return 999)))
            (lambda (ir)
              (setf (mognitio.ir:basic-block-terminator
                     (first (entry-blocks ir))) nil))
            (lambda (ir)
              (setf (mognitio.ir:basic-block-terminator
                     (first (entry-blocks ir))) '(:branch 0 999 2)))
            (lambda (ir)
              (setf (mognitio.ir:basic-block-parameters
                     (second (entry-blocks ir))) '(100)))
            (lambda (ir)
              (setf (mognitio.ir:instruction-result
                     (first (mognitio.ir:basic-block-instructions
                             (second (entry-blocks ir))))) 0))
            (lambda (ir)
              (setf (mognitio.ir:basic-block-terminator
                     (third (entry-blocks ir))) '(:return 1)))
            (lambda (ir)
              (setf (mognitio.ir:basic-block-terminator
                     (first (entry-blocks ir))) '(:branch 0 0 2)))))
    (let ((ir (native-ir "branch when{(true)=>{false},else=>{true}}")))
      (funcall mutation ir)
      (signals internal-failure (mognitio.ir:verify-module ir))))
  (signals internal-failure (mognitio.ir:verify-module nil))
  (signals internal-failure (mognitio.ir:lower-program (parse-text "true")))
  (signals internal-failure
    (mognitio.backend.native:compile-program (check-program (parse-text "true")) nil)))

(deftest d02-d03-machine-goldens
  ;; Hand-reviewed encodings. Branches use rel32 even when rel8 would fit.
  (dolist (pair '(((:bool 0) "48c7c000000000") ((:bool 1) "48c7c001000000")
                   ((:test) "4885c0") ((:mov-edx 6) "ba06000000")
                   ((:mov-edi 1) "bf01000000") ((:mov-eax 60) "b83c000000")
                   ((:cmp-eintr) "4883f8fc") ((:add-rsi) "4801c6")
                   ((:sub-rdx) "4829c2") ((:xor-edi) "31ff")
                   ((:syscall) "0f05") ((:ud2) "0f0b")))
    (same (hex-bytes (second pair))
          (mognitio.amd64:encode (machine (first pair)))))
  (dolist (pair '((:jz "0f8400000000") (:jnz "0f8500000000")
                   (:jle "0f8e00000000") (:jmp "e900000000")
                   (:lea-rsi "488d3500000000")))
    (same (hex-bytes (second pair))
          (mognitio.amd64:encode (machine (list (first pair) :end) '(:label :end)))))
  (same (hex-bytes "e9fbffffff")
        (mognitio.amd64:encode (machine '(:label :back) '(:jmp :back))))
  (dolist (forms '(((:bool 2)) ((:bool 1 2)) ((:mov-eax -1))
                    ((:mov-edx 4294967296)) ((:test 1)) ((:unknown))
                    ((:label :a) (:label :a)) ((:jmp :missing))
                    ((:jmp 7)) ((:bytes 256))))
    (signals internal-failure (mognitio.amd64:encode (apply #'machine forms))))
  (same '(255 255 255 127) (mognitio.amd64:little-endian 2147483647 4 t))
  (same '(0 0 0 128) (mognitio.amd64:little-endian -2147483648 4 t))
  (dolist (number '(-2147483649 2147483648))
    (signals internal-failure (mognitio.amd64:little-endian number 4 t)))
  (signals internal-failure (mognitio.elf:make-image #()))
  (signals internal-failure (mognitio.elf::image-size (- (expt 2 64) #x400000 #x80)))
  (signals internal-failure (mognitio.elf::image-size 0))
  (signals internal-failure (mognitio.amd64:little-endian (expt 2 64) 8))
  ;; The OS adapter aligns the stack, clears RBP, and calls the entry function.
  (let ((code (mognitio.amd64:encode (mognitio.machine:lower-module (native-ir "true")))))
    (same (hex-bytes "4989e04889e24883e4f04831ed") (subseq code 0 13))))



(deftest n21-elf-layout
  (let* ((image (native-image "true")) (size (length image)))
    (same #(127 69 76 70 2 1 1 0) (subseq image 0 8))
    (dolist (field (list '(16 2 2) '(18 2 62) '(20 4 1)
                         '(24 8 4194432) '(32 8 64) '(40 8 0)
                         '(52 2 64) '(54 2 56) '(56 2 1)
                         '(58 2 0) '(60 2 0) '(62 2 0)
                         '(64 4 1) '(68 4 5) '(72 8 0)
                         '(80 8 4194304) '(88 8 4194304)
                         (list 96 8 size) (list 104 8 size) '(112 8 4096)))
      (same (third field) (image-integer image (first field) (second field))))
    (is (< (image-integer image 24 8)
           (+ (image-integer image 80 8) (image-integer image 104 8))))
    (same 0 (mod (image-integer image 80 8) (image-integer image 112 8)))
    (same (hex-bytes "4989e04889e24883e4f04831ed") (subseq image 128 141))))

(deftest v04-function-core-boundary
  (let* ((module (native-ir "true"))
         (entry (first (mognitio.ir:module-functions module))))
    (same 0 (mognitio.ir:module-entry module))
    (same :bool (mognitio.ir:ir-function-result-type entry))
    (dolist (mutation
             (list (lambda () (setf (mognitio.ir:ir-function-result-type entry) :int))
                   (lambda () (setf (mognitio.ir:ir-function-result-type entry) :bool
                                    (mognitio.ir:ir-function-parameter-types entry) '(:int)))
                   (lambda () (setf (mognitio.ir:module-functions module) (list entry entry)))))
      (funcall mutation)
      (signals internal-failure (mognitio.ir:verify-module module)))))

(deftest v04-frame-encoding
  (dolist (pair '(((:mov-reg :r8 :rax) "4989c0") ((:mov-reg :rax :r11) "4c89d8")
                  ((:mov-reg :r10 :r9) "4d89ca") ((:mov-reg :rbp :rsp) "4889e5")
                  ((:load-frame :r9 -8) "4c8b8df8ffffff")
                  ((:store-frame -16 :r10) "4c8995f0ffffff")
                  ((:store-out 8 :r11) "4c899c2408000000")
                  ((:load-frame :rax 16) "488b8510000000")
                  ((:push-rbp) "55") ((:pop-rbp) "5d") ((:ret) "c3")))
    (same (hex-bytes (second pair)) (mognitio.amd64:encode (machine (first pair)))))
  (same (hex-bytes "e801000000c3c3")
        (mognitio.amd64:encode (machine '(:call (:function 1)) '(:ret)
                                       '(:label (:function 1)) '(:ret))))
  (same (hex-bytes "c3e8faffffff")
        (mognitio.amd64:encode (machine '(:label (:function 1)) '(:ret) '(:call (:function 1)))))
  (dolist (forms '(((:call (:data :true)) (:label (:data :true)) (:bytes 0))
                   ((:call :block) (:label :block) (:ret))
                   ((:load-frame :r16 0)) ((:load-frame :rax -2147483656))
                   ((:store-out -8 :rax)) ((:mov-reg :rax :bogus))))
    (signals internal-failure (mognitio.amd64:encode (apply #'machine forms)))))
