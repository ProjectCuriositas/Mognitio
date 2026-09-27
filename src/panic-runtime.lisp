(in-package #:mognitio.runtime)

(define-condition program-panic (program-runtime-failure)
  ((message :initarg :message :reader panic-message)))
(defparameter *panic-prefix* (sb-ext:string-to-octets "panic: " :external-format :utf-8))
(defparameter *panic-newline* (make-array 1 :element-type '(unsigned-byte 8) :initial-element 10))
(defun raise-panic (message) (error 'program-panic :kind :panic :message message))

(defun write-panic (condition stream)
  ;; The condition retains the evaluated message. Reporting never evaluates
  ;; source again and cannot replace status 4 with a reporting failure.
  (handler-case
      (block reporting
        (dolist (bytes (list *panic-prefix* (mognitio.text::text-value-octets (panic-message condition)) *panic-newline*))
          (if (typep stream 'sb-sys:fd-stream)
              (let ((offset 0) (retries 0) (fd (sb-sys:fd-stream-fd stream)))
                (loop while (< offset (length bytes)) do
                  (let ((count (write-chunk fd bytes offset (- (length bytes) offset))))
                    (cond ((= count (- sb-posix:eintr))
                           (when (>= (incf retries) +retry-budget+) (return-from reporting)))
                          ((plusp count) (incf offset count) (setf retries 0))
                          (t (return-from reporting))))))
              (write-string (sb-ext:octets-to-string bytes :external-format :utf-8) stream)))
        (finish-output stream))
    ((or error storage-condition) () nil))
  4)
