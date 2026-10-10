(in-package #:mognitio.tests)

(defparameter *v120-binary-imports*
  "use Std\\Numeric\\{Bits};use Std\\Binary\\{Bytes,bytesFromBits,bytesFromInts,ByteValueError,ByteOrder,BitWidthError,BinaryDecodeError};")
(defun v120-bytes-manifest (body &optional (extra ""))
  (project-fixture (list (cons "app.mgn"
    (format nil "namespace App;~A~Alet main:Function(List<String>):Int=function(args:List<String>):Int{~A};"
            *v120-binary-imports* extra body)))))

(deftest v120-bytes-storage-and-gc
  (let ((manifest (v120-bytes-manifest
    "let b:Bytes=bytesFromBits(List<Bits<8>>[Bits<8>{0},Bits<8>{255},Bits<8>{128}]);
     let hold:Hold=Hold{bytes:b};
     let saved:Function():Bytes=function():Bytes{hold->bytes};
     var i:Int=0;loop while(i<300){
       let values:List<Bytes>=List<Bytes>[saved(),b->append(Bits<8>{0})];
       assert values->length()==2;
       assert saved()==b;
       assert branch on b->slice(1,3){Result<Bytes,SliceError>::Ok(x:Bytes)=>x==bytesFromBits(List<Bits<8>>[Bits<8>{255},Bits<8>{128}]),Result<Bytes,SliceError>::Err(e:SliceError)=>false};
       assert branch on b->toBits<24>(ByteOrder::LittleEndian){Result<Bits<24>,BinaryDecodeError>::Ok(x:Bits<24>)=>x==Bits<24>{8453888},Result<Bits<24>,BinaryDecodeError>::Err(e:BinaryDecodeError)=>false};
       assert branch on Bits<64>{18446744073709551615}->toBytes(ByteOrder::BigEndian){Result<Bytes,BitWidthError>::Ok(x:Bytes)=>x->length()==8,Result<Bytes,BitWidthError>::Err(e:BitWidthError)=>false};
       assert branch on bytesFromInts(List<Int>[0,-1,256]){Result<Bytes,ByteValueError>::Ok(x:Bytes)=>false,Result<Bytes,ByteValueError>::Err(e:ByteValueError)=>e->index==1};
       i=i+1;
     };0" "type Hold=product{bytes:Bytes;};")))
    (dolist (stress '(nil t))
      (expect-project manifest (list :stress stress :validate t :arena-unit 4096 :cap 65536)))))

(deftest v120-bytes-length-and-allocation-failures
  (dolist (body '("discard bytesFromBits(List<Bits<8>>[Bits<8>{0},Bits<8>{1}]);0"
                 "discard bytesFromBits(List<Bits<8>>[Bits<8>{0}])->append(Bits<8>{1});0"
                 "let b:Bytes=bytesFromBits(List<Bits<8>>[Bits<8>{0}]);discard b->concat(b);0"
                 "discard Bits<16>{0}->toBytes(ByteOrder::BigEndian);0"))
    (let ((manifest (v120-bytes-manifest body)))
      (let ((mognitio.value::*bytes-length-limit* 1))
        (multiple-value-bind (out err code) (v12-driver manifest)
          (same "" out) (same 4 code) (same (format nil "runtime error: bytes length overflow~%") err)))
      (multiple-value-bind (out err code)
          (process-result (list (namestring (v12-native manifest '(:bytes-length-limit 1)))))
        (same "" out) (same 4 code) (same (format nil "runtime error: bytes length overflow~%") err))))
  (let* ((manifest (v120-bytes-manifest "discard bytesFromBits(List<Bits<8>>[Bits<8>{0}]);0"))
         (mognitio.runtime::*allocation-hook*
           (lambda (kind) (when (eq kind :bytes) (error 'storage-condition)))))
    (multiple-value-bind (out err code) (v12-driver manifest)
      (same "" out) (same 4 code) (same (format nil "runtime error: allocation failure~%") err))))

(deftest v120-bytes-core-proof
  (dolist (mutation '(:source :result :operands))
    (let* ((manifest (v120-bytes-manifest
                      "let b:Bytes=bytesFromBits(List<Bits<8>>[]);assert b->length()==0;0"))
           (module (mognitio.ir:lower-program (project-checked manifest)))
           (inst (loop for fn in (mognitio.ir:module-functions module) thereis
                   (loop for block in (mognitio.ir:ir-function-blocks fn) thereis
                     (find :bytes.length (mognitio.ir:basic-block-instructions block)
                           :key #'mognitio.ir:instruction-op)))))
      (is inst)
      (ecase mutation
        (:source (setf (mognitio.ir:instruction-value inst) :string))
        (:result (setf (mognitio.ir:instruction-type inst) :bool))
        (:operands (setf (mognitio.ir:instruction-operands inst) nil)))
      (signals internal-failure (mognitio.ir:verify-module module)))))

(deftest v120-bytes-catalog-proof
  (let* ((manifest (v120-bytes-manifest "0"))
         (project (mognitio.project::load-project (namestring manifest))))
    (mognitio.project::resolve-project project)
    (let* ((catalog (third (mognitio.project::project-catalogs project)))
           (decl (first (mognitio.project::standard-catalog-declarations catalog))))
      (setf (mognitio.project::module-declaration-key decl) "standard:Std\\Binary#Fake")
      (signals internal-failure (mognitio.project::verify-standard-catalog project)))))
