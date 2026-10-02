(in-package #:mognitio.io)
(declaim (special mognitio.backend.cl::*void-value*))
(declaim (notinline sb-posix:stat sb-posix:open sb-posix:fstat sb-posix:ftruncate sb-posix:close))

(defvar *input* nil)
(defvar *output* nil)
(defvar *error-output-stream* nil)
(defvar *operation-hook* nil)
(defvar *operation-secondary* nil)

(defun retry-syscall (thunk)
  (loop (handler-case (return (funcall thunk))
          (sb-posix:syscall-error (condition)
            (unless (= (sb-posix:syscall-errno condition) sb-posix:eintr) (error condition))))))
(defconstant +o-cloexec+ #x80000)
(define-condition io-failure (error) ((kind :initarg :kind :reader io-failure-kind)))
(defun reject (kind) (error 'io-failure :kind kind))
(defun observe (stage &rest values)
  (when *operation-hook* (apply *operation-hook* stage values)))

(defun errno-kind (number)
  (cond ((member number (list sb-posix:enoent sb-posix:enotdir)) 2)
        ((member number (list sb-posix:eacces sb-posix:eperm sb-posix:erofs)) 3)
        ((= number sb-posix:eisdir) 4)
        ((= number sb-posix:epipe) 5)
        ((member number (list sb-posix:emfile sb-posix:enfile sb-posix:enospc sb-posix:edquot sb-posix:enomem)) 6)
        (t 7)))

(defun read-chunk (fd bytes)
  (sb-sys:with-pinned-objects (bytes)
    (sb-posix:read fd (sb-sys:vector-sap bytes) (length bytes))))
(defun read-all (fd)
  (let ((buffer (make-array 4096 :element-type '(unsigned-byte 8)))
        (state (mognitio.runtime::make-utf8-state))
        (result (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
    (loop for count = (handler-case (progn (observe :read fd) (read-chunk fd buffer))
                       (sb-posix:syscall-error (condition)
                         (if (= (sb-posix:syscall-errno condition) sb-posix:eintr) -1 (error condition)))) do
      (when (zerop count)
        (unless (zerop (mognitio.runtime::utf8-state-pending state)) (reject 1))
        (return result))
      (when (plusp count)
        (unless (mognitio.runtime::utf8-feed state buffer count) (reject 1))
        (when (>= (+ (length result) count) array-dimension-limit)
          (mognitio.runtime:runtime-error :allocation-failed))
        (when (> (+ (length result) count) (array-total-size result))
          (let ((capacity (max 4096 (array-total-size result))))
            (loop while (< capacity (+ (length result) count)) do
              (setf capacity (min (1- array-dimension-limit) (* capacity 2))))
            (setf result (adjust-array result capacity))))
        (dotimes (index count) (vector-push (aref buffer index) result))))))
(defun write-all (fd bytes)
  (let ((offset 0))
    (loop while (< offset (length bytes)) do
      (observe :write fd offset)
      (let ((count (mognitio.runtime::write-chunk fd bytes offset (- (length bytes) offset))))
        (cond ((= count (- sb-posix:eintr)))
              ((plusp count) (incf offset count))
              ((zerop count) (reject 7))
              (t (reject (errno-kind (- count)))))))))

(defun path-native (text)
  (let ((bytes (mognitio.text:text-value-octets text)))
    (when (or (zerop (length bytes)) (find 0 bytes)) (reject 0))
    (sb-ext:octets-to-string bytes :external-format :latin-1)))
(defun require-regular (stat)
  (unless (sb-posix:s-isreg (sb-posix:stat-mode stat)) (reject 4)))

(defun file-operation (operation path text)
  (let* ((sb-alien::*default-c-string-external-format* :latin-1)
         (native (path-native path)) (write-p (eq operation :write-file))
         (fd nil) (primary nil) (data nil))
    ;; The nonblocking metadata/open/fstat sequence rejects known special files
    ;; without waiting on a FIFO or truncating a changed target.
    (unwind-protect
         (handler-case
             (progn
               (handler-case (require-regular (retry-syscall (lambda () (sb-posix:stat native))))
                 (sb-posix:syscall-error (condition)
                   (unless (and write-p (= (sb-posix:syscall-errno condition) sb-posix:enoent)) (error condition))))
               (sb-sys:without-interrupts
                 (setf fd (retry-syscall (lambda () (sb-posix:open native (logior +o-cloexec+ sb-posix:o-nonblock
                                              (if write-p (logior sb-posix:o-wronly sb-posix:o-creat) sb-posix:o-rdonly)) #o666)))))
               (observe :opened fd)
               (require-regular (retry-syscall (lambda () (sb-posix:fstat fd))))
               (if write-p
                   (progn (observe :truncate fd) (retry-syscall (lambda () (sb-posix:ftruncate fd 0)))
                          (write-all fd (mognitio.text:text-value-octets text)))
                   (setf data (read-all fd))))
           ((or error storage-condition) (condition) (setf primary condition)))
      (when fd
        (let ((owned fd))
          (setf fd nil)
          (handler-case
              (sb-sys:without-interrupts (sb-posix:close owned) (observe :close owned))
            ((or error storage-condition) (condition)
              (if primary (push condition *operation-secondary*) (setf primary condition)))))))
    (when primary (error primary))
    data))

(defun stream-operation (operation text)
  (let* ((input-p (eq operation :read-stdin))
         (stream (ecase operation (:read-stdin (or *input* *standard-input*))
                   (:write-stdout (or *output* *standard-output*))
                   (:write-stderr (or *error-output-stream* *error-output*)))))
    (if (typep stream 'sb-sys:fd-stream)
        (if input-p (read-all (sb-sys:fd-stream-fd stream))
            (write-all (sb-sys:fd-stream-fd stream) (mognitio.text:text-value-octets text)))
        ;; The in-memory host adapter exists for embedding and driver tests.
        (if input-p
            (sb-ext:string-to-octets
              (with-output-to-string (out) (loop for char = (read-char stream nil nil) while char do (write-char char out)))
              :external-format :utf-8)
            (progn (write-string (sb-ext:octets-to-string (mognitio.text:text-value-octets text) :external-format :utf-8) stream)
                   (finish-output stream))))))

(defun decoded-text (bytes)
  (let ((count (or (mognitio.runtime::utf8-count bytes) (reject 1))))
    (if (zerop count) mognitio.text::*empty*
        (mognitio.text::allocate-text (length bytes) count (lambda (out) (replace out bytes))))))

(defun invoke (operation arguments result-type error-type operation-type kind-type &optional entry-type entry-kind)
  (when (member operation '(:join-path :read-directory :create-directory))
    (return-from invoke (invoke-directory operation arguments result-type error-type operation-type kind-type entry-type entry-kind)))
  (handler-case
      (let* ((*operation-secondary* nil) (number (position operation '(:read-file :write-file :read-stdin :write-stdout :write-stderr)))
             (subject (if (< number 2) (first arguments)
                          (let* ((name (nth (- number 2) '("stdin" "stdout" "stderr")))
                                 (bytes (sb-ext:string-to-octets name :external-format :utf-8)))
                            (mognitio.text::%make-text-value bytes (length name)))))
             (failure nil) (value mognitio.backend.cl::*void-value*))
        (handler-case
            (let ((bytes (if (< number 2) (file-operation operation subject (second arguments))
                             (stream-operation operation (first arguments)))))
              (when (member operation '(:read-file :read-stdin)) (setf value (decoded-text bytes))))
          (io-failure (condition) (setf failure (io-failure-kind condition)))
          (sb-posix:syscall-error (condition) (setf failure (errno-kind (sb-posix:syscall-errno condition))))
          (stream-error () (setf failure 7)))
        ;; All owned OS resources are gone before managed error/result allocation.
        (if failure
            (mognitio.value:construct result-type 1
              (mognitio.value:construct error-type 0
                (mognitio.value:construct operation-type number)
                (mognitio.value:construct kind-type failure) subject))
            (mognitio.value:construct result-type 0 value)))
    (storage-condition () (mognitio.runtime:runtime-error :allocation-failed))))
