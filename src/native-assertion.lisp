(in-package #:mognitio.native.runtime)

(defun assertion-units (module)
  (let ((sites (mognitio.ir::module-assertion-sites module)))
    (when (plusp (length sites))
      (list
       (runtime-unit :assertion
         (append (helper-frame 0)
                 '((:load-frame :rax 16))
                 (if (test-image-p)
                     ;; The committed event owns the site; the runner renders it once.
                     '((:load-word :rcx :rax 8) (:store-word :r15 312 :rcx)
                       (:imm-rcx 1) (:store-word :r15 304 :rcx)
                       (:mov-edi 5) (:jmp (:helper :test.terminal)))
                     '((:load-word :rdx :rax 0) (:lea-base :rsi :rax 16)
                       (:mov-edi 2) (:mov-r8d 5) (:mov-r9d 5) (:jmp :write-setup)))) :helper)
       (mognitio.object:make-code-unit :owner :assertion-sites
         :instructions
         (loop for span across sites for id from 0
               for bytes = (mognitio.runtime::assertion-bytes span (test-image-p)) append
           (mapcar (lambda (form) (mognitio.machine:make-instruction :opcode (first form) :operands (rest form)))
                   (list '(:align 8) (list :label (list :assertion-site id))
                         (cons :bytes (append (mognitio.amd64:little-endian (length bytes) 8) (mognitio.amd64:little-endian id 8) (coerce bytes 'list)))))))))))
