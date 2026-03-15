;; Copyright (c) 2024-2026 Parkian Company LLC. All rights reserved.
;; SPDX-License-Identifier: Apache-2.0

(in-package #:cl-mining-protocol)

(define-condition cl-mining-protocol-error (error)
  ((message :initarg :message :reader cl-mining-protocol-error-message))
  (:report (lambda (condition stream)
             (format stream "cl-mining-protocol error: ~A" (cl-mining-protocol-error-message condition)))))
