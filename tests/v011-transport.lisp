(in-package #:mognitio.tests)

(defun v11-record (tag ordinal sequence stage kind &optional (site #xffffffffffffffff))
  ;; Independent encoder with literal protocol values, not production enum tables.
  (let ((bytes (make-array 40 :element-type '(unsigned-byte 8) :initial-element 0)))
    (loop for (offset width value) in (list '(0 4 #x544e474d) '(4 2 1) (list 6 2 tag)
                  (list 8 8 ordinal) (list 16 8 sequence) (list 24 4 stage) (list 28 4 kind) (list 32 8 site)) do
      (dotimes (n width) (setf (aref bytes (+ offset n)) (ldb (byte 8 (* 8 n)) value)))) bytes))
(defun v11-feed (reader record)
  (mognitio.testing::feed-events reader record (length record)))

(deftest v011-native-broken-event-channel
  (let* ((plan (v11-plan (v11-manifest "unit" 1)))
         (test (aref (mognitio.testing::test-plan-cases plan) 0))
         (session (mognitio.testing::make-preparation-session :cases (vector test)))
         (attempt (mognitio.testing::make-attempt-resources))
         (bytes (make-array 40 :element-type '(unsigned-byte 8)))
         (before (v11-fd-snapshot)))
    (unwind-protect
         (progn
           (mognitio.testing::prepare-suite session plan)
           (mognitio.testing::spawn-attempt attempt (mognitio.testing::test-case-path test))
           (let ((received 0))
             (loop repeat 1000 until (= received 40) do
               (sb-sys:with-pinned-objects (bytes)
                 (let ((n (mognitio.testing::raw-read (aref (mognitio.testing::attempt-resources-fds attempt) 4)
                              (sb-sys:sap+ (sb-sys:vector-sap bytes) received) (- 40 received))))
                   (when (plusp n) (incf received n))))
               (unless (= received 40) (sleep 0.002)))
             (same 40 received) (same (v11-record 1 0 0 0 0) bytes))
           (mognitio.testing::close-owned-fd attempt 4)
           (is (mognitio.testing::delegate-start attempt))
           (loop repeat 1000 until (mognitio.testing::collect-wait attempt) do (sleep 0.002))
           (same :reaped (mognitio.testing::attempt-resources-process-state attempt))
           (same (* 124 256) (mognitio.testing::attempt-resources-status attempt)))
      (mognitio.testing::finalize-attempt attempt)
      (same nil (mognitio.testing::cleanup-preparation session)))
    (same before (v11-fd-snapshot))))

(deftest v011-protocol-independent-fixtures
  (same #(77 71 78 84 1 0 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
          255 255 255 255 255 255 255 255) (v11-record 1 0 0 0 0))
  (dolist (chunk '(1 3 17 40))
    (let ((reader (mognitio.testing::make-event-reader :ordinal 0 :site-count 1)))
      (dolist (record (list (v11-record 1 0 0 0 0) (v11-record 2 0 1 1 0)
                            (v11-record 2 0 2 2 0) (v11-record 3 0 3 2 1 0)))
        (loop for start from 0 below 40 by chunk do (v11-feed reader (subseq record start (min 40 (+ start chunk))))))
      (same '(1 . 0) (mognitio.testing::event-reader-terminal reader))
      (same 0 (mognitio.testing::event-reader-used reader))))
  (dolist (record (list (v11-record 1 1 0 0 0) (v11-record 1 0 2 0 0)
                        (v11-record 1 0 0 1 0) (v11-record 9 0 0 0 0)))
    (signals internal-failure (v11-feed (mognitio.testing::make-event-reader :ordinal 0 :site-count 1) record)))
  (dolist (record (list (v11-record 2 0 2 1 0) (v11-record 3 0 2 1 0)
                        (v11-record 3 0 2 1 1 99) (v11-record 3 0 2 1 42)))
    (let ((reader (mognitio.testing::make-event-reader :ordinal 0 :site-count 1)))
      (v11-feed reader (v11-record 1 0 0 0 0)) (v11-feed reader (v11-record 2 0 1 1 0))
      (signals internal-failure (v11-feed reader record))))
  (dolist (case '((0 nil 0 :abnormal) (9 t 0 :abnormal) (1280 t 0 :assertion)
                  (0 t 0 :internal) (31744 nil 0 :io) (0 nil 7 :abnormal)))
    (destructuring-bind (status terminal partial expected) case
      (let ((attempt (mognitio.testing::make-attempt-resources :process-state :reaped :status status))
            (test (mognitio.testing::make-test-case :state :running :sites (vector (make-span (text-source "assert false;") 0 13))))
            (reader (mognitio.testing::make-event-reader :ordinal 0 :eof t :used partial :terminal (when terminal '(1 . 0)))))
        (case expected
          (:internal (signals internal-failure (mognitio.testing::commit-result attempt reader test)))
          (:io (signals usage-or-io-failure (mognitio.testing::commit-result attempt reader test)))
          (t (mognitio.testing::commit-result attempt reader test) (same expected (mognitio.testing::test-case-kind test)))))))
  (let ((observed (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0))
        (original (fdefinition 'mognitio.testing::feed-events)))
    (replacing (mognitio.testing::feed-events (lambda (reader bytes count)
                 (dotimes (n count) (vector-push-extend (aref bytes n) observed))
                 (funcall original reader bytes count)))
      (multiple-value-bind (out err code) (v11-driver (v11-manifest "assert true;" 1))
        (declare (ignore out)) (same 0 code) (same "" err)))
    (same (concatenate 'vector (v11-record 1 0 0 0 0) (v11-record 2 0 1 1 0)
                                (v11-record 2 0 2 2 0) (v11-record 3 0 3 2 0)) observed)))

(sb-alien:define-alien-routine ("posix_spawn_file_actions_addclose" v11-addclose) sb-alien:int
  (actions sb-alien:system-area-pointer) (fd sb-alien:int))

(deftest v011-pre-exec-failure-boundary
  ;; D11-R04/R08: fd action/exec failures run inside glibc, not Lisp child code.
  (dolist (fault '(:dup :close :exec :pipe))
    (let ((before (v11-fd-snapshot)) (attempt nil) (image nil)
          (original-dup (fdefinition 'mognitio.testing::actions-dup)))
      (labels ((run ()
                 (multiple-value-bind (out err code)
                     (v11-driver (v11-manifest) (lambda (point object)
                       (when (eq point :image-created) (unless image (setf image (mognitio.testing::test-case-path object))))
                       (when (eq point :before-spawn)
                         (setf attempt object)
                         (when (eq fault :exec) (sb-posix:chmod image #o600)))))
                   (same 2 code) (same "" out) (is (not (search "tests:" err))))))
        (ecase fault
          (:dup (replacing (mognitio.testing::actions-dup
                   (lambda (a source target) (declare (ignore source)) (funcall original-dup a 99999 target))) (run)))
          (:close (replacing (mognitio.testing::actions-closefrom
                     (lambda (a fd) (declare (ignore fd)) (v11-addclose a 2147483647))) (run)))
          (:exec (run))
          (:pipe (replacing (mognitio.testing::raw-pipe (lambda (&rest args) (declare (ignore args)) -1)) (run)))))
      (when attempt (v11-assert-released attempt)
        (same :absent (mognitio.testing::attempt-resources-process-state attempt)))
      (same before (v11-fd-snapshot)))))

(deftest v011-start-delegation-commit
  ;; D11-R09: positive, unsent, retry and deferred asynchronous interruption.
  (dolist (mode '(:success :epipe :eintr-stop :eintr-success :deferred-interrupt))
    (let ((attempt nil) (writes 0) (successes 0) (unsent nil) (before (v11-fd-snapshot))
          (original (fdefinition 'mognitio.testing::raw-write))
          (ep (mognitio.testing::errno-pointer)))
      (flet ((interrupt ()
               (is (mognitio.testing::attempt-resources-execution-delegated attempt))
               (internal-error "Deferred start interruption")))
        (replacing (mognitio.testing::raw-write
          (lambda (fd sap count)
            (incf writes)
            (cond
              ((eq mode :epipe) (setf (sb-sys:sap-ref-32 ep 0) sb-posix:epipe) -1)
              ((and (= writes 1) (member mode '(:eintr-stop :eintr-success)))
               (setf unsent t (sb-sys:sap-ref-32 ep 0) sb-posix:eintr) -1)
              (t
               ;; Test-only runtime interruption request. The production primitive
               ;; has no hooks; its generated write-to-slot path is reviewed separately.
               (when (eq mode :deferred-interrupt)
                 (sb-thread:interrupt-thread sb-thread:*current-thread* #'interrupt))
               (let ((n (funcall original fd sap count))) (when (= n 1) (incf successes)) n)))))
          (multiple-value-bind (out err code)
              (v11-driver (v11-manifest "var i:Int=0;loop while(i==0){unit};")
                (lambda (point object)
                  (when (eq point :before-spawn) (setf attempt object))
                  (when (and unsent (eq mode :eintr-stop) (eq point :draining)) (internal-error "Stop before retry"))
                  (when (eq point :after-delegation) (internal-error "Stop before ledger sync"))))
            (same (if (eq mode :epipe) 2 3) code)
            (cond ((member mode '(:epipe :eintr-stop))
                   (same "" out) (is (not (search "tests:" err)))
                   (same nil (mognitio.testing::attempt-resources-execution-delegated attempt)))
                  (t (same 1 successes)
                     (is (search "total=2 passed=0 failed=0 errors=0 aborted=1 not_run=1" out))
                     (is (mognitio.testing::attempt-resources-execution-delegated attempt)))))))
      (v11-assert-released attempt) (same before (v11-fd-snapshot))
      (let ((test (mognitio.testing::make-test-case :state :passed)))
        (mognitio.testing::sync-start attempt test) (same :passed (mognitio.testing::test-case-state test))))))
