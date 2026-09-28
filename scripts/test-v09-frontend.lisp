(require :asdf)
(asdf:load-asd (truename (merge-pathnames "../mognitio.asd" *load-truename*)))
(asdf:load-system "mognitio/v09-frontend-tests")
(mognitio.tests:run-tests)
