(in-package #:mognitio.runtime)

(defvar *arguments* mognitio.value::*empty-list*)
(define-condition argument-startup-failure (mognitio.diagnostics:usage-or-io-failure) ())

(defun %decode-arguments (arguments)
  ;; Complete byte validation precedes all user initialization. BOM is content.
  (let ((decoded
          (mapcar (lambda (argument)
                    (let ((bytes (if (stringp argument)
                                     (sb-ext:string-to-octets argument :external-format :utf-8) argument)))
                      (let ((count (utf8-count bytes)))
                        (unless count
                          (mognitio.diagnostics:fail 'argument-startup-failure nil
                                                    "Invalid UTF-8 runtime argument"))
                        (cons bytes count)))) arguments))
        (result mognitio.value::*empty-list*))
    (dolist (pair decoded result)
      (let ((text (if (zerop (length (car pair))) mognitio.text::*empty*
                      (mognitio.text::allocate-text (length (car pair)) (cdr pair)
                        (lambda (out) (replace out (car pair)))))))
        (setf result (mognitio.value::list-append-value result text))))))

(defun decode-arguments (arguments)
  (handler-case (%decode-arguments arguments)
    (storage-condition () (runtime-error :allocation-failed))))

(defun application-status (result)
  (unless (and (integerp result) (<= 0 result 255)) (runtime-error :invalid-exit-status))
  result)

(defun write-argument-startup-failure (condition stream)
  ;; Startup is already a primary exit 2. Write directly to an fd so a failed
  ;; diagnostic cannot remain buffered for a retry after the signal guard ends.
  (handler-case
      (if (typep stream 'sb-sys:fd-stream)
          (let* ((message (with-output-to-string (out)
                            (mognitio.diagnostics:render-diagnostic
                              (mognitio.diagnostics:failure-diagnostic condition) out)))
                 (bytes (sb-ext:string-to-octets message :external-format :utf-8))
                 (offset 0) (retries 0) (fd (sb-sys:fd-stream-fd stream)))
            (loop while (< offset (length bytes)) do
              (let ((count (write-chunk fd bytes offset (- (length bytes) offset))))
                (cond ((= count (- sb-posix:eintr))
                       (when (>= (incf retries) +retry-budget+) (return)))
                      ((plusp count) (incf offset count) (setf retries 0))
                      (t (return))))))
          (mognitio.diagnostics:render-diagnostic
            (mognitio.diagnostics:failure-diagnostic condition) stream))
    ((or error storage-condition) () nil))
  2)
