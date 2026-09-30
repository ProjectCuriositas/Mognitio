(defpackage #:mognitio.diagnostics
  (:use #:cl)
  (:export #:diagnostic #:make-diagnostic #:diagnostic-phase #:diagnostic-message
           #:diagnostic-path #:diagnostic-line #:diagnostic-column #:diagnostic-start-byte #:diagnostic-end-byte
           #:compiler-failure #:failure-diagnostic #:source-failure
           #:usage-or-io-failure #:internal-failure #:fail #:internal-error
           #:render-diagnostic #:one-line))
(defpackage #:mognitio.source
  (:use #:cl #:mognitio.diagnostics)
  (:export #:source #:source-path #:source-octets #:source-text #:source-byte-offsets
           #:source-lines #:source-columns #:decode-source #:read-source
           #:span #:make-span #:span-source #:span-start #:span-end
           #:span-diagnostic #:fail-at))
(defpackage #:mognitio.syntax
  (:use #:cl #:mognitio.source)
  (:export #:declaration-attributes #:declaration-span #:walk-ast
           #:attribute-syntax #:make-attribute-syntax #:attribute-syntax-name #:attribute-syntax-span
           #:assert-statement #:make-assert-statement #:assert-statement-operand #:assert-statement-keyword-span
           #:program-declarations #:expression-statement-discard-p #:loop-expression-target #:loop-expression-binder
           #:template-declaration #:template-declaration-name #:template-declaration-parameters #:template-declaration-function #:template-declaration-span #:make-template-declaration
           #:specialization-reference #:specialization-reference-name #:specialization-reference-arguments #:specialization-reference-span #:make-specialization-reference
           #:list-expression #:list-expression-type #:list-expression-elements #:list-expression-span #:make-list-expression
           #:concrete-function-reference #:make-concrete-function-reference #:concrete-function-reference-target
           #:type-syntax #:make-type-syntax #:type-syntax-name #:type-syntax-arguments
           #:function-type-syntax #:make-function-type-syntax #:function-type-syntax-parameters #:function-type-syntax-result #:function-type-syntax-span
           #:function-type-syntax-p #:generic-signature-syntax #:make-generic-signature-syntax #:generic-signature-syntax-p #:generic-signature-syntax-type-parameters #:generic-signature-syntax-parameters #:generic-signature-syntax-result #:generic-signature-syntax-span
           #:form-span
           #:data-declaration-type-parameters #:function-expression-type-parameters
           #:local-binding-annotation #:call-expression-type-arguments
           #:try-expression #:make-try-expression #:try-expression-operand
           #:panic-expression #:make-panic-expression #:panic-expression-block
           #:data-declaration #:make-data-declaration #:data-declaration-p #:data-declaration-name #:data-declaration-kind #:data-declaration-target #:data-declaration-members #:data-declaration-span #:contract-declaration #:make-contract-declaration #:contract-declaration-p #:contract-declaration-name #:contract-declaration-methods #:contract-declaration-span #:implementation-declaration #:make-implementation-declaration #:implementation-declaration-p #:implementation-declaration-target #:implementation-declaration-contract #:implementation-declaration-methods #:implementation-declaration-span #:named-member #:make-named-member #:named-member-p #:named-member-name #:named-member-value #:named-member-span #:struct-expression #:make-struct-expression #:struct-expression-p #:struct-expression-name #:struct-expression-fields #:struct-expression-span #:enum-expression #:make-enum-expression #:enum-expression-p #:enum-expression-name #:enum-expression-variant #:enum-expression-arguments #:enum-expression-parenthesized-p #:enum-expression-span #:field-expression #:make-field-expression #:field-expression-p #:field-expression-receiver #:field-expression-name #:field-expression-span #:field-assignment #:make-field-assignment #:field-assignment-p #:field-assignment-target #:field-assignment-value #:field-assignment-span #:this-expression #:make-this-expression #:this-expression-p #:this-expression-token #:this-expression-span #:branch-expression #:make-branch-expression #:branch-expression-p #:branch-expression-mode #:branch-expression-subject #:branch-expression-arms #:branch-expression-span #:branch-arm #:make-branch-arm #:branch-arm-p #:branch-arm-selector #:branch-arm-value #:branch-arm-span #:variant-pattern #:make-variant-pattern #:variant-pattern-p #:variant-pattern-name #:variant-pattern-variant #:variant-pattern-bindings #:variant-pattern-span
           #:text-payload #:make-text-payload #:text-payload-octets #:text-payload-scalar-count
           #:token-payload #:string-literal #:make-string-literal #:string-literal-payload
           #:method-call #:make-method-call #:method-call-receiver #:method-call-name #:method-call-arguments
           #:loop-expression #:make-loop-expression #:loop-expression-body #:loop-expression-condition
           #:break-statement #:make-break-statement #:break-statement-value
           #:continue-statement #:make-continue-statement
           #:void-literal #:make-void-literal #:void-literal-span
           #:expression-statement #:make-expression-statement #:expression-statement-expression
           #:token #:make-token #:token-kind #:token-span #:boolean-literal
           #:make-boolean-literal #:boolean-literal-value #:boolean-literal-span
           #:if-expression #:make-if-expression #:if-expression-condition
           #:if-expression-then-branch #:if-expression-else-branch #:if-expression-span
           #:node-span #:program #:make-program #:program-source #:program-root
           #:program-statements #:token-text
           #:function-expression #:make-function-expression
           #:function-expression-parameters #:function-expression-result-type
           #:function-expression-body #:function-expression-span
           #:parameter #:make-parameter #:parameter-type #:parameter-name #:parameter-span
           #:call-expression #:make-call-expression #:call-expression-callee #:call-expression-arguments
           #:return-statement #:make-return-statement #:return-statement-keyword #:return-statement-value #:integer-literal #:make-integer-literal
           #:integer-literal-token #:integer-literal-span #:variable-reference
           #:make-variable-reference #:variable-reference-name #:variable-reference-span
           #:local-binding #:make-local-binding #:local-binding-mutability #:local-binding-name
           #:local-binding-initializer #:local-binding-span #:assignment #:make-assignment
           #:assignment-name #:assignment-rhs #:assignment-span #:sequence-node
           #:make-sequence-node #:sequence-node-statements #:sequence-node-terminal
           #:sequence-node-span #:grouping #:make-grouping #:grouping-expression
           #:grouping-span #:unary-expression #:make-unary-expression
           #:unary-expression-operator #:unary-expression-operand #:unary-expression-span
           #:binary-expression #:make-binary-expression #:binary-expression-operator
           #:binary-expression-left #:binary-expression-right #:binary-expression-span))
(defpackage #:mognitio.frontend
  (:use #:cl #:mognitio.diagnostics #:mognitio.source #:mognitio.syntax)
  (:export #:lex-source #:parse-program))
(defpackage #:mognitio.semantic
  (:use #:cl #:mognitio.diagnostics #:mognitio.source #:mognitio.syntax)
  (:export #:completion-structure #:signature-captures #:list-type-p
           #:checked-program-values #:checked-member #:checked-pack #:checked-value-type #:signature-receiver #:signature-method #:signature-runtime-types #:nominal-type-p #:reference-type-p #:valid-value-type-p #:canonical-type #:context-type #:type-info #:type-info-id #:type-info-kind #:type-info-name #:type-info-fields #:type-info-variants #:type-info-methods #:variant-info #:variant-info-id #:variant-info-name #:variant-info-types #:requirement #:requirement-name #:requirement-parameters #:requirement-result #:implementation-info #:implementation-info-id #:implementation-info-concrete #:implementation-info-contract #:implementation-info-methods #:member-info #:member-info-kind #:member-info-type #:member-info-index #:member-info-variant #:member-info-implementation #:member-info-signature #:member-info-contract #:value-context-types #:value-context-implementations
           #:checked-error #:error-info-kind #:error-info-operand-type #:error-info-result-type #:error-info-return-type #:error-info-owner
           #:checked-string-literals #:checked-operation #:operation-info #:operation-info-kind #:operation-info-operands
           #:operation-info-parameter-types #:operation-info-result-type
           #:check-program #:checked-program #:checked-program-program #:checked-normal-type #:checked-symbol #:checked-literal #:checked-literal-p #:checked-program-bindings #:local-symbol-id #:local-symbol-type #:local-symbol-mutability
           #:local-symbol-owner #:verify-checked-program #:checked-completion #:completion-normal-type #:completion-may-return
           #:checked-call #:checked-return #:checked-program-signatures #:signature-id
           #:signature-declaration #:signature-parameter-types #:signature-result-type #:check-call-graph
           #:checked-loop #:checked-control #:loop-info-id #:loop-info-owner #:loop-info-node
           #:loop-info-normal-type #:loop-info-targets #:completion-exits
           #:function-type-p #:signature-type #:completion-targets #:local-symbol-targets #:local-symbol-static-target
           #:call-info-type #:call-info-targets #:call-info-owner #:checked-function))
(defpackage #:mognitio.backend.cl
  (:use #:cl #:mognitio.diagnostics #:mognitio.source #:mognitio.syntax
        #:mognitio.semantic)
  (:export #:compile-program #:execute-program #:compiled-program))
(defpackage #:mognitio.driver
  (:use #:cl #:mognitio.diagnostics #:mognitio.source #:mognitio.syntax
        #:mognitio.frontend #:mognitio.semantic #:mognitio.backend.cl)
  (:export #:run-cli))
(defpackage #:mognitio.testing
  (:use #:cl #:mognitio.diagnostics))
(defpackage #:mognitio.cli
  (:use #:cl)
  (:export #:main))

(defpackage #:mognitio.ir
  (:use #:cl #:mognitio.diagnostics #:mognitio.source #:mognitio.syntax
        #:mognitio.semantic)
  (:export #:module-values #:ir-function-method #:instruction #:make-instruction #:instruction-result #:instruction-type
           #:instruction-effects #:instruction-op #:instruction-value #:instruction-operands #:instruction-span
           #:basic-block #:make-basic-block #:basic-block-id #:basic-block-parameters
           #:basic-block-instructions #:basic-block-terminator #:basic-block-span
           #:module-literal-pool #:module #:make-module #:module-functions #:module-entry #:module-span
           #:ir-function #:make-ir-function #:ir-function-id #:ir-function-parameter-types
           #:ir-function-result-type #:ir-function-blocks #:ir-function-entry #:ir-function-span
           #:lower-program #:verify-module #:successors))
(defpackage #:mognitio.regalloc
  (:use #:cl #:mognitio.diagnostics)
  (:export #:allocate-function #:verify-allocation #:allocation-locations #:allocation-intervals
           #:allocation-barriers #:allocation-spill-count #:allocation-order #:parallel-copies
           #:live-intervals #:interval-id #:interval-start #:interval-end))
(defpackage #:mognitio.object
  (:use #:cl #:mognitio.diagnostics)
  (:export #:code-unit #:make-code-unit #:code-unit-owner #:code-unit-instructions
           #:code-unit-entry #:layout-units #:image-symbol #:make-image-symbol
           #:image-symbol-name #:image-symbol-kind #:image-symbol-offset #:symbol-kind
           #:fixup #:make-fixup #:fixup-offset #:fixup-end #:fixup-target #:fixup-kind #:fixup-use))
(defpackage #:mognitio.machine
  (:use #:cl #:mognitio.diagnostics)
  (:export #:instruction #:make-instruction #:instruction-opcode
           #:instruction-operands #:instruction-span #:lower-module))
(defpackage #:mognitio.amd64
  (:use #:cl #:mognitio.diagnostics)
  (:export #:encode #:little-endian))
(defpackage #:mognitio.elf
  (:use #:cl #:mognitio.diagnostics)
  (:export #:make-image))
(defpackage #:mognitio.backend.native
  (:use #:cl #:mognitio.diagnostics)
  (:export #:compile-program))
(defpackage #:mognitio.artifact
  (:use #:cl #:mognitio.diagnostics)
  (:export #:validate-paths #:publish-image))
(defpackage #:mognitio.target
  (:use #:cl #:mognitio.diagnostics)
  (:export #:target #:linux-amd64 #:target-os #:target-arch #:target-abi #:target-artifact))

(defpackage #:mognitio.runtime (:use #:cl) (:export #:program-runtime-failure #:integer-runtime-failure #:failure-kind #:failure-octets #:failure-status #:runtime-error #:write-runtime-failure #:+retry-budget+))
(defpackage #:mognitio.integer (:use #:cl) (:export #:+minimum+ #:+maximum+ #:in-range-p #:decimal-magnitude #:checked-arithmetic))

(defpackage #:mognitio.text
  (:use #:cl)
  (:export #:text-value #:text-value-octets #:text-value-scalar-count #:literal-value
           #:text-length #:text-equal #:text-not-equal #:text-concat #:text-slice #:checked-size))

(defpackage #:mognitio.roots
  (:use #:cl #:mognitio.diagnostics #:mognitio.ir)
  (:export #:analyze-roots #:verify-roots #:root-plan #:root-plan-function-id
           #:root-plan-capacity #:root-plan-sites #:root-site #:root-site-block-id
           #:root-site-instruction-index #:root-site-values))

(defpackage #:mognitio.native.runtime
  (:use #:cl #:mognitio.diagnostics)
  (:export #:+context-size+ #:+root-head+ #:+arena-head+ #:+page-size+
           #:entry-forms #:literal-forms #:text-helper-units))
(defpackage #:mognitio.frame
  (:use #:cl #:mognitio.diagnostics)
  (:export #:plan-frame #:verify-layout #:verify-sections #:layout-size #:layout-root-offset
           #:layout-capacity #:layout-temporary #:layout-arity))

(defpackage #:mognitio.value
  (:use #:cl)
  (:export #:construct #:pack #:field #:tag #:receiver #:method-id #:data-value #:interface-value))

(defpackage #:mognitio.project
  (:use #:cl #:mognitio.diagnostics #:mognitio.source #:mognitio.syntax))
