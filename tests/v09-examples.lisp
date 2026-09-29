(in-package #:mognitio.tests)
(deftest v010-distributed-examples
  (let ((paths (directory (merge-pathnames #p"examples/*/mognitio.toml" (root-path "")))))
    (is (>= (length paths) 13))
    (dolist (path paths)
      (expect-project path)
      (multiple-value-bind (out err code)
          (process-result (list (namestring (root-path "bin/mgn")) "run" (namestring path)))
        (same 0 code) (same "" out) (same "" err)))))
