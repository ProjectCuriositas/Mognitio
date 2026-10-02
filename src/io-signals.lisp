(in-package #:mognitio.io)

;; Linux amd64 rt_sigaction: handler, flags, restorer and 64 signal bits.
;; Use the kernel structure so restoration also preserves a custom restorer;
;; libc's wrapper may synthesize flags/restorer and leaves unused mask storage.
(sb-alien:define-alien-routine ("syscall" raw-rt-sigaction) sb-alien:long
  (number sb-alien:long) (signal sb-alien:long) (action sb-alien:system-area-pointer)
  (old sb-alien:system-area-pointer) (mask-size sb-alien:unsigned-long))
(defun raw-sigaction (signal action old) (raw-rt-sigaction 13 signal action old 8))
(defvar *signal-guard-depth* 0)
(defvar *signal-guard-hook* nil)
(defvar *signal-secondary* nil)
(defstruct signal-state number original replacement installed)

(defun signal-action (state mode)
  (let ((original (signal-state-original state)) (replacement (signal-state-replacement state)))
    (when *signal-guard-hook* (funcall *signal-guard-hook* mode (signal-state-number state)))
    (sb-sys:with-pinned-objects (original replacement)
      (let ((result (ecase mode
                      (:read (raw-sigaction (signal-state-number state) (sb-sys:int-sap 0) (sb-sys:vector-sap original)))
                      (:install (raw-sigaction (signal-state-number state) (sb-sys:vector-sap replacement) (sb-sys:int-sap 0)))
                      (:restore (raw-sigaction (signal-state-number state) (sb-sys:vector-sap original) (sb-sys:int-sap 0))))))
        (unless (zerop result) (mognitio.diagnostics:internal-error "Cannot set or restore I/O signal guard"))
))))


(defun call-with-io-signals (thunk)
  ;; THUNK's second result identifies a primary command/language failure; a
  ;; successful application's nonzero exit is not itself a guard failure.
  (when (plusp *signal-guard-depth*) (return-from call-with-io-signals (funcall thunk)))
  (let* ((*signal-guard-depth* 1)
         (states (loop for number in '(13 25) collect
                   (make-signal-state :number number :original (make-array 32 :element-type '(unsigned-byte 8) :initial-element 0)
                     :replacement (make-array 32 :element-type '(unsigned-byte 8) :initial-element 0))))
         (values nil) (completed nil) (cleanup-failed nil))
    (unwind-protect
         (progn
           (dolist (state states)
             (setf (aref (signal-state-replacement state) 0) 1)
             (signal-action state :read)
             (sb-sys:without-interrupts
               (signal-action state :install) (setf (signal-state-installed state) t)))
           (setf values (multiple-value-list (funcall thunk)) completed t))
      (dolist (state (reverse states))
        (when (signal-state-installed state)
          (handler-case
              (sb-sys:without-interrupts (signal-action state :restore) (setf (signal-state-installed state) nil))
            ((or error storage-condition) (condition) (push condition *signal-secondary*) (setf cleanup-failed t))))))
    (when (and completed cleanup-failed (not (second values)))
      (mognitio.diagnostics:internal-error "Cannot restore I/O signal guard"))
    (values-list values)))
