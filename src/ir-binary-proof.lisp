(in-package #:mognitio.ir)

(defun verify-binary-instruction (instruction types context)
  (let* ((op (instruction-op instruction)) (source (instruction-value instruction))
         (result (instruction-type instruction))
         (parts (mognitio.semantic::canonical-result-arguments context result))
         (success (first parts)) (error (second parts)) (byte '(:bits (:integer-value 8))))
    (labels ((error-is (name fields)
               (and (nominal-type-p error :struct)
                    (let ((info (context-type context error)))
                      (and (equal (type-info-name info) name) (equal (type-info-fields info) fields)))))
             (order-p (type)
               (and (nominal-type-p type :enum)
                    (let ((info (context-type context type)))
                      (and (equal "standard:Std\\Binary#ByteOrder" (type-info-name info))
                           (equal '((0 "LittleEndian" nil) (1 "BigEndian" nil))
                             (mapcar (lambda (v) (list (variant-info-id v) (variant-info-name v) (variant-info-types v)))
                                     (type-info-variants info))))))))
      (case op
        (:bytes.from-ints
         (and (null source) (equal types '((:buffer :int))) (eq success :bytes)
              (error-is "standard:Std\\Binary#ByteValueError" '(("index" . :int) ("value" . :int)))))
        (:bytes.from-bits
         (and (null source) (equal types (list (list :buffer byte))) (eq result :bytes)))
        ((:bytes.equal :bytes.not-equal) (and (null source) (equal types '(:bytes :bytes)) (eq result :bool)))
        (:bytes.length (and (eq source :bytes) (equal types '(:bytes)) (eq result :int)))
        (:bytes.append (and (eq source :bytes) (equal types (list :bytes byte)) (eq result :bytes)))
        (:bytes.concat (and (eq source :bytes) (equal types '(:bytes :bytes)) (eq result :bytes)))
        (:bytes.at
         (and (eq source :bytes) (equal types '(:bytes :int)) (equal success byte)
              (error-is "IndexError" '(("index" . :int) ("length" . :int)))))
        (:bytes.slice
         (and (eq source :bytes) (equal types '(:bytes :int :int)) (eq success :bytes)
              (error-is "SliceError" '(("start" . :int) ("end" . :int) ("length" . :int)))))
        (:bytes.to-bits
         (and (eq source :bytes) (= 2 (length types)) (eq (first types) :bytes) (order-p (second types))
              (mognitio.semantic::bits-type-p success) (not (mognitio.semantic::symbolic-type-p success))
              (error-is "standard:Std\\Binary#BinaryDecodeError" '(("width" . :int) ("length" . :int)))))
        (:bits.to-bytes
         (and (mognitio.semantic::bits-type-p source) (not (mognitio.semantic::symbolic-type-p source))
              (= 2 (length types)) (equal source (first types)) (order-p (second types)) (eq success :bytes)
              (error-is "standard:Std\\Binary#BitWidthError" '(("width" . :int)))))))))
