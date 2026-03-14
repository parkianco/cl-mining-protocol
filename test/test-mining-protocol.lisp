;; Copyright (c) 2024-2026 Parkian Company LLC. All rights reserved.
;; SPDX-License-Identifier: BSD-3-Clause

;;;; test-mining-protocol.lisp - Unit tests for mining-protocol
;;;;
;;;; Copyright (c) 2024-2026 Parkian Company LLC. All rights reserved.
;;;; SPDX-License-Identifier: BSD-3-Clause

(defpackage #:cl-mining-protocol.test
  (:use #:cl)
  (:export #:run-tests))

(in-package #:cl-mining-protocol.test)

(defun run-tests ()
  "Run all tests for cl-mining-protocol."
  (format t "~&Running tests for cl-mining-protocol...~%")
  ;; TODO: Add test cases
  ;; (test-function-1)
  ;; (test-function-2)
  (format t "~&All tests passed!~%")
  t)
