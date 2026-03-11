;;;; cl-mining-protocol.asd - Stratum Pool Mining Protocol
;;;; Pure Common Lisp implementation of the Stratum mining protocol

(defsystem "cl-mining-protocol"
  :version "1.0.0"
  :author "CLPIC Contributors"
  :license "MIT"
  :description "Stratum pool mining protocol for Bitcoin-compatible blockchains"
  :long-description "A standalone implementation of the Stratum mining protocol
supporting pool mining, job management, share submission, and variable difficulty.
Includes an inlined SHA256d implementation for block header hashing."
  :depends-on ()
  :serial t
  :components ((:file "package")
               (:module "src"
                :serial t
                :components ((:file "util")))))
