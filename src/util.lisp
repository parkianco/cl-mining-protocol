;;;; Copyright (c) 2024-2026 Parkian Company LLC. All rights reserved.
;;;; SPDX-License-Identifier: Apache-2.0

;;;; util.lisp - Utility functions including inlined SHA256d

(in-package #:cl-mining-protocol)

;;; ============================================================================
;;; BYTE MANIPULATION UTILITIES
;;; ============================================================================

(defun bytes-to-hex (bytes)
  "Convert byte vector to lowercase hexadecimal string."
  (with-output-to-string (s)
    (loop for byte across bytes
          do (format s "~2,'0x" byte))))

(defun hex-to-bytes (hex-string)
  "Convert hexadecimal string to byte vector."
  (let* ((len (length hex-string))
         (bytes (make-array (/ len 2) :element-type '(unsigned-byte 8))))
    (loop for i from 0 below len by 2
          for j from 0
          do (setf (aref bytes j)
                   (parse-integer hex-string :start i :end (+ i 2) :radix 16)))
    bytes))

(defun reverse-bytes (bytes)
  "Reverse byte order (for endianness conversion)."
  (let ((len (length bytes)))
    (let ((result (make-array len :element-type '(unsigned-byte 8))))
      (loop for i from 0 below len
            do (setf (aref result i) (aref bytes (- len 1 i))))
      result)))

(defun reverse-bytes-to-hex (bytes)
  "Reverse bytes and convert to hex (common for Bitcoin hashes)."
  (bytes-to-hex (reverse-bytes bytes)))

(defun concatenate-bytes (&rest byte-vectors)
  "Concatenate multiple byte vectors into one."
  (apply #'concatenate '(vector (unsigned-byte 8)) byte-vectors))

(defun integer-to-bytes-le (n size)
  "Convert integer to little-endian byte vector of specified size."
  (let ((bytes (make-array size :element-type '(unsigned-byte 8))))
    (loop for i from 0 below size
          do (setf (aref bytes i) (logand (ash n (- (* i 8))) #xff)))
    bytes))

(defun bytes-to-integer-le (bytes)
  "Convert little-endian bytes to integer."
  (loop for i from 0 below (length bytes)
        sum (ash (aref bytes i) (* i 8))))

;;; ============================================================================
;;; SHA-256 IMPLEMENTATION (INLINED FOR STANDALONE USE)
;;; ============================================================================
;;;
;;; This is a pure Common Lisp implementation of SHA-256, required for
;;; computing block header hashes (SHA256d = double SHA-256).

(defparameter *sha256-k*
  (make-array 64 :element-type '(unsigned-byte 32) :initial-contents
              '(#x428a2f98 #x71374491 #xb5c0fbcf #xe9b5dba5 #x3956c25b #x59f111f1 #x923f82a4 #xab1c5ed5
                #xd807aa98 #x12835b01 #x243185be #x550c7dc3 #x72be5d74 #x80deb1fe #x9bdc06a7 #xc19bf174
                #xe49b69c1 #xefbe4786 #x0fc19dc6 #x240ca1cc #x2de92c6f #x4a7484aa #x5cb0a9dc #x76f988da
                #x983e5152 #xa831c66d #xb00327c8 #xbf597fc7 #xc6e00bf3 #xd5a79147 #x06ca6351 #x14292967
                #x27b70a85 #x2e1b2138 #x4d2c6dfc #x53380d13 #x650a7354 #x766a0abb #x81c2c92e #x92722c85
                #xa2bfe8a1 #xa81a664b #xc24b8b70 #xc76c51a3 #xd192e819 #xd6990624 #xf40e3585 #x106aa070
                #x19a4c116 #x1e376c08 #x2748774c #x34b0bcb5 #x391c0cb3 #x4ed8aa4a #x5b9cca4f #x682e6ff3
                #x748f82ee #x78a5636f #x84c87814 #x8cc70208 #x90befffa #xa4506ceb #xbef9a3f7 #xc67178f2))
  "SHA-256 round constants (first 32 bits of fractional parts of cube roots of first 64 primes).")

(defparameter *sha256-h0*
  (make-array 8 :element-type '(unsigned-byte 32)
              :initial-contents '(#x6a09e667 #xbb67ae85 #x3c6ef372 #xa54ff53a
                                  #x510e527f #x9b05688c #x1f83d9ab #x5be0cd19))
  "SHA-256 initial hash values (first 32 bits of fractional parts of square roots of first 8 primes).")

;;; SHA-256 helper macros (inline for performance)

(defmacro rotr32 (x n)
  "32-bit right rotation."
  `(logior (ldb (byte 32 0) (ash ,x (- ,n)))
           (ldb (byte 32 0) (ash ,x (- 32 ,n)))))

(defmacro shr32 (x n)
  "32-bit right shift."
  `(ash ,x (- ,n)))

(defmacro sha256-ch (x y z)
  "SHA-256 Ch function: (x AND y) XOR ((NOT x) AND z)"
  `(logxor (logand ,x ,y) (logand (lognot ,x) ,z)))

(defmacro sha256-maj (x y z)
  "SHA-256 Maj function: (x AND y) XOR (x AND z) XOR (y AND z)"
  `(logxor (logand ,x ,y) (logand ,x ,z) (logand ,y ,z)))

(defmacro sha256-sigma0 (x)
  "SHA-256 big Sigma0: ROTR^2(x) XOR ROTR^13(x) XOR ROTR^22(x)"
  `(logxor (rotr32 ,x 2) (rotr32 ,x 13) (rotr32 ,x 22)))

(defmacro sha256-sigma1 (x)
  "SHA-256 big Sigma1: ROTR^6(x) XOR ROTR^11(x) XOR ROTR^25(x)"
  `(logxor (rotr32 ,x 6) (rotr32 ,x 11) (rotr32 ,x 25)))

(defmacro sha256-gamma0 (x)
  "SHA-256 small sigma0: ROTR^7(x) XOR ROTR^18(x) XOR SHR^3(x)"
  `(logxor (rotr32 ,x 7) (rotr32 ,x 18) (shr32 ,x 3)))

(defmacro sha256-gamma1 (x)
  "SHA-256 small sigma1: ROTR^17(x) XOR ROTR^19(x) XOR SHR^10(x)"
  `(logxor (rotr32 ,x 17) (rotr32 ,x 19) (shr32 ,x 10)))

(defun sha256-pad-message (message)
  "Pad message according to SHA-256 specification.
   Append bit '1', then zeros, then 64-bit big-endian length."
  (let* ((len (length message))
         (bit-len (* len 8))
         ;; Padding: 1 byte for 0x80, then zeros to make (len + pad) mod 64 = 56
         (pad-len (let ((mod (mod (+ len 1) 64)))
                    (if (<= mod 56)
                        (- 56 mod)
                        (- 120 mod))))
         (total-len (+ len 1 pad-len 8))
         (padded (make-array total-len :element-type '(unsigned-byte 8))))
    ;; Copy message
    (loop for i from 0 below len
          do (setf (aref padded i) (aref message i)))
    ;; Append 0x80
    (setf (aref padded len) #x80)
    ;; Zeros already there (initial-element 0)
    ;; Append 64-bit big-endian length
    (loop for i from 0 below 8
          do (setf (aref padded (+ len 1 pad-len i))
                   (ldb (byte 8 (* (- 7 i) 8)) bit-len)))
    padded))

(defun sha256-process-block (block h)
  "Process a single 512-bit (64-byte) block.
   BLOCK is a 64-byte vector, H is the 8-word hash state (modified in place)."
  (declare (optimize (speed 3) (safety 1)))
  (let ((w (make-array 64 :element-type '(unsigned-byte 32)))
        (a (aref h 0)) (b (aref h 1)) (c (aref h 2)) (d (aref h 3))
        (e (aref h 4)) (f (aref h 5)) (g (aref h 6)) (hh (aref h 7)))
    ;; Prepare message schedule (first 16 words from block, big-endian)
    (loop for i from 0 below 16
          do (setf (aref w i)
                   (logior (ash (aref block (* i 4)) 24)
                           (ash (aref block (+ (* i 4) 1)) 16)
                           (ash (aref block (+ (* i 4) 2)) 8)
                           (aref block (+ (* i 4) 3)))))
    ;; Extend message schedule
    (loop for i from 16 below 64
          do (setf (aref w i)
                   (ldb (byte 32 0)
                        (+ (sha256-gamma1 (aref w (- i 2)))
                           (aref w (- i 7))
                           (sha256-gamma0 (aref w (- i 15)))
                           (aref w (- i 16))))))
    ;; Compression function main loop
    (loop for i from 0 below 64
          do (let* ((s1 (sha256-sigma1 e))
                    (ch (sha256-ch e f g))
                    (temp1 (ldb (byte 32 0)
                                (+ hh s1 ch (aref *sha256-k* i) (aref w i))))
                    (s0 (sha256-sigma0 a))
                    (maj (sha256-maj a b c))
                    (temp2 (ldb (byte 32 0) (+ s0 maj))))
               (setf hh g
                     g f
                     f e
                     e (ldb (byte 32 0) (+ d temp1))
                     d c
                     c b
                     b a
                     a (ldb (byte 32 0) (+ temp1 temp2)))))
    ;; Add compressed chunk to hash
    (setf (aref h 0) (ldb (byte 32 0) (+ (aref h 0) a)))
    (setf (aref h 1) (ldb (byte 32 0) (+ (aref h 1) b)))
    (setf (aref h 2) (ldb (byte 32 0) (+ (aref h 2) c)))
    (setf (aref h 3) (ldb (byte 32 0) (+ (aref h 3) d)))
    (setf (aref h 4) (ldb (byte 32 0) (+ (aref h 4) e)))
    (setf (aref h 5) (ldb (byte 32 0) (+ (aref h 5) f)))
    (setf (aref h 6) (ldb (byte 32 0) (+ (aref h 6) g)))
    (setf (aref h 7) (ldb (byte 32 0) (+ (aref h 7) hh)))))

(defun sha256 (data)
  "Compute SHA-256 hash of DATA (byte vector).
   Returns 32-byte hash."
  (let ((padded (sha256-pad-message data))
        (h (copy-seq *sha256-h0*)))
    ;; Process each 64-byte block
    (loop for i from 0 below (length padded) by 64
          do (sha256-process-block (subseq padded i (+ i 64)) h))
    ;; Convert hash words to bytes (big-endian)
    (let ((result (make-array 32 :element-type '(unsigned-byte 8))))
      (loop for i from 0 below 8
            for word = (aref h i)
            do (setf (aref result (* i 4)) (ldb (byte 8 24) word))
               (setf (aref result (+ (* i 4) 1)) (ldb (byte 8 16) word))
               (setf (aref result (+ (* i 4) 2)) (ldb (byte 8 8) word))
               (setf (aref result (+ (* i 4) 3)) (ldb (byte 8 0) word)))
      result)))

(defun sha256d (data)
  "Compute double SHA-256 hash (SHA256(SHA256(data))).
   This is the standard hash function for Bitcoin block headers."
  (sha256 (sha256 data)))

;;; ============================================================================
;;; DIFFICULTY AND TARGET FUNCTIONS
;;; ============================================================================

(defun target-from-bits (bits)
  "Convert compact 'bits' representation to full 256-bit target.
   Bitcoin uses this compact format in block headers."
  (let ((exp (logand (ash bits -24) #xff))
        (mant (logand bits #xffffff)))
    (* mant (expt 256 (- exp 3)))))

(defun difficulty-from-target (target)
  "Calculate difficulty from target value.
   Difficulty = max_target / target"
  (if (zerop target)
      most-positive-double-float
      (/ (target-from-bits #x1d00ffff) target)))

(defun hash-meets-target-p (hash target)
  "Check if hash (as bytes, little-endian) meets target.
   Returns T if the hash interpreted as a 256-bit LE integer is < target."
  (let ((hash-int 0))
    ;; Convert hash to integer (little-endian)
    (loop for i from 0 below 32
          do (setf hash-int (+ hash-int (ash (aref hash i) (* i 8)))))
    (< hash-int target)))

;;; ============================================================================
;;; HASHRATE FORMATTING
;;; ============================================================================

(defun format-hashrate (hashrate)
  "Format hashrate with appropriate unit suffix.
   HASHRATE: Hashes per second (float or integer)
   Returns: Human-readable string (e.g., '1.23 GH/s')"
  (cond
    ((< hashrate 1000)
     (format nil "~,2F H/s" hashrate))
    ((< hashrate 1000000)
     (format nil "~,2F KH/s" (/ hashrate 1000)))
    ((< hashrate 1000000000)
     (format nil "~,2F MH/s" (/ hashrate 1000000)))
    ((< hashrate 1000000000000)
     (format nil "~,2F GH/s" (/ hashrate 1000000000)))
    ((< hashrate 1000000000000000)
     (format nil "~,2F TH/s" (/ hashrate 1000000000000)))
    (t
     (format nil "~,2F PH/s" (/ hashrate 1000000000000000)))))

(defun estimate-hashrate-from-shares (shares difficulty time-span)
  "Estimate hashrate from share statistics.
   SHARES: Number of shares submitted
   DIFFICULTY: Share difficulty
   TIME-SPAN: Seconds over which shares were submitted
   Formula: hashrate = (shares * difficulty * 2^32) / time_span"
  (if (plusp time-span)
      (/ (* shares difficulty (expt 2 32)) time-span)
      0.0d0))
