;;;; Copyright (c) 2024-2026 Parkian Company LLC. All rights reserved.
;;;; SPDX-License-Identifier: BSD-3-Clause

;;;; job.lisp - Mining Job Management
;;;;
;;;; Handles mining jobs received from pools, including coinbase reconstruction,
;;;; merkle root computation, and block header building.

(in-package #:cl-mining-protocol)

;;; ============================================================================
;;; STRATUM JOB STRUCTURE
;;; ============================================================================

(defstruct stratum-job
  "A Stratum mining job ready for mining.

   Encapsulates all data needed to construct block headers:
   - Block template reference for share validation
   - Pre-computed coinbase split for extranonce insertion
   - Merkle branches for fast root calculation"
  (job-id "" :type string)
  (prev-hash (make-array 0 :element-type '(unsigned-byte 8))
   :type (vector (unsigned-byte 8)))
  (coinbase1 (make-array 0 :element-type '(unsigned-byte 8))
   :type (vector (unsigned-byte 8)))
  (coinbase2 (make-array 0 :element-type '(unsigned-byte 8))
   :type (vector (unsigned-byte 8)))
  (merkle-branches (list) :type list)
  (version 0 :type (unsigned-byte 32))
  (nbits 0 :type (unsigned-byte 32))
  (ntime 0 :type (unsigned-byte 32))
  (clean-jobs-p t :type boolean)
  (created-at 0 :type integer)
  (expires-at 0 :type integer)
  (difficulty 1.0d0 :type double-float)
  (extranonce1 (make-array 0 :element-type '(unsigned-byte 8))
   :type (vector (unsigned-byte 8)))
  (extranonce2-size 4 :type fixnum))

(defun parse-stratum-job (params extranonce1 extranonce2-size difficulty)
  "Parse a mining.notify parameters list into a stratum-job.

   PARAMS format: [job_id, prev_hash, coinbase1, coinbase2, merkle_branches,
                   version, nbits, ntime, clean_jobs]"
  (make-stratum-job
   :job-id (nth 0 params)
   :prev-hash (hex-to-bytes (nth 1 params))
   :coinbase1 (hex-to-bytes (nth 2 params))
   :coinbase2 (hex-to-bytes (nth 3 params))
   :merkle-branches (mapcar #'hex-to-bytes (nth 4 params))
   :version (parse-integer (nth 5 params) :radix 16)
   :nbits (parse-integer (nth 6 params) :radix 16)
   :ntime (parse-integer (nth 7 params) :radix 16)
   :clean-jobs-p (nth 8 params)
   :created-at (get-universal-time)
   :expires-at (+ (get-universal-time) 300)  ; 5 minute default
   :difficulty difficulty
   :extranonce1 extranonce1
   :extranonce2-size extranonce2-size))

;;; ============================================================================
;;; COINBASE RECONSTRUCTION
;;; ============================================================================

(defun build-coinbase-from-parts (coinbase1 extranonce1 extranonce2 coinbase2)
  "Reconstruct full coinbase transaction from Stratum parts.

   Miners receive coinbase split into parts:
   - coinbase1: Bytes before extranonce
   - extranonce1: Pool-assigned (unique per miner)
   - extranonce2: Miner-chosen (iterates locally)
   - coinbase2: Bytes after extranonce

   Full coinbase = coinbase1 || extranonce1 || extranonce2 || coinbase2"
  (let ((cb1 (if (stringp coinbase1) (hex-to-bytes coinbase1) coinbase1))
        (en1 (if (stringp extranonce1) (hex-to-bytes extranonce1) extranonce1))
        (en2 (if (stringp extranonce2) (hex-to-bytes extranonce2) extranonce2))
        (cb2 (if (stringp coinbase2) (hex-to-bytes coinbase2) coinbase2)))
    (concatenate-bytes cb1 en1 en2 cb2)))

(defun make-extranonce2 (value size)
  "Create extranonce2 byte vector from integer value.

   VALUE: Integer value for extranonce2
   SIZE: Number of bytes (typically 4)"
  (let ((bytes (make-array size :element-type '(unsigned-byte 8))))
    (loop for i from 0 below size
          do (setf (aref bytes i) (logand (ash value (- (* i 8))) #xff)))
    bytes))

;;; ============================================================================
;;; MERKLE ROOT COMPUTATION
;;; ============================================================================

(defun compute-merkle-root-from-branches (coinbase-hash branches)
  "Compute merkle root from coinbase hash and merkle branches.

   COINBASE-HASH: SHA256d hash of coinbase transaction (32 bytes)
   BRANCHES: List of merkle branch hashes from pool

   The pool provides merkle branches which are sibling hashes needed
   to compute the merkle root. The miner only needs to hash up the tree."
  (let ((current coinbase-hash))
    (dolist (branch branches current)
      (let ((branch-bytes (if (stringp branch)
                              (hex-to-bytes branch)
                              branch)))
        ;; Concatenate current || branch and double-hash
        (setf current (sha256d (concatenate-bytes current branch-bytes)))))))

(defun compute-coinbase-hash (job extranonce2)
  "Compute the hash of the reconstructed coinbase transaction.

   JOB: Stratum job with coinbase parts
   EXTRANONCE2: Miner's extranonce2 value (bytes)"
  (let ((coinbase (build-coinbase-from-parts
                   (stratum-job-coinbase1 job)
                   (stratum-job-extranonce1 job)
                   extranonce2
                   (stratum-job-coinbase2 job))))
    (sha256d coinbase)))

(defun compute-merkle-root-for-job (job extranonce2)
  "Compute merkle root for a job with given extranonce2.

   This is the complete merkle root calculation pipeline:
   1. Build coinbase from parts
   2. Hash coinbase (SHA256d)
   3. Compute merkle root using branches"
  (let ((coinbase-hash (compute-coinbase-hash job extranonce2)))
    (compute-merkle-root-from-branches coinbase-hash
                                       (stratum-job-merkle-branches job))))

;;; ============================================================================
;;; BLOCK HEADER CONSTRUCTION
;;; ============================================================================

(defun build-block-header-from-job (job extranonce2 nonce &optional ntime)
  "Build 80-byte block header from job and miner's nonce.

   JOB: Stratum job (plist or stratum-job struct)
   EXTRANONCE2: Miner's extranonce2 (bytes)
   NONCE: Block nonce (32-bit integer)
   NTIME: Optional timestamp override (defaults to job's ntime)

   Returns 80-byte block header ready for hashing.

   BLOCK HEADER FORMAT (80 bytes):
   - Version: 4 bytes (little-endian)
   - Previous hash: 32 bytes (already byte-swapped from pool)
   - Merkle root: 32 bytes
   - Timestamp: 4 bytes (little-endian)
   - Bits: 4 bytes (little-endian)
   - Nonce: 4 bytes (little-endian)"
  (let* ((version (if (stratum-job-p job)
                      (stratum-job-version job)
                      (parse-integer (getf job :version) :radix 16)))
         (prev-hash (if (stratum-job-p job)
                        (stratum-job-prev-hash job)
                        (hex-to-bytes (getf job :prev-hash))))
         (merkle-root (compute-merkle-root-for-job
                       (if (stratum-job-p job)
                           job
                           (make-stratum-job
                            :coinbase1 (hex-to-bytes (getf job :coinbase1))
                            :coinbase2 (hex-to-bytes (getf job :coinbase2))
                            :merkle-branches (mapcar #'hex-to-bytes
                                                     (getf job :merkle-branches))
                            :extranonce1 (hex-to-bytes (getf job :extranonce1))))
                       extranonce2))
         (timestamp (or ntime
                        (if (stratum-job-p job)
                            (stratum-job-ntime job)
                            (parse-integer (getf job :ntime) :radix 16))))
         (bits (if (stratum-job-p job)
                   (stratum-job-nbits job)
                   (parse-integer (getf job :nbits) :radix 16)))
         (header (make-array 80 :element-type '(unsigned-byte 8))))

    ;; Version (4 bytes, little-endian)
    (setf (aref header 0) (logand version #xff))
    (setf (aref header 1) (logand (ash version -8) #xff))
    (setf (aref header 2) (logand (ash version -16) #xff))
    (setf (aref header 3) (logand (ash version -24) #xff))

    ;; Previous hash (32 bytes, reversed for display but stored as-is from pool)
    (replace header (reverse-bytes prev-hash) :start1 4)

    ;; Merkle root (32 bytes)
    (replace header merkle-root :start1 36)

    ;; Timestamp (4 bytes, little-endian)
    (setf (aref header 68) (logand timestamp #xff))
    (setf (aref header 69) (logand (ash timestamp -8) #xff))
    (setf (aref header 70) (logand (ash timestamp -16) #xff))
    (setf (aref header 71) (logand (ash timestamp -24) #xff))

    ;; Bits (4 bytes, little-endian)
    (setf (aref header 72) (logand bits #xff))
    (setf (aref header 73) (logand (ash bits -8) #xff))
    (setf (aref header 74) (logand (ash bits -16) #xff))
    (setf (aref header 75) (logand (ash bits -24) #xff))

    ;; Nonce (4 bytes, little-endian)
    (setf (aref header 76) (logand nonce #xff))
    (setf (aref header 77) (logand (ash nonce -8) #xff))
    (setf (aref header 78) (logand (ash nonce -16) #xff))
    (setf (aref header 79) (logand (ash nonce -24) #xff))

    header))

(defun hash-block-header (header)
  "Compute the double SHA-256 hash of an 80-byte block header."
  (sha256d header))

(defun check-header-meets-target (header target)
  "Check if a block header hash meets the difficulty target.

   HEADER: 80-byte block header
   TARGET: Difficulty target as integer

   Returns T if hash < target (valid proof of work)."
  (let ((hash (hash-block-header header)))
    (hash-meets-target-p hash target)))

;;; ============================================================================
;;; JOB CACHE
;;; ============================================================================

(defstruct job-cache
  "Cache of active mining jobs for share validation."
  (jobs (make-hash-table :test 'equal) :type hash-table)
  (max-jobs 20 :type fixnum)
  (lock (bt:make-lock "job-cache")))

(defun cache-job (cache job)
  "Add a job to the cache, evicting oldest if necessary."
  (bt:with-lock-held ((job-cache-lock cache))
    (let ((jobs (job-cache-jobs cache))
          (job-id (if (stratum-job-p job)
                      (stratum-job-job-id job)
                      (getf job :job-id))))
      ;; Add new job
      (setf (gethash job-id jobs) job)

      ;; Evict expired jobs
      (let ((now (get-universal-time))
            (to-remove nil))
        (maphash (lambda (id j)
                   (when (and (stratum-job-p j)
                              (> now (stratum-job-expires-at j)))
                     (push id to-remove)))
                 jobs)
        (dolist (id to-remove)
          (remhash id jobs)))

      ;; Evict oldest if over limit
      (when (> (hash-table-count jobs) (job-cache-max-jobs cache))
        (let ((oldest-id nil)
              (oldest-time most-positive-fixnum))
          (maphash (lambda (id j)
                     (let ((created (if (stratum-job-p j)
                                        (stratum-job-created-at j)
                                        (getf j :received-at 0))))
                       (when (< created oldest-time)
                         (setf oldest-id id
                               oldest-time created))))
                   jobs)
          (when oldest-id
            (remhash oldest-id jobs)))))))

(defun get-cached-job (cache job-id)
  "Retrieve a job from the cache by ID."
  (bt:with-lock-held ((job-cache-lock cache))
    (let ((job (gethash job-id (job-cache-jobs cache))))
      (when job
        (let ((expires (if (stratum-job-p job)
                           (stratum-job-expires-at job)
                           (+ (getf job :received-at 0) 300))))
          (when (< (get-universal-time) expires)
            job))))))

(defun clear-job-cache (cache)
  "Clear all jobs from the cache."
  (bt:with-lock-held ((job-cache-lock cache))
    (clrhash (job-cache-jobs cache))))
