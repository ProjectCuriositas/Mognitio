(in-package #:mognitio.native.runtime)

;; All native object kinds and descriptor layouts are defined here.
(defconstant +kind-mask+ #x70)
(defconstant +object-scans+ 208)
(defconstant +header-visits+ 216)
(defconstant +trace-passes+ 224)
(defvar *runtime-module* nil)
(defun layout-name (key) (list :layout key))
(defun static-name (kind key) (list :static-object kind key))
(defun runtime-list-types ()
  (let ((types nil))
    (labels ((note (type)
               (cond ((mognitio.semantic:list-type-p type) (pushnew type types :test #'equal) (note (second type)))
                     ((and (consp type) (eq :buffer (first type))) (note (list :list (second type))))
                     ((mognitio.semantic:function-type-p type) (mapc #'note (second type)) (note (third type))))))
      (when *runtime-module*
        (dolist (fn (mognitio.ir:module-functions *runtime-module*))
          (mapc #'note (mognitio.ir:ir-function-parameter-types fn)) (note (mognitio.ir:ir-function-result-type fn))
          (mapc #'note (mognitio.ir::ir-function-capture-types fn))
          (dolist (block (mognitio.ir:ir-function-blocks fn))
            (dolist (p (mognitio.ir:basic-block-parameters block)) (note (cdr p)))
            (dolist (i (mognitio.ir:basic-block-instructions block)) (note (mognitio.ir:instruction-type i)))))
        (loop for info across (mognitio.semantic:value-context-types (mognitio.ir:module-values *runtime-module*)) do
          (mapc (lambda (p) (note (cdr p))) (mognitio.semantic:type-info-fields info))
          (mapc (lambda (v) (mapc #'note (mognitio.semantic:variant-info-types v))) (mognitio.semantic:type-info-variants info))))
      (sort types #'mognitio.semantic::structural-key-before-p))))
(defun descriptors (context)
  ;; Rows: symbol, kind, identity, variant, fixed word count, reference indices.
  ;; Buffer rows additionally carry their element reference classification.
  (append
    (loop for info across (mognitio.semantic:value-context-types context) append
      (let ((id (mognitio.semantic:type-info-id info)))
        (labels ((row (kind variant types)
                   (list (list :descriptor id variant) kind id variant (length types)
                         (loop for type in types for index from 0 when (mognitio.semantic:reference-type-p type) collect index))))
          (case (mognitio.semantic:type-info-kind info)
            (:struct (list (row 1 0 (mapcar #'cdr (mognitio.semantic:type-info-fields info)))))
            (:enum (loop for v in (mognitio.semantic:type-info-variants info)
                         collect (row 2 (mognitio.semantic:variant-info-id v) (mognitio.semantic:variant-info-types v))))))))
    (loop for impl across (mognitio.semantic:value-context-implementations context)
          for id = (mognitio.semantic:implementation-info-id impl)
          collect (list (layout-name (list :package id)) 3 id 0 1
                        (when (mognitio.semantic:reference-type-p (mognitio.semantic:implementation-info-concrete impl)) '(0))))
    (loop for fn in (when *runtime-module* (mognitio.ir:module-functions *runtime-module*))
          when (and (plusp (mognitio.ir:ir-function-id fn)) (null (mognitio.ir:ir-function-method fn)))
          collect (list (layout-name (list :closure (mognitio.ir:ir-function-id fn))) 4 (mognitio.ir:ir-function-id fn) 0
                        (1+ (length (mognitio.ir::ir-function-capture-types fn)))
                        (loop for type in (mognitio.ir::ir-function-capture-types fn) for index from 1
                              when (mognitio.semantic:reference-type-p type) collect index)))
    (loop for type in (runtime-list-types) for serial from 0
          append (list (list (layout-name (list :list type)) 5 serial 0 3
                             (if (mognitio.semantic:reference-type-p (second type)) '(1 2) '(1)))
                       (list (layout-name (list :buffer (second type))) 6 serial 0 1 nil
                             (not (null (mognitio.semantic:reference-type-p (second type)))))))))
(defun static-objects ()
  (append
    (loop for type in (runtime-list-types) append
      (list (list (static-name :list type) (layout-name (list :list type)) 5 '(0 0 0))
            (list (static-name :buffer (second type)) (layout-name (list :buffer (second type))) 6 '(0))))
    (loop for fn in (when *runtime-module* (mognitio.ir:module-functions *runtime-module*))
          when (and (plusp (mognitio.ir:ir-function-id fn)) (null (mognitio.ir:ir-function-method fn))
                    (null (mognitio.ir::ir-function-capture-types fn)))
          collect (let ((id (mognitio.ir:ir-function-id fn)))
                    (list (static-name :closure id) (layout-name (list :closure id)) 4 (list (list :function id)))))))
(defun metadata-unit (context)
  (let ((forms nil))
    (labels ((word (value)
               (push (if (integerp value) (cons :bytes (mognitio.amd64:little-endian value 8)) (list :address64 value)) forms))
             (record (name words)
               (push '(:align 8) forms) (push (list :label name) forms) (mapc #'word words)))
      (dolist (row (descriptors context))
        (destructuring-bind (name kind id variant count refs &optional dynamic) row
          (record name (append (list kind id variant count (length refs)) refs (when (= kind 6) (list (if dynamic 1 0)))))))
      (loop for impl across (mognitio.semantic:value-context-implementations context)
            for id = (mognitio.semantic:implementation-info-id impl)
            for contract = (mognitio.semantic:implementation-info-contract impl) do
        (record (list :method-table id)
          (append (list id (second contract) (length (mognitio.semantic:implementation-info-methods impl)))
                  (loop for req in (mognitio.semantic:type-info-methods (mognitio.semantic:context-type context contract))
                        collect (list :function (mognitio.semantic:signature-id
                          (cdr (assoc (mognitio.semantic:requirement-name req) (mognitio.semantic:implementation-info-methods impl) :test #'string=))))))))
      (dolist (object (static-objects))
        (destructuring-bind (name descriptor kind words) object
          (record name (append (list (+ 32 (* 8 (length words))) (+ 5 (* kind 16)) descriptor 0) words)))))
    (mognitio.object:make-code-unit :owner :metadata
      :instructions (loop for form in (nreverse forms)
                          collect (mognitio.machine:make-instruction :opcode (first form) :operands (rest form))))))
(defun initialize-object (descriptor kind &optional (variant 0))
  ;; RAX is an allocated block; no safepoint occurs until initialization ends.
  (append
    '((:mov-reg :rdx :rax) (:load-word :r9 :rdx 0) (:add-reg :r9 :rdx)
      (:lea-base :r8 :rdx 32) (:imm-rax 0)
      (:label :zero-payload) (:cmp-reg :r8 :r9) (:jae :payload-ready)
      (:store-word :r8 0 :rax) (:add-imm :r8 8) (:jmp :zero-payload)
      (:label :payload-ready))
    `((:imm-rcx ,(+ 1 (* kind 16))) (:store-word :rdx 8 :rcx)
      (:lea-meta ,descriptor) (:store-word :rdx 16 :rax) (:imm-rax ,variant) (:store-word :rdx 24 :rax))))
