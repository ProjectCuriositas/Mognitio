(in-package #:mognitio.tests)
(deftest v09-distributed-examples
  (dolist (path (directory (root-path "examples/*.mgn")))
    (let ((source (uiop:read-file-string path))
          (expected (if (string= (pathname-name path) "false") :false :true)))
      (same expected (compiled-result source))
      (expect-cli (list "run" (namestring path)) 0 :output (format nil "~(~A~)~%" expected))
      (v06-expect-native source expected))))
