(in-package #:mognitio.tests)

(defparameter *v120-numeric-lifetime*
  "namespace App; use Std\\Numeric\\{Bits,Signed,Unsigned,IntegerConversionError,BitShiftError};
type Hold=product { bits:Bits<64>; number:Int<64,Unsigned>; };
let main:Function(List<String>):Int=function(args:List<String>):Int {
  let hold:Hold=Hold{bits:Bits<64>{18446744073709551615},number:Int<64,Unsigned>{18446744073709551615}};
  let saved:Function():Bits<64>=function():Bits<64>{hold->bits};
  var i:Int=0;
  loop while(i<500) {
    let pattern:Bits<64>=hold->number->toBits();
    let values:List<Bits<64>>=List<Bits<64>>[pattern,saved()];
    assert values->length()==2;
    assert branch on pattern->shiftRight(63) {
      Result<Bits<64>,BitShiftError>::Ok(x:Bits<64>)=>x==Bits<64>{1},
      Result<Bits<64>,BitShiftError>::Err(e:BitShiftError)=>false
    };
    assert branch on hold->number->convertTo<Int>() {
      Result<Int,IntegerConversionError>::Ok(x:Int)=>false,
      Result<Int,IntegerConversionError>::Err(e:IntegerConversionError)=>true
    };
    assert hold->number==Int<64,Unsigned>{18446744073709551615};
    i=i+1;
  };
  0
};")

(deftest v120-numeric-storage-and-gc
  (let ((manifest (project-fixture (list (cons "app.mgn" *v120-numeric-lifetime*)))))
    (dolist (stress '(nil t))
      (expect-project manifest (list :stress stress :validate t :arena-unit 4096 :cap 65536)))))

(deftest v120-numeric-proof-mutations
  (let* ((manifest (project-fixture
                    '(("app.mgn" . "namespace App;use Std\\Numeric\\{Bits};template pattern<N:Int>=function():Bits<N>{Bits<N>{255}};let main:Function(List<String>):Int=function(args:List<String>):Int{assert pattern<8>()==Bits<8>{255};0};"))))
         (checked (project-checked manifest))
         (context (mognitio.semantic::checked-program-values checked)))
    (is (plusp (hash-table-count (mognitio.semantic::value-context-width-constraints context))))
    (clrhash (mognitio.semantic::value-context-width-constraints context))
    (signals internal-failure (verify-checked-program checked)))
  (let* ((manifest (project-fixture
                    '(("app.mgn" . "namespace App;use Std\\Numeric\\{Bits};let main:Function(List<String>):Int=function(args:List<String>):Int{assert Bits<8>{255}==Bits<8>{255};0};"))))
         (checked (project-checked manifest))
         (module (mognitio.ir:lower-program checked))
         (constant (loop for fn in (mognitio.ir:module-functions module) thereis
                     (loop for b in (mognitio.ir:ir-function-blocks fn) thereis
                       (find-if (lambda (i) (and (eq :constant (mognitio.ir:instruction-op i))
                                                 (mognitio.semantic::bits-type-p (mognitio.ir:instruction-type i))))
                                (mognitio.ir:basic-block-instructions b))))))
    (is constant)
    (setf (mognitio.ir:instruction-value constant) 256)
    (signals internal-failure (mognitio.ir:verify-module module))))

(deftest v120-numeric-catalog-proof
  (let* ((manifest (project-fixture
                    '(("app.mgn" . "namespace App;let main:Function(List<String>):Int=function(args:List<String>):Int{0};"))))
         (project (mognitio.project::load-project (namestring manifest))))
    (mognitio.project::resolve-project project)
    (let* ((catalog (second (mognitio.project::project-catalogs project)))
           (decl (first (mognitio.project::standard-catalog-declarations catalog))))
      (setf (mognitio.project::module-declaration-key decl) "standard:Std\\Numeric#Unsigned")
      (signals internal-failure (mognitio.project::verify-standard-catalog project)))))

(deftest v120-numeric-machine-proof
  (dolist (data '((:mul (:fixed-int (:integer-value 64) :unsigned))
                 (:mul (:fixed-int (:integer-value 8) :signed))
                 (:div (:fixed-int (:integer-value 64) :unsigned))
                 (:lt (:fixed-int (:integer-value 64) :unsigned))))
    (let* ((serial 0)
           (forms (mognitio.native.runtime::numeric-operation-forms data (lambda () (incf serial))))
           (mutant (copy-tree forms)))
      (is (mognitio.native.runtime::verify-numeric-operation-forms data forms))
      (setf (caar mutant) :idiv)
      (signals internal-failure
        (mognitio.native.runtime::verify-numeric-operation-forms data mutant)))))
