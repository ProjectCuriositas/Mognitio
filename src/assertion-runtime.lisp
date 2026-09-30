(in-package #:mognitio.runtime)

(define-condition program-assertion (program-runtime-failure)
  ((site :initarg :site :reader assertion-site)))

(defun assertion-bytes (span &optional test-context)
  (sb-ext:string-to-octets
   (with-output-to-string (stream)
     (mognitio.diagnostics:render-diagnostic
      (mognitio.source:span-diagnostic span :assertion
        (if test-context "assertion failed" "assertion failed (outside test)")) stream))
   :external-format :utf-8))

(defun raise-assertion (span)
  (error 'program-assertion :kind :assertion :site span))

(defun write-assertion (condition stream)
  (handler-case
      (let ((bytes (assertion-bytes (assertion-site condition))))
        (if (typep stream 'sb-sys:fd-stream)
            (let ((offset 0) (retries 0))
              (loop while (< offset (length bytes)) do
                (let ((n (write-chunk (sb-sys:fd-stream-fd stream) bytes offset (- (length bytes) offset))))
                  (cond ((= n (- sb-posix:eintr)) (when (>= (incf retries) +retry-budget+) (return)))
                        ((plusp n) (incf offset n) (setf retries 0)) (t (return))))))
            (progn (write-string (sb-ext:octets-to-string bytes :external-format :utf-8) stream)
                   (finish-output stream))))
    ((or error storage-condition) () nil))
  5)
