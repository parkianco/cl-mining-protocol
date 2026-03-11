# cl-mining-protocol

Stratum pool mining protocol for Bitcoin-compatible blockchains with **zero external dependencies**.

## Features

- **Stratum v1**: Classic mining protocol
- **Stratum v2**: Modern encrypted protocol
- **Job management**: Work distribution and submission
- **Share validation**: Difficulty and target checking
- **Hashrate tracking**: Per-worker statistics
- **Pure Common Lisp**: No CFFI, no external libraries

## Installation

```lisp
(asdf:load-system :cl-mining-protocol)
```

## Quick Start

```lisp
(use-package :cl-mining-protocol)

;; Create pool server
(let ((pool (make-stratum-pool
             :port 3333
             :difficulty 1.0
             :block-template-fn #'get-block-template)))
  ;; Start pool
  (stratum-pool-start pool)
  ;; Handle submissions
  (stratum-pool-on-submit pool
                          (lambda (worker share)
                            (process-share worker share))))
```

## API Reference

### Pool Server

- `(make-stratum-pool &key port difficulty)` - Create pool
- `(stratum-pool-start pool)` - Start accepting connections
- `(stratum-pool-stop pool)` - Stop pool
- `(stratum-pool-broadcast-job pool job)` - Send job to workers

### Worker Management

- `(stratum-authorize pool worker-name password)` - Authorize worker
- `(stratum-submit pool worker nonce)` - Submit share
- `(stratum-get-hashrate pool worker)` - Get worker hashrate

### Client

- `(make-stratum-client &key host port worker password)` - Create client
- `(stratum-client-connect client)` - Connect to pool

## Testing

```lisp
(asdf:test-system :cl-mining-protocol)
```

## License

BSD-3-Clause

Copyright (c) 2024-2026 Parkian Company LLC. All rights reserved.
