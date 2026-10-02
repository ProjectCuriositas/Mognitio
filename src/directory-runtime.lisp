(in-package #:mognitio.io)

;; Raw Linux names never pass through the host pathname or locale decoder.
(sb-alien:define-alien-routine ("openat" directory-openat) sb-alien:int
  (fd sb-alien:int) (path sb-alien:system-area-pointer) (flags sb-alien:int) (mode sb-alien:int))
(sb-alien:define-alien-routine ("fstatat" directory-fstatat) sb-alien:int
  (fd sb-alien:int) (path sb-alien:system-area-pointer) (stat sb-alien:system-area-pointer) (flags sb-alien:int))
(sb-alien:define-alien-routine ("mkdirat" directory-mkdirat) sb-alien:int
  (fd sb-alien:int) (path sb-alien:system-area-pointer) (mode sb-alien:unsigned-int))
(sb-alien:define-alien-routine ("getdents64" directory-getdents) sb-alien:long
  (fd sb-alien:int) (buffer sb-alien:system-area-pointer) (count sb-alien:unsigned-long))
(sb-alien:define-alien-routine ("close" directory-close) sb-alien:int (fd sb-alien:int))
(sb-alien:define-alien-routine ("__errno_location" directory-errno) sb-alien:system-area-pointer)

(defvar *directory-fault-hook* nil)
(defvar *directory-length-limit* mognitio.integer:+maximum+)
(define-condition directory-failure (io-failure)
  ((child :initarg :child :initform nil :accessor directory-failure-child)
   (subject :initarg :subject :initform nil :reader directory-failure-subject)))
(defun directory-internal () (mognitio.diagnostics:internal-error "Invalid directory runtime state"))
(defun directory-reject (kind &key child subject)
  (error 'directory-failure :kind kind :child child :subject subject))
(defun directory-errno-kind (number)
  (cond ((= number 36) 0) ((= number 2) 2)
        ((member number '(13 1 30)) 3) ((member number '(20 21)) 4)
        ((member number '(24 23 28 122 12 31)) 6) (t 7)))
(defun directory-check-status (phase status)
  (unless (and (integerp status) (>= status -4095)
               (or (minusp status) (member phase '(:open :scan)) (zerop status)))
    (directory-internal))
  (when (and (minusp status)
             (member (- status)
               (case phase (:scan '(9 20 14 22)) (:child-stat '(9 20 14 22))
                 ((:root-stat :create-stat) '(9 14 22)) ((:open :mkdir) '(9 14))
                 (:close '(9)) (otherwise (directory-internal)))))
    (directory-internal))
  status)
(defun directory-call (phase thunk &optional close-p)
  ;; Injection precedes an acquisition. Close injection follows the real close,
  ;; so a synthetic error cannot silently leak an unregistered descriptor.
  (loop
    (let* ((injected (and (not close-p) *directory-fault-hook* (funcall *directory-fault-hook* phase)))
           (raw (if injected injected
                    (let ((result (funcall thunk)))
                      (if (minusp result) (- (sb-sys:sap-ref-32 (directory-errno) 0)) result))))
           (status (if (and close-p *directory-fault-hook*)
                       (or (funcall *directory-fault-hook* phase) raw) raw)))
      (directory-check-status phase status)
      (unless (and (= status -4) (not close-p)) (return status)))))
(defun directory-result (status)
  (when (minusp status) (directory-reject (directory-errno-kind (- status))))
  status)
(defun directory-path-bytes (text)
  (let ((bytes (mognitio.text:text-value-octets text)))
    (when (or (zerop (length bytes)) (find 0 bytes)) (directory-reject 0 :subject text))
    (let ((path (make-array (1+ (length bytes)) :element-type '(unsigned-byte 8) :initial-element 0)))
      (replace path bytes) path)))
(defun directory-stat (path fd flags phase &optional (offset 0))
  (let ((stat (make-array 144 :element-type '(unsigned-byte 8) :initial-element 0)))
    (sb-sys:with-pinned-objects (path stat)
      (let ((status (directory-call phase
                      (lambda () (directory-fstatat fd (sb-sys:sap+ (sb-sys:vector-sap path) offset)
                                                   (sb-sys:vector-sap stat) flags)))))
        (if (minusp status) status (logand #o170000 (sb-sys:sap-ref-32 (sb-sys:vector-sap stat) 24)))))))

(defun join-directory-path (base relative)
  (let ((left (mognitio.text:text-value-octets base)) (right (mognitio.text:text-value-octets relative)))
    (when (or (zerop (length left)) (find 0 left)) (directory-reject 0 :subject base))
    (when (or (zerop (length right)) (find 0 right) (= (aref right 0) 47))
      (directory-reject 0 :subject relative))
    (let* ((separator (if (= (aref left (1- (length left))) 47) 0 1))
           (bytes (+ (length left) separator (length right)))
           (scalars (+ (mognitio.text:text-length base) separator (mognitio.text:text-length relative))))
      (when (> scalars *directory-length-limit*) (mognitio.runtime:runtime-error :string-size-overflow))
      (when (>= bytes array-dimension-limit) (mognitio.runtime:runtime-error :allocation-failed))
      (mognitio.text::allocate-text bytes scalars
        (lambda (out)
          (replace out left)
          (when (plusp separator) (setf (aref out (length left)) 47))
          (replace out right :start1 (+ (length left) separator)))))))

(defun create-directory-value (text)
  (let* ((path (directory-path-bytes text)) (mode (directory-stat path -100 0 :create-stat)))
    (cond ((= mode #o040000))
          ((>= mode 0) (directory-reject 4))
          ((/= mode -2) (directory-result mode))
          (t
           (let ((status (sb-sys:with-pinned-objects (path)
                           (directory-call :mkdir (lambda () (directory-mkdirat -100 (sb-sys:vector-sap path) #o777))))))
             (cond ((zerop status))
                   ((= status -17)
                    (let ((found (directory-stat path -100 0 :create-stat)))
                      (when (and (= found -2) (/= (aref path (- (length path) 2)) 47))
                        (setf found (directory-stat path -100 #x100 :create-stat)))
                      (cond ((= found #o040000)) ((>= found 0) (directory-reject 4))
                            (t (directory-result found)))))
                   (t (directory-result status)))))))
  mognitio.backend.cl::*void-value*)

(defun directory-row-before-p (a b arena)
  (loop for i below (min (aref a 1) (aref b 1))
        for x = (aref arena (+ (aref a 0) i)) for y = (aref arena (+ (aref b 0) i)) do
    (when (/= x y) (return-from directory-row-before-p (< x y))))
  (if (/= (aref a 1) (aref b 1)) (< (aref a 1) (aref b 1)) (< (aref a 4) (aref b 4))))
(defun directory-heapsort (rows arena)
  (labels ((sift (start end)
             (loop with parent = start for child = (1+ (* 2 parent)) while (< child end) do
               (when (and (< (1+ child) end)
                          (directory-row-before-p (aref rows child) (aref rows (1+ child)) arena)) (incf child))
               (unless (directory-row-before-p (aref rows parent) (aref rows child) arena) (return))
               (rotatef (aref rows parent) (aref rows child)) (setf parent child))))
    (loop for i downfrom (1- (floor (length rows) 2)) to 0 do (sift i (length rows)))
    (loop for end downfrom (1- (length rows)) above 0 do
      (rotatef (aref rows 0) (aref rows end)) (sift 0 end)))
  rows)

(defun scan-directory (text)
  (let* ((path (directory-path-bytes text))
         (scan (make-array 65536 :element-type '(unsigned-byte 8)))
         (arena (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0))
         (rows (make-array 0 :adjustable t :fill-pointer 0)) (fd nil) (primary nil))
    (unwind-protect
         (handler-case
             (progn
               (sb-sys:without-interrupts
                 (setf fd (sb-sys:with-pinned-objects (path)
                            (directory-result (directory-call :open
                              (lambda () (directory-openat -100 (sb-sys:vector-sap path) #x90000 0)))))))
               (observe :directory-opened fd)
               (loop for count = (sb-sys:with-pinned-objects (scan)
                                   (directory-result (directory-call :scan
                                     (lambda () (directory-getdents fd (sb-sys:vector-sap scan) 65536))))) do
                 (when (zerop count) (return))
                 (unless (<= 1 count 65536) (directory-internal))
                 (loop with offset = 0 while (< offset count) do
                   (unless (<= (+ offset 20) count) (directory-internal))
                   (let* ((size (+ (aref scan (+ offset 16)) (* 256 (aref scan (+ offset 17)))))
                          (end (+ offset size)) (name-start (+ offset 19)))
                     (unless (and (>= size 24) (zerop (mod size 8)) (<= end count)) (directory-internal))
                     (let ((nul (position 0 scan :start name-start :end end)))
                       (unless (and nul (> nul name-start)) (directory-internal))
                       (let* ((bytes (subseq scan name-start nul)) (scalar (mognitio.runtime::utf8-count bytes)))
                         (unless scalar (directory-reject 1))
                         (when (find 47 bytes) (directory-internal))
                         (unless (or (equalp bytes #(46)) (equalp bytes #(46 46)))
                           (let ((start (length arena)))
                             (loop for byte across bytes do (vector-push-extend byte arena))
                             (handler-case
                                 (let* ((mode (directory-result (directory-stat scan fd #x100 :child-stat name-start)))
                                        (kind (case mode (#o100000 0) (#o040000 1) (#o120000 2) (otherwise 3))))
                                   (vector-push-extend (vector start (length bytes) scalar kind (length rows)) rows))
                               (directory-failure (condition)
                                 (setf (directory-failure-child condition) bytes) (error condition)))))))
                     (setf offset end)))))
           ((or error storage-condition) (condition) (setf primary condition)))
      (when fd
        (let ((owned fd))
          (setf fd nil)
          (handler-case
              (sb-sys:without-interrupts
                (directory-result (directory-call :close (lambda () (directory-close owned)) t))
                (observe :directory-closed owned))
            ((or error storage-condition) (condition)
              (cond ((null primary) (setf primary condition))
                    ((and (typep condition 'mognitio.diagnostics:internal-failure)
                          (not (typep primary 'mognitio.runtime:program-runtime-failure)))
                     (setf primary condition))
                    (t (push condition *operation-secondary*))))))))
    (when primary (error primary))
    (values (directory-heapsort rows arena) arena)))

(defun read-directory-value (text entry-type entry-kind)
  (multiple-value-bind (rows arena) (scan-directory text)
    (let ((result mognitio.value::*empty-list*) (previous nil))
      (loop for row across rows for bytes = (subseq arena (aref row 0) (+ (aref row 0) (aref row 1))) do
        (unless (equalp bytes previous)
          (when (= (mognitio.value::list-value-length result) *directory-length-limit*)
            (mognitio.runtime:runtime-error :list-length-overflow))
          (let* ((name (decoded-text bytes)) (kind (mognitio.value:construct entry-kind (aref row 3)))
                 (entry (mognitio.value:construct entry-type 0 name kind)))
            (setf result (mognitio.value::list-append-value result entry))))
        (setf previous bytes))
      result)))

(defun invoke-directory (operation arguments result-type error-type operation-type kind-type entry-type entry-kind)
  (handler-case
      (let ((number (ecase operation (:join-path 5) (:read-directory 6) (:create-directory 7)))
            (*operation-secondary* nil) (subject (first arguments)) (failure nil) (value nil))
        (handler-case
            (setf value (ecase operation
                          (:join-path (join-directory-path (first arguments) (second arguments)))
                          (:read-directory (read-directory-value subject entry-type entry-kind))
                          (:create-directory (create-directory-value subject))))
          (directory-failure (condition)
            (setf failure (io-failure-kind condition))
            (cond ((directory-failure-subject condition) (setf subject (directory-failure-subject condition)))
                  ((directory-failure-child condition)
                   (setf subject (join-directory-path subject (decoded-text (directory-failure-child condition))))))))
        (if failure
            (mognitio.value:construct result-type 1
              (mognitio.value:construct error-type 0 (mognitio.value:construct operation-type number)
                                      (mognitio.value:construct kind-type failure) subject))
            (mognitio.value:construct result-type 0 value)))
    (storage-condition () (mognitio.runtime:runtime-error :allocation-failed))))
