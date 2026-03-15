;; Copyright (c) 2024-2026 Parkian Company LLC. All rights reserved.
;; SPDX-License-Identifier: Apache-2.0

(in-package #:cl-mining-protocol)

;;; Core types for cl-mining-protocol
(deftype cl-mining-protocol-id () '(unsigned-byte 64))
(deftype cl-mining-protocol-status () '(member :ready :active :error :shutdown))
