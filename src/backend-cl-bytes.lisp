(in-package #:mognitio.backend.cl)

(defun binary-host-form (info args context)
  (let* ((op (operation-info-kind info)) (source (first (operation-info-parameter-types info)))
         (result (operation-info-result-type info))
         (parts (mognitio.semantic::canonical-result-arguments context result))
         (error (second parts)))
    (flet ((result-arguments () (list (list 'quote result) (list 'quote error))))
      (case op
        (:binary.publish
         (append (list 'mognitio.io::invoke-publication) args (result-arguments)
                 (list (list 'quote (mapcar #'cdr (type-info-fields (context-type context error)))))))
        ((:bytes.from-ints :bytes.from-bits)
         (append (list 'mognitio.value::bytes-from-list (first args) (eq op :bytes.from-ints))
                 (result-arguments)))
        (:bits.to-bytes
         (append (list 'mognitio.value::bits-to-bytes (first args) (second (second source)) (second args))
                 (result-arguments)))
        (:bytes.to-bits
         (append (list 'mognitio.value::bytes-to-bits (first args) (second (second (first parts))) (second args))
                 (result-arguments)))
        (t
         (append (list (ecase op
                         (:bytes.length 'mognitio.value::bytes-length)
                         (:bytes.at 'mognitio.value::bytes-at)
                         (:bytes.append 'mognitio.value::bytes-append)
                         (:bytes.concat 'mognitio.value::bytes-concat)
                         (:bytes.slice 'mognitio.value::bytes-slice)))
                 args (when parts (result-arguments))))))))
