(in-package #:mognitio.runtime)

;; Inclusive lead range, continuation count, minimum scalar and payload mask.
;; Host and native generators share this closed table, not a locale codec.
(defparameter *utf8-leads* '((194 223 1 128 31) (224 239 2 2048 15) (240 244 3 65536 7)))
(defstruct utf8-state (pending 0) (scalar 0) (minimum 0) (count 0))

(defun utf8-feed (state bytes &optional (end (length bytes)))
  (dotimes (index end t)
    (let ((byte (aref bytes index)))
      (cond
        ((plusp (utf8-state-pending state))
         (unless (<= 128 byte 191) (return-from utf8-feed nil))
         (setf (utf8-state-scalar state) (+ (* 64 (utf8-state-scalar state)) (- byte 128)))
         (when (zerop (decf (utf8-state-pending state)))
           (let ((scalar (utf8-state-scalar state)))
             (unless (and (<= (utf8-state-minimum state) scalar #x10ffff)
                          (not (<= #xd800 scalar #xdfff))) (return-from utf8-feed nil)))
           (when (= (utf8-state-count state) mognitio.integer:+maximum+) (runtime-error :string-size-overflow))
           (incf (utf8-state-count state))))
        ((< byte 128)
         (when (= (utf8-state-count state) mognitio.integer:+maximum+) (runtime-error :string-size-overflow))
         (incf (utf8-state-count state)))
        (t
         (let ((row (find-if (lambda (row) (<= (first row) byte (second row))) *utf8-leads*)))
           (unless row (return-from utf8-feed nil))
           (setf (utf8-state-pending state) (third row) (utf8-state-minimum state) (fourth row)
                 (utf8-state-scalar state) (logand byte (fifth row)))))))))

(defun utf8-count (bytes)
  (let ((state (make-utf8-state)))
    (when (and (utf8-feed state bytes) (zerop (utf8-state-pending state))) (utf8-state-count state))))
