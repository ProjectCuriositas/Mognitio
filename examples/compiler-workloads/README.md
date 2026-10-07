# Compiler workloads

This example implements a small scanner and persistent symbol table using ordinary
Mognitio values. It exercises scalar decomposition, fragment assembly, token
positions, symbol registration, lookup, and retained snapshots.

The scanner recognizes exactly space, tab, CR, and LF as whitespace and
`(`, `)`, `=`, `,`, and `;` as punctuation. Other scalars form words.
Positions are half-open scalar offsets. Symbol IDs follow first registration;
comparison is exact and case-sensitive. These rules are example behavior, not
the Mognitio compiler's grammar or a new standard-library API.

Build and run from the repository root:

```sh
bin/mgn build examples/compiler-workloads/mognitio.toml -o /tmp/compiler-workloads
/tmp/compiler-workloads combined /tmp/input.txt 1 /tmp/queries.txt
bin/mgn run examples/compiler-workloads/mognitio.toml -- combined /tmp/input.txt 1 /tmp/queries.txt
```

The four arguments are mode, UTF-8 input file, nonnegative repetition count, and
UTF-8 query file. Modes are `scalars`, `join`, `scan`, `symbols`, and `combined`.
Queries and symbol inputs use LF-separated nonempty names without a trailing LF.
An empty query or symbol file represents no entries. Join splits at LF, retains
empty fragments, and joins them with `|`. Input, query, and output paths are
provided by the caller; the program does not generate expected results.

Output is the private `MGN11R1` verification frame. It includes every scalar,
token, registered ID, symbol-table entry, lookup result, and assembled string
applicable to the mode. String lengths count Unicode scalars, so embedded NUL,
CR, LF, and separators are unambiguous. This format is an internal test adapter.

Run the independent oracle, host/native cases, standalone execution, malformed
UTF-8 cases, output-corruption controls, and separate built-in tests with:

```sh
python3 tests/v11-workloads.py
```

The five built-in tests live in `tests/fixtures/v11-checks.mgn` and are copied into
a temporary test project. They are not imported into the measured application.
Large expected values stay in the external Python oracle. A fixed application
binary accepts all measured input sizes without adding expected literals.

For an explicit artifact and persistent evidence directory:

```sh
python3 tests/v11-workloads.py verify --image /tmp/compiler-workloads --evidence /tmp/workload-check
python3 tests/v11-workloads.py measure --image /tmp/compiler-workloads --evidence /tmp/workload-calibration
```

Calibration records include raw output files, verification status, elapsed
process time, and peak RSS. The process interval includes input, workload,
serialization, and file output, but excludes compilation and external result
comparison. Calibration alone does not establish a performance acceptance claim.
