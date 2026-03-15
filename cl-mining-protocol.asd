;; Copyright (c) 2024-2026 Parkian Company LLC. All rights reserved.
;; SPDX-License-Identifier: Apache-2.0

(asdf:defsystem #:cl-mining-protocol
  :description "Stratum pool mining protocol for Bitcoin-compatible blockchains"
  :author "Park Ian Co"
  :license "Apache-2.0"
  :version "0.1.0"
  :serial t
  :components
  ((:module "src"
            :serial t
            :components
            ((:file "package")
             (:file "conditions")
             (:file "types")
             (:file "util")
             (:file "job")
             (:file "stratum")
             (:file "cl-mining-protocol"))))
  :in-order-to ((asdf:test-op (test-op #:cl-mining-protocol/test))))

(asdf:defsystem #:cl-mining-protocol/test
  :description "Tests for cl-mining-protocol"
  :author "Park Ian Co"
  :license "Apache-2.0"
  :depends-on (#:cl-mining-protocol)
  :serial t
  :components
  ((:module "test"
    :serial t
    :components
    ((:file "package")
     (:file "test"))))
  :perform (asdf:test-op (o c)
             (let ((result (uiop:symbol-call :cl-mining-protocol.test :run-tests)))
               (unless result
                 (error "Tests failed")))))
