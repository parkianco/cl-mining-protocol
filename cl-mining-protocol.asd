;; Copyright (c) 2024-2026 Parkian Company LLC. All rights reserved.
;; SPDX-License-Identifier: BSD-3-Clause

;;;; cl-mining-protocol.asd - Stratum Pool Mining Protocol
;;;; Pure Common Lisp implementation of the Stratum mining protocol

(asdf:defsystem #:"cl-mining-protocol"
  :version "0.1.0"
  :author "Parkian Company LLC"
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

(asdf:defsystem #:cl-mining-protocol/test
  :description "Tests for cl-mining-protocol"
  :depends-on (#:cl-mining-protocol)
  :serial t
  :components ((:module "test"
                :components ((:file "test-mining-protocol"))))
  :perform (asdf:test-op (o c)
             (let ((result (uiop:symbol-call :cl-mining-protocol.test :run-tests)))
               (unless result
                 (error "Tests failed")))))
