(in-package #:mognitio.runtime)

(defconstant +retry-budget+ 16)
(defparameter *failure-data*
  '((:overflow "runtime error: integer overflow")
    (:division-by-zero "runtime error: division by zero")
    (:remainder-by-zero "runtime error: division by zero")
    (:string-index-out-of-bounds "runtime: string_index_out_of_bounds")
    (:string-size-overflow "runtime error: string length overflow")
    (:list-length-overflow "runtime error: list length overflow")
    (:allocation-failed "runtime error: allocation failure")))
(define-condition program-runtime-failure (error)
  ((kind :initarg :kind :reader failure-kind)))
(define-condition integer-runtime-failure (program-runtime-failure) ())
(defparameter *failure-bytes*
  (mapcar (lambda (entry)
            (cons (first entry) (sb-ext:string-to-octets (format nil "~A~%" (second entry)) :external-format :utf-8)))
          *failure-data*))
(defun failure-octets (kind)
  (let ((entry (assoc kind *failure-bytes*)))
    (unless entry (mognitio.diagnostics:internal-error "Unknown runtime failure"))
    (cdr entry)))
(defun runtime-error (kind)
  (error (if (member kind '(:overflow :division-by-zero :remainder-by-zero))
             'integer-runtime-failure 'program-runtime-failure) :kind kind))
(defun failure-status (kind) (failure-octets kind) 4)

(defun write-chunk (fd bytes offset count)
  (sb-sys:with-pinned-objects (bytes)
    (handler-case
        (sb-posix:write fd (sb-sys:sap+ (sb-sys:vector-sap bytes) offset) count)
      (sb-posix:syscall-error (c) (- (sb-posix:syscall-errno c))))))

(defun write-runtime-failure (condition stream)
  ;; Reporting cannot replace the original failure, or restart source evaluation.
  (let ((bytes (failure-octets (failure-kind condition))))
    (handler-case
        (if (typep stream 'sb-sys:fd-stream)
            (let ((offset 0) (retries 0) (fd (sb-sys:fd-stream-fd stream)))
              (loop while (< offset (length bytes)) do
                (let ((count (write-chunk fd bytes offset (- (length bytes) offset))))
                  (cond ((= count (- sb-posix:eintr))
                         (when (>= (incf retries) +retry-budget+) (return)))
                        ((plusp count) (incf offset count) (setf retries 0))
                        (t (return))))))
            ;; In-memory adapters preserve the driver test interface.
            (progn (write-string (sb-ext:octets-to-string bytes :external-format :utf-8) stream)
                   (finish-output stream)))
      ((or error storage-condition) () nil)))
  (failure-status (failure-kind condition)))

(defvar *allocation-hook* nil)
(defun allocation-point (kind)
  (when *allocation-hook* (funcall *allocation-hook* kind)))
