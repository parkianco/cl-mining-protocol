;;;; Copyright (c) 2024-2026 Parkian Company LLC. All rights reserved.
;;;; SPDX-License-Identifier: Apache-2.0

;;;; package.lisp - Package definitions for cl-mining-protocol

(defpackage #:cl-mining-protocol
  (:use #:cl)
  (:nicknames #:mining-protocol #:stratum)
  (:export
   #:identity-list
   #:flatten
   #:map-keys
   #:now-timestamp
#:with-mining-protocol-timing
   #:mining-protocol-batch-process
   #:mining-protocol-health-check;; SHA256d (inlined for block hashing)
   #:sha256
   #:sha256d

   ;; Utility functions
   #:bytes-to-hex
   #:hex-to-bytes
   #:reverse-bytes
   #:concatenate-bytes

   ;; Stratum protocol
   #:stratum-pool-config
   #:make-stratum-pool-config
   #:stratum-pool-config-host
   #:stratum-pool-config-port
   #:stratum-pool-config-username
   #:stratum-pool-config-password
   #:stratum-pool-config-priority

   #:stratum-client
   #:make-stratum-client
   #:stratum-client-connect
   #:stratum-client-disconnect
   #:stratum-client-connected-p
   #:stratum-client-submit-share
   #:stratum-client-add-pool
   #:stratum-client-get-stats

   ;; Job management
   #:stratum-job
   #:stratum-job-job-id
   #:stratum-job-prev-hash
   #:stratum-job-coinbase1
   #:stratum-job-coinbase2
   #:stratum-job-merkle-branches
   #:stratum-job-version
   #:stratum-job-nbits
   #:stratum-job-ntime
   #:stratum-job-clean-jobs-p

   #:build-coinbase-from-parts
   #:compute-merkle-root-from-branches
   #:build-block-header-from-job

   ;; Share submission
   #:share-submission
   #:make-share-submission
   #:share-result
   #:validate-share

   ;; Pool connection
   #:pool-connection
   #:make-pool-connection
   #:pool-connect
   #:pool-disconnect

   ;; Miner interface
   #:miner
   #:make-miner
   #:miner-start
   #:miner-stop
   #:miner-running-p
   #:miner-status
   #:miner-set-callback

   ;; Difficulty
   #:target-from-bits
   #:difficulty-from-target
   #:hash-meets-target-p

   ;; Hashrate formatting
   #:format-hashrate
   #:estimate-hashrate-from-shares))

(defpackage #:cl-mining-protocol.test
  (:use #:cl #:cl-mining-protocol)
  (:export
   #:identity-list
   #:flatten
   #:map-keys
   #:now-timestamp
#:with-mining-protocol-timing
   #:mining-protocol-batch-process
   #:mining-protocol-health-check#:run-tests))
