(in-package #:mognitio.diagnostics)

(defstruct diagnostic phase message path line column start-byte end-byte)
(define-condition compiler-failure (error)
  ((diagnostic :initarg :diagnostic :reader failure-diagnostic)))
(define-condition source-failure (compiler-failure) ())
(define-condition usage-or-io-failure (compiler-failure) ())
(define-condition internal-failure (compiler-failure) ())

(defun fail (kind phase message &key path line column start-byte end-byte)
  (error kind :diagnostic (make-diagnostic :phase phase :message message
                                          :path path :line line :column column
                                          :start-byte start-byte :end-byte end-byte)))
(defun internal-error (message)
  (fail 'internal-failure :internal message))

(defun one-line (text)
  (with-output-to-string (out)
    (loop for ch across (princ-to-string text)
          for code = (char-code ch)
          do (cond ((char= ch #\Newline) (write-string "\\n" out))
                   ((char= ch #\Return) (write-string "\\r" out))
                   ((or (< code 32) (= code 127) (= code #x2028) (= code #x2029))
                    (format out "\\u~4,'0X" code))
                   (t (write-char ch out))))))

(defun render-diagnostic (diagnostic stream)
  (let ((path (diagnostic-path diagnostic))
        (line (diagnostic-line diagnostic))
        (column (diagnostic-column diagnostic))
        (phase (diagnostic-phase diagnostic)))
    (cond ((and path line column)
           (format stream "~A:~D:~D: ~A: ~A~A~%"
                   (one-line path) line column
                   (string-downcase (symbol-name phase))
                   (one-line (diagnostic-message diagnostic))
                   (if (and (diagnostic-start-byte diagnostic) (diagnostic-end-byte diagnostic))
                       (format nil " [bytes ~D,~D)" (diagnostic-start-byte diagnostic)
                               (diagnostic-end-byte diagnostic)) "")))
          (t (format stream "~A: ~A~A~%"
                     (if path (one-line path) "mgn")
                     (if (eq phase :internal) "internal: " "")
                     (one-line (diagnostic-message diagnostic))))))
  (finish-output stream))
