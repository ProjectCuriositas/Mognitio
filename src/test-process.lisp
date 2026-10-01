(in-package #:mognitio.testing)

;; Linux/AMD64 glibc ABI: posix_spawn_file_actions_t is 80 bytes, alignment 8.
;; No Lisp continuation exists in the child. glibc owns failed pre-exec children.
(sb-alien:define-alien-routine ("posix_spawn" raw-spawn) sb-alien:int
  (pid sb-alien:system-area-pointer) (path sb-alien:system-area-pointer)
  (actions sb-alien:system-area-pointer) (attributes sb-alien:system-area-pointer)
  (argv sb-alien:system-area-pointer) (envp sb-alien:system-area-pointer))
(sb-alien:define-alien-routine ("posix_spawn_file_actions_init" actions-init) sb-alien:int
  (actions sb-alien:system-area-pointer))
(sb-alien:define-alien-routine ("posix_spawn_file_actions_destroy" actions-destroy) sb-alien:int
  (actions sb-alien:system-area-pointer))
(sb-alien:define-alien-routine ("posix_spawn_file_actions_adddup2" actions-dup) sb-alien:int
  (actions sb-alien:system-area-pointer) (source sb-alien:int) (target sb-alien:int))
(sb-alien:define-alien-routine ("posix_spawn_file_actions_addopen" actions-open) sb-alien:int
  (actions sb-alien:system-area-pointer) (fd sb-alien:int) (path sb-alien:c-string)
  (flags sb-alien:int) (mode sb-alien:unsigned-int))
(sb-alien:define-alien-routine ("posix_spawn_file_actions_addclosefrom_np" actions-closefrom) sb-alien:int
  (actions sb-alien:system-area-pointer) (fd sb-alien:int))
(sb-alien:define-alien-routine ("pipe2" raw-pipe) sb-alien:int
  (fds sb-alien:system-area-pointer) (flags sb-alien:int))
(sb-alien:define-alien-routine ("fcntl" raw-fcntl) sb-alien:int
  (fd sb-alien:int) (command sb-alien:int) (value sb-alien:int))
(sb-alien:define-alien-routine ("close" raw-close) sb-alien:int (fd sb-alien:int))
(sb-alien:define-alien-routine ("read" raw-read) sb-alien:long
  (fd sb-alien:int) (buffer sb-alien:system-area-pointer) (count sb-alien:unsigned-long))
(sb-alien:define-alien-routine ("write" raw-write) sb-alien:long
  (fd sb-alien:int) (buffer sb-alien:system-area-pointer) (count sb-alien:unsigned-long))
(sb-alien:define-alien-routine ("__errno_location" errno-pointer) sb-alien:system-area-pointer)
(sb-alien:define-alien-routine ("waitpid" raw-wait) sb-alien:int
  (pid sb-alien:int) (status sb-alien:system-area-pointer) (flags sb-alien:int))
(sb-alien:define-alien-routine ("kill" raw-kill) sb-alien:int (pid sb-alien:int) (signal sb-alien:int))
(sb-alien:define-alien-routine ("poll" raw-poll) sb-alien:int
  (fds sb-alien:system-area-pointer) (count sb-alien:unsigned-long) (timeout sb-alien:int))

(defstruct attempt-resources (pid 0) (process-state :absent) status execution-delegated
  (fds (make-array 8 :element-type 'fixnum :initial-element -1))
  (gate-byte (make-array 1 :element-type '(unsigned-byte 8) :initial-element 1)))
(defvar *runner-hook* nil)
(defun runner-hook (point &optional object) (when *runner-hook* (funcall *runner-hook* point object)))
(defun runner-io (message) (fail 'usage-or-io-failure nil message))
(defun check-action (code) (unless (zerop code) (runner-io "Test process preparation failed")))

(defun close-owned-fd (attempt index)
  (let ((fds (attempt-resources-fds attempt)) (result 0))
    (sb-sys:without-interrupts
      (when (>= (aref fds index) 0)
        (setf result (raw-close (aref fds index)) (aref fds index) -1)))
    ;; Linux releases the descriptor even on EINTR. Never retry a reused number.
    (unless (zerop result) (runner-io "Cannot close test process descriptor"))))

(defun acquire-pipe (attempt index)
  (sb-alien:with-alien ((pair (array sb-alien:int 2)))
    (let ((sap (sb-alien:alien-sap (sb-alien:addr pair))) (result -1)
          (fds (attempt-resources-fds attempt)))
      (sb-sys:without-interrupts
        (setf result (raw-pipe sap #x80000))
        (when (zerop result)
          (setf (aref fds index) (sb-alien:deref pair 0)
                (aref fds (1+ index)) (sb-alien:deref pair 1))))
      (unless (zerop result) (runner-io "Cannot create test process pipe"))
      ;; Sources are above every fixed child destination, making dup ordering safe.
      (loop for i from index below (+ index 2) do
        (let ((copy -1) (closed 0))
          (sb-sys:without-interrupts
            (setf copy (raw-fcntl (aref fds i) 1030 10)) ; F_DUPFD_CLOEXEC
            (when (>= copy 0)
              (setf closed (raw-close (aref fds i)) (aref fds i) copy)))
          (when (or (minusp copy) (minusp closed)) (runner-io "Cannot relocate test pipe")))))))

(defun spawn-attempt (attempt path)
  (dotimes (n 4) (acquire-pipe attempt (* 2 n))) ; stdout, stderr, event, gate
  (let ((fds (attempt-resources-fds attempt)))
    (dolist (i '(0 2 4 7))
      (when (minusp (raw-fcntl (aref fds i) sb-posix:f-setfl sb-posix:o-nonblock))
        (runner-io "Cannot configure test pipe")))
    (sb-alien:with-alien ((actions (array sb-alien:unsigned-long 10))
                         (argv (array sb-alien:unsigned-long 2))
                         (envp sb-alien:unsigned-long 0) (pid sb-alien:int 0))
      (let ((a (sb-alien:alien-sap (sb-alien:addr actions)))
            (av (sb-alien:alien-sap (sb-alien:addr argv)))
            (ev (sb-alien:alien-sap (sb-alien:addr envp)))
            (pp (sb-alien:alien-sap (sb-alien:addr pid)))
            (name (sb-ext:string-to-octets path :external-format :utf-8 :null-terminate t)))
        (check-action (actions-init a))
        (unwind-protect
             (progn
               (check-action (actions-open a 0 "/dev/null" sb-posix:o-rdonly 0))
               (loop for source in '(1 3 5 6) for target from 1 do
                 (check-action (actions-dup a (aref fds source) target)))
               (check-action (actions-closefrom a 5))
               (runner-hook :before-spawn attempt)
               (sb-sys:with-pinned-objects (name)
                 (let ((np (sb-sys:vector-sap name)) (result -1))
                   (setf (sb-sys:sap-ref-sap av 0) np
                         (sb-sys:sap-ref-sap av 8) (sb-sys:int-sap 0))
                   (sb-sys:without-interrupts
                     (setf result (raw-spawn pp np a (sb-sys:int-sap 0) av ev))
                     (when (zerop result)
                       (setf (attempt-resources-pid attempt) pid
                             (attempt-resources-process-state attempt) :owned-unreaped)))
                   (unless (zerop result) (runner-io "Cannot execute test image")))))
          (actions-destroy a))))
    (runner-hook :after-spawn attempt)
    (dolist (i '(1 3 5 6)) (close-owned-fd attempt i))))

(defun delegate-start (attempt)
  (when (attempt-resources-execution-delegated attempt) (return-from delegate-start t))
  (let ((byte (attempt-resources-gate-byte attempt))
        (fd (aref (attempt-resources-fds attempt) 7)) (ep (errno-pointer)) (result 0) (errno 0))
    (sb-sys:with-pinned-objects (byte)
      (let ((sap (sb-sys:vector-sap byte)))
        ;; The successful write and the preallocated slot store form one commit.
        ;; There is no callback, allocation, wrapper condition or wait in this region.
        (sb-sys:without-interrupts
          (setf result (raw-write fd sap 1))
          (if (= result 1)
              (setf (attempt-resources-execution-delegated attempt) t)
              (setf errno (sb-sys:sap-ref-32 ep 0))))))
    (cond ((= result 1) (runner-hook :after-delegation attempt) t)
          ((and (= result -1) (member errno (list sb-posix:eintr sb-posix:eagain))) nil)
          (t (runner-io "Cannot delegate test execution")))))

(defun collect-wait (attempt &optional blocking)
  (when (eq (attempt-resources-process-state attempt) :owned-unreaped)
    (sb-alien:with-alien ((status sb-alien:int 0))
      (let ((sap (sb-alien:alien-sap (sb-alien:addr status))) (result 0) (errno 0) (ep (errno-pointer)))
        (sb-sys:without-interrupts
          (setf result (raw-wait (attempt-resources-pid attempt) sap (if blocking 0 sb-posix:wnohang)))
          (cond ((plusp result) (setf (attempt-resources-status attempt) status
                                     (attempt-resources-process-state attempt) :reaped))
                ((minusp result) (setf errno (sb-sys:sap-ref-32 ep 0)))))
        (when (and (minusp result) (/= errno sb-posix:eintr)) (runner-io "Cannot reap test process"))
        (when (plusp result) (runner-hook :after-reap attempt)))))
  (eq (attempt-resources-process-state attempt) :reaped))

(defun finalize-attempt (attempt)
  (let ((failure nil))
    (flet ((protect (thunk) (handler-case (funcall thunk)
                            ((or error storage-condition) (c) (unless failure (setf failure c))))))
      (protect (lambda ()
        (collect-wait attempt)
        (when (eq (attempt-resources-process-state attempt) :owned-unreaped)
          (when (minusp (raw-kill (attempt-resources-pid attempt) sb-posix:sigkill))
            (unless (= (sb-sys:sap-ref-32 (errno-pointer) 0) sb-posix:esrch)
              (runner-io "Cannot stop test process")))
          (loop repeat 16 until (collect-wait attempt t))
          (unless (eq (attempt-resources-process-state attempt) :reaped) (runner-io "Test process reap is unconfirmed")))))
      (dotimes (i 8) (protect (lambda () (close-owned-fd attempt i)))))
    (when failure (error failure))))

(sb-alien:define-alien-routine ("signal" raw-signal) sb-alien:unsigned-long
  (signal sb-alien:int) (handler sb-alien:unsigned-long))
