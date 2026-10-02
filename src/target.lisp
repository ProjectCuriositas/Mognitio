(in-package #:mognitio.target)

(defstruct (target (:constructor linux-amd64 ()))
  (os :linux :read-only t)
  (arch :amd64 :read-only t)
  (abi :mognitio-internal-v6 :read-only t)
  (artifact :elf64-executable :read-only t))
