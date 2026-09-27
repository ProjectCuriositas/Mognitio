(in-package #:mognitio.artifact)

(defun io-failure (path)
  (fail 'usage-or-io-failure nil "File I/O failed" :path path))

(defun call-with-io-errors (path thunk)
  (handler-case (funcall thunk)
    (sb-posix:syscall-error () (io-failure path))
    (file-error () (io-failure path))
    (stream-error () (io-failure path))))

(defun native-path (path)
  (when (or (zerop (length path)) (find #\Null path))
    (io-failure path))
  (sb-ext:native-namestring
   (merge-pathnames (sb-ext:parse-native-namestring path))))

(defun existing-stat (path)
  (handler-case (sb-posix:lstat path)
    (sb-posix:syscall-error (condition)
      (unless (= (sb-posix:syscall-errno condition) sb-posix:enoent)
        (error condition)))))

(defun validated-source-stat (source)
  (call-with-io-errors
   source
   (lambda ()
     (let ((stat (sb-posix:stat (native-path source))))
       (unless (sb-posix:s-isreg (sb-posix:stat-mode stat))
         (io-failure source))
       stat))))

(defun validate-paths (source output)
  (let ((input-stat (validated-source-stat source)))
    (call-with-io-errors
     output
     (lambda ()
       (let* ((output-path (native-path output))
              (output-stat (existing-stat output-path))
              (parent (sb-ext:native-namestring
                       (uiop:pathname-directory-pathname
                        (sb-ext:parse-native-namestring output-path))))
              (parent-stat (sb-posix:stat parent)))
         (unless (sb-posix:s-isdir (sb-posix:stat-mode parent-stat))
           (io-failure output))
         (when output-stat
           (unless (sb-posix:s-isreg (sb-posix:stat-mode output-stat))
             (io-failure output))
           (when (and (= (sb-posix:stat-dev input-stat) (sb-posix:stat-dev output-stat))
                      (= (sb-posix:stat-ino input-stat) (sb-posix:stat-ino output-stat)))
             (fail 'usage-or-io-failure nil "Source and output refer to the same file"
                   :path output)))
         (values output-path parent))))))

;; Narrow operations provide fault-injection seams without adding CLI switches.
(defun write-image (image stream) (write-sequence image stream))
(defun flush-image (stream) (finish-output stream))
(defun set-executable (fd) (sb-posix:fchmod fd #o700))
(defun close-image (stream) (close stream))
(defun replace-image (temporary output) (sb-posix:rename temporary output))

(defun verify-image (image temporary)
  (with-open-file (stream temporary :direction :input :element-type '(unsigned-byte 8))
    (unless (= (length image) (file-length stream)) (io-failure temporary))
    (loop for expected across image for observed = (read-byte stream nil nil)
          unless (eql expected observed) do (io-failure temporary))))
(defun commit-image (temporary output)
  (handler-case (replace-image temporary output)
    (sb-posix:syscall-error (condition)
      (if (= (sb-posix:syscall-errno condition) sb-posix:eio)
          (fail 'usage-or-io-failure nil "File I/O failed; replacement outcome is unknown" :path output)
          (error condition)))))

(defun publish-image (image source output)
  (unless (and (typep image '(vector (unsigned-byte 8))) (plusp (length image)))
    (internal-error "Cannot publish an empty or invalid image"))
  (call-with-io-errors
   output
   (lambda ()
     ;; Recheck immediately before publication preparation as well as before compilation.
     (multiple-value-bind (destination parent) (validate-paths source output)
       (let ((fd nil) (temporary nil) (stream nil) (published nil))
         (unwind-protect
              (progn
                (multiple-value-setq (fd temporary)
                  (sb-posix:mkstemp (concatenate 'string parent ".mgn-build-XXXXXX")))
                (setf stream (sb-sys:make-fd-stream fd :output t
                                                     :element-type '(unsigned-byte 8)))
                (write-image image stream)
                (flush-image stream)
                (set-executable fd)
                (close-image stream)
                (setf stream nil fd nil)
                (verify-image image temporary)
                (commit-image temporary destination)
                (setf published t))
           ;; Preserve the original failure if cleanup itself also fails.
           (when stream (ignore-errors (close stream :abort t)))
           (when (and fd (null stream)) (ignore-errors (sb-posix:close fd)))
           (when (and temporary (not published))
             (ignore-errors (sb-posix:unlink temporary)))))))))
