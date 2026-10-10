(in-package #:mognitio.value)

(defstruct (bytes-value (:constructor %make-bytes-value (data)))
  (data (make-array 0 :element-type '(unsigned-byte 8)) :read-only t))
(defparameter *empty-bytes* (%make-bytes-value (make-array 0 :element-type '(unsigned-byte 8))))
(defvar *bytes-length-limit* mognitio.integer:+maximum+)

(defun bytes-size (length)
  (when (> length *bytes-length-limit*) (mognitio.runtime:runtime-error :bytes-length-overflow))
  length)
(defun fresh-bytes (length fill)
  (bytes-size length)
  (when (zerop length) (return-from fresh-bytes *empty-bytes*))
  (handler-case
      (progn
        (when (>= length array-dimension-limit) (mognitio.runtime:runtime-error :allocation-failed))
        (mognitio.runtime::allocation-point :bytes)
        (let ((data (make-array length :element-type '(unsigned-byte 8))))
          (funcall fill data)
          (%make-bytes-value data)))
    (storage-condition () (mognitio.runtime:runtime-error :allocation-failed))))

(defun bytes-from-list (value checked result error-type)
  (let* ((buffer (list-buffer value)) (length (length buffer)))
    (when checked
      (loop for byte across buffer for index from 0 do
        (unless (<= 0 byte 255)
          (return-from bytes-from-list
            (construct result 1 (construct error-type 0 index byte))))))
    (let ((bytes (fresh-bytes length (lambda (data) (replace data buffer)))))
      (if checked (construct result 0 bytes) bytes))))

(defun bytes-length (value) (length (bytes-value-data value)))
(defun bytes-at (value index result error-type)
  (let ((data (bytes-value-data value)))
    (if (<= 0 index (1- (length data)))
        (construct result 0 (aref data index))
        (construct result 1 (construct error-type 0 index (length data))))))
(defun bytes-append (value byte)
  (let* ((old (bytes-value-data value)) (length (length old)))
    (fresh-bytes (1+ length)
      (lambda (data) (replace data old) (setf (aref data length) byte)))))
(defun bytes-concat (left right)
  (let* ((a (bytes-value-data left)) (b (bytes-value-data right)) (size (+ (length a) (length b))))
    (fresh-bytes size
      (lambda (data) (replace data a) (replace data b :start1 (length a))))))
(defun bytes-slice (value start end result error-type)
  (let ((data (bytes-value-data value)))
    (if (<= 0 start end (length data))
        (construct result 0 (fresh-bytes (- end start)
                              (lambda (out) (replace out data :start2 start :end2 end))))
        (construct result 1 (construct error-type 0 start end (length data))))))
(defun bytes-equal (left right) (equalp (bytes-value-data left) (bytes-value-data right)))
(defun bytes-not-equal (left right) (not (bytes-equal left right)))
(defun bits-to-bytes (value width order result error-type)
  (if (not (zerop (mod width 8)))
      (construct result 1 (construct error-type 0 width))
      (let ((count (/ width 8)) (big (= 1 (tag order))))
        (construct result 0
          (fresh-bytes count
            (lambda (data)
              (loop for i below count
                    for offset = (if big (- count i 1) i)
                    do (setf (aref data i) (ldb (byte 8 (* 8 offset)) value)))))))))
(defun bytes-to-bits (value width order result error-type)
  (let ((data (bytes-value-data value)))
    (if (or (not (zerop (mod width 8))) (/= (length data) (/ width 8)))
        (construct result 1 (construct error-type 0 width (length data)))
        (let ((bits 0) (count (length data)) (big (= 1 (tag order))))
          (loop for byte across data for i from 0
                for offset = (if big (- count i 1) i)
                do (setf bits (logior bits (ash byte (* 8 offset)))))
          (construct result 0 bits)))))
