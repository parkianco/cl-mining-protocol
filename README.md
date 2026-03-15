# cl-mining-protocol

Pure Common Lisp implementation of Mining Protocol

## Overview
This library provides a robust, zero-dependency implementation of Mining Protocol for the Common Lisp ecosystem. It is designed to be highly portable, performant, and easy to integrate into any SBCL/CCL/ECL environment.

## Getting Started

Load the system using ASDF:

```lisp
(asdf:load-system #:cl-mining-protocol)
```

## Usage Example

```lisp
;; Initialize the environment
(let ((ctx (cl-mining-protocol:initialize-mining-protocol :initial-id 42)))
  ;; Perform batch processing using the built-in standard toolkit
  (multiple-value-bind (results errors)
      (cl-mining-protocol:mining-protocol-batch-process '(1 2 3) #'identity)
    (format t "Processed ~A items with ~A errors.~%" (length results) (length errors))))
```

## License
Apache-2.0
