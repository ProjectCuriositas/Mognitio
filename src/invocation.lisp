(in-package #:mognitio.driver)

;; Only the installed launcher supplies this private byte stream. Runtime
;; arguments remain octets until after the complete project has been checked.
(defstruct raw-invocation arguments)

(defun invocation-error ()
  (fail 'usage-or-io-failure nil
        "Expected test <mognitio.toml>, run <mognitio.toml> [-- arguments...] or build <mognitio.toml> -o <artifact>"))

(defun read-raw-invocation (stream)
  (labels ((field ()
             (let ((bytes (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
               (loop for byte = (read-byte stream nil nil) do
                 (unless byte (invocation-error))
                 (when (zerop byte) (return bytes))
                 (vector-push-extend byte bytes)))))
    (let* ((header (field)) (count 0) (arguments nil))
      (unless (plusp (length header)) (invocation-error))
      (loop for byte across header do
        (unless (<= 48 byte 57) (invocation-error))
        (setf count (+ (* count 10) (- byte 48)))
        (when (> count most-positive-fixnum) (invocation-error)))
      (dotimes (index count) (push (field) arguments))
      (when (read-byte stream nil nil) (invocation-error))
      (make-raw-invocation :arguments (nreverse arguments)))))

(defun compiler-argument (value)
  (if (stringp value) value
      (handler-case (sb-ext:octets-to-string value :external-format :utf-8)
        (sb-int:character-decoding-error () (invocation-error)))))

(defun parse-invocation (input)
  (let* ((argv (if (raw-invocation-p input) (raw-invocation-arguments input) input))
         (command nil) (source nil) (output nil) (arguments nil))
    (unless (and (listp argv) (>= (length argv) 2)
                 (every (lambda (arg) (or (stringp arg) (typep arg '(vector (unsigned-byte 8))))) argv))
      (invocation-error))
    (setf command (compiler-argument (first argv)) source (compiler-argument (second argv)))
    (cond ((and (equal command "test") (= (length argv) 2)))
          ((and (equal command "run")
                (or (= (length argv) 2) (equal (compiler-argument (third argv)) "--")))
           (setf arguments (cdddr argv)))
          ((and (equal command "build") (= (length argv) 4)
                (equal (compiler-argument (third argv)) "-o"))
           (setf output (compiler-argument (fourth argv)))
           (unless (plusp (length output)) (invocation-error)))
          (t (invocation-error)))
    (unless (and (plusp (length source)) (not (char= #\- (char source 0)))) (invocation-error))
    (values command source output (when output (mognitio.target:linux-amd64)) arguments)))
