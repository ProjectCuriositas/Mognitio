(in-package #:mognitio.tests)

(defparameter *v120-value-positive*
  '("type Tag<N:Int>=product{};let a:Tag<-1>=Tag<(-1)>{};true"
    "type Tag<N:Int>=product{};let a:Tag<0>=Tag<-0>{};true"
    "type Tag<N:Int>=product{};let a:Tag<-9223372036854775808>=Tag<-(9223372036854775808)>{};true"
    "type Tag<N:Int>=product{};let a:Tag<9223372036854775807>=Tag<((9223372036854775807))>{};true"
    "type Tag<N:Int>=product{};template keep<N:Int,T>=function(a:Tag<N>,x:T):T{x};keep<-1,Int>(Tag<-1>{},42)==42"
    "type Tag<N:Int>=product{};alias Same<N:Int>=Tag<N>;let a:Same<8>=Tag<(8)>{};true"
    "type Item<N:Int,T>=product{value:T;};alias Forward<M:Int,U>=Item<M,U>;let a:Forward<-9,Int>=Item<-9,Int>{value:42};a->value==42"
    "type Item<N:Int>=product{value:Int;};template pass<N:Int>=function(x:Item<N>):Item<N>{x};template relay<M:Int>=function(y:Item<M>):Item<M>{pass<M>(y)};relay<-1>(Item<-1>{value:7})->value==7"
    "type Item<N:Int>=product{value:Int;};template capture<N:Int>=function(x:Item<N>):Function():Item<N>{function():Item<N>{x}};capture<-7>(Item<-7>{value:9})()->value==9"
    "type A<N:Int>=product{};type B<N:Int>=product{};let a:A<-2>=A<-2>{};let b:B<-2>=B<-2>{};true"))

(deftest v120-value-arguments-host-and-native
  (dolist (source *v120-value-positive*)
    (v03-positive source :true)))

(deftest v120-value-arguments-static-boundaries
  (dolist (source
    '("type Tag<N:Int>=product{};let a:Tag<9223372036854775808>=Tag<0>{};true"
      "type Tag<N:Int>=product{};let a:Tag<-9223372036854775809>=Tag<0>{};true"
      "type Tag<N:Int>=product{};let a:Tag<--1>=Tag<0>{};true"
      "type Tag<N:Int>=product{};let a:Tag<-(-1)>=Tag<0>{};true"
      "type Tag<N:Int>=product{};let a:Tag<1+7>=Tag<8>{};true"
      "type Tag<N:Int>=product{};let a:Tag<true>=Tag<0>{};true"
      "type Tag<N:Int>=product{};let a:Tag<\"8\">=Tag<8>{};true"
      "type Tag<N:Int>=product{};let n:Int=8;let a:Tag<n>=Tag<8>{};true"
      "type Tag<N:Int>=product{};alias Bad<N:Int>=Tag<-N>;true"
      "type Tag<N:Int>=product{};alias Bad<T>=Tag<T>;true"
      "type Tag<N:Int>=product{};let a:Tag<Int>=Tag<0>{};true"
      "type Tag<T>=product{};let a:Tag<8>=Tag<Int>{};true"
      "type Tag<N:Int>=product{};let a:Tag<-1>=Tag<1>{};true"
      "type A<N:Int>=product{};type B<N:Int>=product{};let a:A<1>=B<1>{};true"
      "type Tag<N:Int,N>=product{};true"
      "type Tag<N:Bool>=product{};true"
      "type Tag<N:Int>=product{x:N;};true"
      "type Tag<N:Int>=product{x:List<N>;};true"
      "alias Bad<N:Int>=N;true"
      "template bad<N:Int>=function():Int{N};true"
      "template bad<N:Int>=function():Function():Int{function():Int{N}};true"
      "template bad<N:Int>=function(N:Int):Int{N};true"
      "template bad<N:Int>=function():Bool{let N:Int=1;true};true"
      "type Tag<N:Int>=product{};template bad<T>=function():Tag<T>{Tag<T>{}};true"
      "type Tag<N:Int>=product{};template bad<N:Int>=function():Tag<N>{Tag<N>{}};discard bad<Int>();true"
      "type Tag<N:Int>=product{};let a:Tag<01>=Tag<1>{};true"
      "type Tag<N:Int>=product{};let a:Tag<0x8>=Tag<8>{};true"))
    (signals source-failure (check-program (parse-text source)))))

(deftest v120-value-argument-proof-and-display
  (let* ((checked (check-program (parse-text "type Tag<N:Int>=product{};let a:Tag<-7>=Tag<-7>{};true")))
         (context (mognitio.semantic::checked-program-values checked))
         (template (gethash "Tag" (mognitio.semantic::value-context-names context)))
         (value (mognitio.semantic::instantiate-generic-type context template '((:integer-value -7)))))
    (same "Tag<-7>" (mognitio.semantic::diagnostic-type-name value context))
    (setf (mognitio.semantic::generic-template-parameters template) '((:parameter (:type 0) 0)))
    (signals internal-failure (verify-checked-program checked))))
