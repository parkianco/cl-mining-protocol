;;;; Copyright (c) 2024-2026 Parkian Company LLC. All rights reserved.
;;;; SPDX-License-Identifier: BSD-3-Clause

;;;; stratum.lisp - Stratum Protocol Client Implementation
;;;;
;;;; Implements the Stratum mining protocol v1 for connecting to mining pools.
;;;; Handles subscription, authorization, job reception, and share submission.

(in-package #:cl-mining-protocol)

;;; ============================================================================
;;; STRATUM POOL CONFIGURATION
;;; ============================================================================

(defstruct stratum-pool-config
  "Configuration for a single mining pool."
  (host "localhost" :type string)
  (port 3333 :type fixnum)
  (username "" :type string)
  (password "x" :type string)
  (priority 0 :type fixnum)
  (weight 1 :type fixnum)
  (enabled-p t :type boolean))

(defstruct stratum-client-config
  "Configuration for the Stratum client."
  (pools (list) :type list)
  (connect-timeout 10 :type fixnum)
  (read-timeout 30 :type fixnum)
  (reconnect-delay 5 :type fixnum)
  (max-reconnect-delay 300 :type fixnum)
  (ping-interval 30 :type fixnum)
  (stale-job-threshold 120 :type fixnum)
  (auto-reconnect-p t :type boolean))

;;; ============================================================================
;;; STRATUM CLIENT STATE
;;; ============================================================================

(defstruct stratum-client
  "Stratum mining client for connecting to pools.

   STATE MACHINE:
   disconnected -> connecting -> subscribing -> authorizing -> mining
        ^                                                        |
        |__________________ on error/timeout ___________________|"
  ;; Configuration
  (config nil :type (or null stratum-client-config))
  ;; Connection state
  (socket nil)
  (stream nil)
  (state :disconnected :type symbol)
  (current-pool nil)
  (pool-index 0 :type fixnum)
  ;; Stratum session data
  (subscription-id "" :type string)
  (extranonce1 (make-array 0 :element-type '(unsigned-byte 8))
   :type (vector (unsigned-byte 8)))
  (extranonce2-size 4 :type fixnum)
  (current-difficulty 1.0d0 :type double-float)
  ;; Job management
  (current-job nil)
  (jobs (make-hash-table :test 'equal))
  ;; Share tracking
  (shares-submitted 0 :type integer)
  (shares-accepted 0 :type integer)
  (shares-rejected 0 :type integer)
  (last-share-time 0 :type integer)
  ;; Connection management
  (connected-at 0 :type integer)
  (last-activity 0 :type integer)
  (reconnect-attempts 0 :type fixnum)
  (reconnect-delay 5 :type fixnum)
  (running-p nil :type boolean)
  ;; Thread management
  (reader-thread nil)
  (lock (bt:make-lock "stratum-client"))
  (request-id 0 :type integer)
  (pending-requests (make-hash-table))
  ;; Callbacks
  (on-connect nil :type (or null function))
  (on-disconnect nil :type (or null function))
  (on-job nil :type (or null function))
  (on-share-result nil :type (or null function))
  (on-difficulty nil :type (or null function)))

;;; ============================================================================
;;; CLIENT LIFECYCLE
;;; ============================================================================

(defun make-stratum-client-instance (&key pools
                                          (connect-timeout 10)
                                          (read-timeout 30)
                                          (auto-reconnect t)
                                          on-connect
                                          on-disconnect
                                          on-job
                                          on-share-result
                                          on-difficulty)
  "Create a new Stratum client instance.
   POOLS: List of pool configs or plists with :host :port :username :password"
  (let* ((pool-configs (mapcar #'normalize-pool-config pools))
         (config (make-stratum-client-config
                  :pools pool-configs
                  :connect-timeout connect-timeout
                  :read-timeout read-timeout
                  :auto-reconnect-p auto-reconnect)))
    (make-stratum-client
     :config config
     :on-connect on-connect
     :on-disconnect on-disconnect
     :on-job on-job
     :on-share-result on-share-result
     :on-difficulty on-difficulty)))

(defun normalize-pool-config (pool)
  "Convert pool specification to stratum-pool-config."
  (etypecase pool
    (stratum-pool-config pool)
    (list
     (make-stratum-pool-config
      :host (getf pool :host "localhost")
      :port (getf pool :port 3333)
      :username (getf pool :username "")
      :password (getf pool :password "x")
      :priority (getf pool :priority 0)
      :enabled-p (getf pool :enabled t)))))

(defun stratum-client-add-pool (client host port username &key (password "x") (priority 10))
  "Add a pool to the client's pool list."
  (let ((pool-config (make-stratum-pool-config
                      :host host
                      :port port
                      :username username
                      :password password
                      :priority priority)))
    (bt:with-lock-held ((stratum-client-lock client))
      (let* ((config (stratum-client-config client))
             (pools (stratum-client-config-pools config)))
        (setf (stratum-client-config-pools config)
              (sort (cons pool-config pools)
                    #'< :key #'stratum-pool-config-priority))))
    t))

(defun stratum-client-connect (client)
  "Connect to a mining pool. Returns T on success, NIL on failure."
  (bt:with-lock-held ((stratum-client-lock client))
    (when (stratum-client-running-p client)
      (return-from stratum-client-connect nil))
    (setf (stratum-client-running-p client) t))

  (let ((pools (stratum-client-config-pools (stratum-client-config client))))
    (loop for pool in pools
          for i from 0
          when (stratum-pool-config-enabled-p pool)
          do (when (attempt-pool-connection client pool i)
               (return-from stratum-client-connect t))))

  (bt:with-lock-held ((stratum-client-lock client))
    (setf (stratum-client-running-p client) nil))
  nil)

(defun attempt-pool-connection (client pool-config pool-index)
  "Attempt to connect to a specific pool. Returns T on success."
  (let ((host (stratum-pool-config-host pool-config))
        (port (stratum-pool-config-port pool-config))
        (timeout (stratum-client-config-connect-timeout
                  (stratum-client-config client))))
    (handler-case
        (let ((socket (usocket:socket-connect host port
                                              :timeout timeout
                                              :element-type 'character)))
          (bt:with-lock-held ((stratum-client-lock client))
            (setf (stratum-client-socket client) socket
                  (stratum-client-stream client) (usocket:socket-stream socket)
                  (stratum-client-current-pool client) pool-config
                  (stratum-client-pool-index client) pool-index
                  (stratum-client-state client) :connecting
                  (stratum-client-connected-at client) (get-universal-time)
                  (stratum-client-last-activity client) (get-universal-time)
                  (stratum-client-reconnect-attempts client) 0
                  (stratum-client-reconnect-delay client)
                  (stratum-client-config-reconnect-delay
                   (stratum-client-config client))))

          ;; Start reader thread
          (setf (stratum-client-reader-thread client)
                (bt:make-thread
                 (lambda () (stratum-client-reader-loop client))
                 :name "stratum-reader"))

          ;; Perform Stratum handshake
          (when (stratum-client-handshake client)
            (when (stratum-client-on-connect client)
              (funcall (stratum-client-on-connect client) client))
            t))
      (error (e)
        (declare (ignore e))
        nil))))

(defun stratum-client-handshake (client)
  "Perform Stratum handshake (subscribe + authorize). Returns T on success."
  (let ((pool (stratum-client-current-pool client)))
    ;; Subscribe
    (setf (stratum-client-state client) :subscribing)
    (multiple-value-bind (result error)
        (stratum-client-subscribe client)
      (declare (ignore error))
      (unless result
        (return-from stratum-client-handshake nil)))

    ;; Authorize
    (setf (stratum-client-state client) :authorizing)
    (multiple-value-bind (result error)
        (stratum-client-authorize client
                                  (stratum-pool-config-username pool)
                                  (stratum-pool-config-password pool))
      (declare (ignore error))
      (unless result
        (return-from stratum-client-handshake nil)))

    (setf (stratum-client-state client) :mining)
    t))

(defun stratum-client-disconnect (client &optional (reason :user-requested))
  "Disconnect from the current pool."
  (declare (ignore reason))
  (bt:with-lock-held ((stratum-client-lock client))
    (setf (stratum-client-running-p client) nil)
    (setf (stratum-client-state client) :disconnected)

    (when (stratum-client-socket client)
      (handler-case
          (usocket:socket-close (stratum-client-socket client))
        (error (e) (declare (ignore e))))
      (setf (stratum-client-socket client) nil
            (stratum-client-stream client) nil))

    (setf (stratum-client-current-job client) nil)
    (clrhash (stratum-client-jobs client)))

  (when (stratum-client-on-disconnect client)
    (funcall (stratum-client-on-disconnect client) client reason))
  t)

(defun stratum-client-connected-p (client)
  "Check if client is connected and mining."
  (eq (stratum-client-state client) :mining))

;;; ============================================================================
;;; STRATUM PROTOCOL REQUESTS
;;; ============================================================================

(defun stratum-client-subscribe (client)
  "Send mining.subscribe request. Returns (values T nil) on success."
  (let ((response (stratum-client-request client "mining.subscribe"
                                          (list "cl-mining-protocol/1.0"))))
    (when response
      (let ((result (cdr (assoc :result response))))
        (when result
          (let ((subscriptions (first result))
                (extranonce1-hex (second result))
                (extranonce2-size (third result)))
            (declare (ignore subscriptions))
            (bt:with-lock-held ((stratum-client-lock client))
              (setf (stratum-client-extranonce1 client)
                    (hex-to-bytes extranonce1-hex))
              (setf (stratum-client-extranonce2-size client)
                    extranonce2-size))
            (values t nil)))))
    (values nil "Subscribe failed")))

(defun stratum-client-authorize (client username password)
  "Send mining.authorize request. Returns (values T nil) on success."
  (let ((response (stratum-client-request client "mining.authorize"
                                          (list username password))))
    (if (and response (cdr (assoc :result response)))
        (values t nil)
        (values nil "Authorization failed"))))

(defun stratum-client-submit-share (client job-id extranonce2 ntime nonce)
  "Submit a share to the pool. Returns T if submitted."
  (let ((pool (stratum-client-current-pool client)))
    (unless pool
      (return-from stratum-client-submit-share nil))

    (let* ((username (stratum-pool-config-username pool))
           (extranonce2-hex (if (stringp extranonce2)
                                extranonce2
                                (bytes-to-hex extranonce2)))
           (ntime-hex (if (stringp ntime)
                          ntime
                          (format nil "~8,'0x" ntime)))
           (nonce-hex (if (stringp nonce)
                          nonce
                          (format nil "~8,'0x" nonce))))

      (bt:with-lock-held ((stratum-client-lock client))
        (incf (stratum-client-shares-submitted client))
        (setf (stratum-client-last-share-time client) (get-universal-time)))

      ;; Send async
      (stratum-client-request-async client "mining.submit"
                                    (list username job-id extranonce2-hex
                                          ntime-hex nonce-hex)
                                    (lambda (result error)
                                      (stratum-client-handle-share-result
                                       client result error)))
      t)))

;;; ============================================================================
;;; MESSAGE HANDLING
;;; ============================================================================

(defun stratum-client-reader-loop (client)
  "Read and dispatch messages from pool (runs in reader thread)."
  (handler-case
      (loop while (stratum-client-running-p client)
            do (let ((message (stratum-client-read-message client)))
                 (when message
                   (bt:with-lock-held ((stratum-client-lock client))
                     (setf (stratum-client-last-activity client)
                           (get-universal-time)))
                   (stratum-client-dispatch-message client message))))
    (error (e)
      (declare (ignore e))
      (stratum-client-handle-disconnect client :error))))

(defun stratum-client-dispatch-message (client message)
  "Dispatch a received message to appropriate handler."
  (let ((id (cdr (assoc :id message)))
        (method (cdr (assoc :method message)))
        (params (cdr (assoc :params message))))
    (cond
      ;; Response to a request
      ((and id (not (eq id :null)))
       (stratum-client-handle-response client message))
      ;; Notification
      (method
       (cond
         ((string= method "mining.notify")
          (stratum-client-handle-job client params))
         ((string= method "mining.set_difficulty")
          (stratum-client-handle-difficulty client params)))))))

(defun stratum-client-handle-response (client message)
  "Handle response to a pending request."
  (let* ((id (cdr (assoc :id message)))
         (callback (gethash id (stratum-client-pending-requests client))))
    (when callback
      (remhash id (stratum-client-pending-requests client))
      (let ((result (cdr (assoc :result message)))
            (error (cdr (assoc :error message))))
        (funcall callback result error)))))

(defun stratum-client-handle-job (client params)
  "Handle mining.notify notification - new job received."
  (let* ((job-id (nth 0 params))
         (prev-hash (nth 1 params))
         (coinbase1 (nth 2 params))
         (coinbase2 (nth 3 params))
         (merkle-branches (nth 4 params))
         (version (nth 5 params))
         (nbits (nth 6 params))
         (ntime (nth 7 params))
         (clean-jobs (nth 8 params))
         (job (list :job-id job-id
                    :prev-hash prev-hash
                    :coinbase1 coinbase1
                    :coinbase2 coinbase2
                    :merkle-branches merkle-branches
                    :version version
                    :nbits nbits
                    :ntime ntime
                    :clean-jobs clean-jobs
                    :received-at (get-universal-time)
                    :extranonce1 (bytes-to-hex (stratum-client-extranonce1 client))
                    :extranonce2-size (stratum-client-extranonce2-size client)
                    :difficulty (stratum-client-current-difficulty client))))

    (bt:with-lock-held ((stratum-client-lock client))
      (when clean-jobs
        (clrhash (stratum-client-jobs client)))
      (setf (gethash job-id (stratum-client-jobs client)) job)
      (setf (stratum-client-current-job client) job))

    (when (stratum-client-on-job client)
      (funcall (stratum-client-on-job client) client job))))

(defun stratum-client-handle-difficulty (client params)
  "Handle mining.set_difficulty notification."
  (let ((difficulty (coerce (first params) 'double-float)))
    (bt:with-lock-held ((stratum-client-lock client))
      (setf (stratum-client-current-difficulty client) difficulty))
    (when (stratum-client-on-difficulty client)
      (funcall (stratum-client-on-difficulty client) client difficulty))))

(defun stratum-client-handle-share-result (client result error)
  "Handle share submission result."
  (bt:with-lock-held ((stratum-client-lock client))
    (if result
        (incf (stratum-client-shares-accepted client))
        (incf (stratum-client-shares-rejected client))))

  (when (stratum-client-on-share-result client)
    (funcall (stratum-client-on-share-result client)
             client result error)))

(defun stratum-client-handle-disconnect (client reason)
  "Handle unexpected disconnection."
  (let ((was-running (stratum-client-running-p client)))
    (stratum-client-disconnect client reason)
    (when (and was-running
               (stratum-client-config-auto-reconnect-p
                (stratum-client-config client)))
      (stratum-client-reconnect client))))

(defun stratum-client-reconnect (client)
  "Attempt to reconnect with exponential backoff."
  (let* ((config (stratum-client-config client))
         (max-delay (stratum-client-config-max-reconnect-delay config))
         (current-delay (stratum-client-reconnect-delay client)))
    (sleep current-delay)
    (bt:with-lock-held ((stratum-client-lock client))
      (incf (stratum-client-reconnect-attempts client))
      (setf (stratum-client-reconnect-delay client)
            (min max-delay (* current-delay 2))))
    (stratum-client-connect client)))

;;; ============================================================================
;;; LOW-LEVEL I/O
;;; ============================================================================

(defun stratum-client-read-message (client)
  "Read a JSON-RPC message from the pool. Returns parsed JSON or NIL."
  (let ((stream (stratum-client-stream client)))
    (unless stream
      (return-from stratum-client-read-message nil))
    (handler-case
        (let ((line (read-line stream nil nil)))
          (when line
            (parse-json line)))
      (error () nil))))

(defun stratum-client-send-message (client message)
  "Send a JSON-RPC message to the pool. Returns T on success."
  (let ((stream (stratum-client-stream client)))
    (unless stream
      (return-from stratum-client-send-message nil))
    (handler-case
        (progn
          (write-line (encode-json message) stream)
          (force-output stream)
          t)
      (error () nil))))

(defun stratum-client-request (client method params &key (timeout 10))
  "Send a synchronous request and wait for response."
  (declare (ignore timeout))
  (let* ((id (bt:with-lock-held ((stratum-client-lock client))
               (incf (stratum-client-request-id client))))
         (response nil)
         (response-lock (bt:make-lock))
         (response-cv (bt:make-condition-variable)))

    (setf (gethash id (stratum-client-pending-requests client))
          (lambda (result error)
            (bt:with-lock-held (response-lock)
              (setf response (list (cons :result result)
                                   (cons :error error)))
              (bt:condition-notify response-cv))))

    (unless (stratum-client-send-message client
              (list (cons :id id)
                    (cons :method method)
                    (cons :params params)))
      (remhash id (stratum-client-pending-requests client))
      (return-from stratum-client-request nil))

    ;; Wait for response (simple polling for portability)
    (loop repeat 100  ; 10 seconds at 100ms intervals
          until response
          do (sleep 0.1))

    response))

(defun stratum-client-request-async (client method params callback)
  "Send an asynchronous request with callback."
  (let ((id (bt:with-lock-held ((stratum-client-lock client))
              (incf (stratum-client-request-id client)))))
    (setf (gethash id (stratum-client-pending-requests client)) callback)
    (if (stratum-client-send-message client
          (list (cons :id id)
                (cons :method method)
                (cons :params params)))
        id
        (progn
          (remhash id (stratum-client-pending-requests client))
          nil))))

;;; ============================================================================
;;; STATISTICS
;;; ============================================================================

(defun stratum-client-get-stats (client)
  "Get client statistics."
  (bt:with-lock-held ((stratum-client-lock client))
    (let ((pool (stratum-client-current-pool client)))
      (list :state (stratum-client-state client)
            :pool-host (when pool (stratum-pool-config-host pool))
            :pool-port (when pool (stratum-pool-config-port pool))
            :connected-at (stratum-client-connected-at client)
            :uptime (if (stratum-client-connected-at client)
                        (- (get-universal-time)
                           (stratum-client-connected-at client))
                        0)
            :difficulty (stratum-client-current-difficulty client)
            :shares-submitted (stratum-client-shares-submitted client)
            :shares-accepted (stratum-client-shares-accepted client)
            :shares-rejected (stratum-client-shares-rejected client)
            :accept-rate (let ((total (stratum-client-shares-submitted client)))
                           (if (plusp total)
                               (* 100.0 (/ (stratum-client-shares-accepted client)
                                           total))
                               0.0))
            :extranonce1 (bytes-to-hex (stratum-client-extranonce1 client))
            :extranonce2-size (stratum-client-extranonce2-size client)
            :current-job-id (when (stratum-client-current-job client)
                              (getf (stratum-client-current-job client) :job-id))))))

;;; ============================================================================
;;; MINIMAL JSON PARSER/ENCODER (for standalone use)
;;; ============================================================================

(defun parse-json (string)
  "Simple JSON parser returning alist. Handles basic Stratum messages."
  (let ((pos 0)
        (len (length string)))
    (labels ((skip-ws ()
               (loop while (and (< pos len)
                                (member (char string pos) '(#\Space #\Tab #\Newline #\Return)))
                     do (incf pos)))
             (peek () (and (< pos len) (char string pos)))
             (consume () (prog1 (char string pos) (incf pos)))
             (parse-value ()
               (skip-ws)
               (case (peek)
                 (#\{ (parse-object))
                 (#\[ (parse-array))
                 (#\" (parse-string))
                 ((#\- #\0 #\1 #\2 #\3 #\4 #\5 #\6 #\7 #\8 #\9) (parse-number))
                 (#\t (consume) (consume) (consume) (consume) t)  ; true
                 (#\f (consume) (consume) (consume) (consume) (consume) nil)  ; false
                 (#\n (consume) (consume) (consume) (consume) :null)  ; null
                 (otherwise nil)))
             (parse-object ()
               (consume)  ; {
               (skip-ws)
               (if (eql (peek) #\})
                   (progn (consume) nil)
                   (loop collect (progn
                                   (skip-ws)
                                   (let ((key (parse-string)))
                                     (skip-ws) (consume)  ; :
                                     (cons (intern (string-upcase key) :keyword)
                                           (parse-value))))
                         while (progn (skip-ws) (eql (peek) #\,))
                         do (consume)
                         finally (skip-ws) (consume))))  ; }
             (parse-array ()
               (consume)  ; [
               (skip-ws)
               (if (eql (peek) #\])
                   (progn (consume) nil)
                   (loop collect (parse-value)
                         while (progn (skip-ws) (eql (peek) #\,))
                         do (consume)
                         finally (skip-ws) (consume))))  ; ]
             (parse-string ()
               (consume)  ; "
               (with-output-to-string (s)
                 (loop for c = (consume)
                       until (eql c #\")
                       do (if (eql c #\\)
                              (write-char (case (consume)
                                            (#\n #\Newline) (#\t #\Tab)
                                            (#\r #\Return) (otherwise (char string (1- pos))))
                                          s)
                              (write-char c s)))))
             (parse-number ()
               (let ((start pos))
                 (when (eql (peek) #\-) (consume))
                 (loop while (and (< pos len) (digit-char-p (peek))) do (consume))
                 (when (eql (peek) #\.)
                   (consume)
                   (loop while (and (< pos len) (digit-char-p (peek))) do (consume)))
                 (when (member (peek) '(#\e #\E))
                   (consume)
                   (when (member (peek) '(#\+ #\-)) (consume))
                   (loop while (and (< pos len) (digit-char-p (peek))) do (consume)))
                 (let ((str (subseq string start pos)))
                   (if (find #\. str)
                       (read-from-string str)
                       (parse-integer str))))))
      (parse-value))))

(defun encode-json (obj)
  "Simple JSON encoder for alists, lists, strings, numbers, and booleans."
  (with-output-to-string (s)
    (labels ((encode (x)
               (cond
                 ((null x) (write-string "null" s))
                 ((eq x t) (write-string "true" s))
                 ((eq x :null) (write-string "null" s))
                 ((stringp x)
                  (write-char #\" s)
                  (loop for c across x
                        do (case c
                             (#\" (write-string "\\\"" s))
                             (#\\ (write-string "\\\\" s))
                             (#\Newline (write-string "\\n" s))
                             (#\Tab (write-string "\\t" s))
                             (#\Return (write-string "\\r" s))
                             (otherwise (write-char c s))))
                  (write-char #\" s))
                 ((numberp x) (format s "~A" x))
                 ((and (consp x) (consp (car x)) (keywordp (caar x)))
                  ;; alist (object)
                  (write-char #\{ s)
                  (loop for (pair . rest) on x
                        do (format s "~S:" (string-downcase (symbol-name (car pair))))
                           (encode (cdr pair))
                        when rest do (write-char #\, s))
                  (write-char #\} s))
                 ((listp x)
                  ;; array
                  (write-char #\[ s)
                  (loop for (item . rest) on x
                        do (encode item)
                        when rest do (write-char #\, s))
                  (write-char #\] s))
                 (t (write-string "null" s)))))
      (encode obj))))
