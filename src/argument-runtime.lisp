(in-package #:mognitio.runtime)

(defvar *arguments* mognitio.value::*empty-list*)

(defun %decode-arguments (arguments)
  ;; Complete byte validation precedes all user initialization. BOM is content.
  (let ((decoded
          (mapcar (lambda (argument)
                    (let ((bytes (if (stringp argument)
                                     (sb-ext:string-to-octets argument :external-format :utf-8) argument)))
                      (let ((count (utf8-count bytes)))
                        (unless count
                          (mognitio.diagnostics:fail 'mognitio.diagnostics:usage-or-io-failure nil
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
