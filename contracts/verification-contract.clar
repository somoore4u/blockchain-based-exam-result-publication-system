;; title: verification-contract
;; version: 1.0.0
;; summary: Smart contract to enable students, employers, or institutions to verify result authenticity
;; description: Provides verification services for exam results with access control and audit trails

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u200))
(define-constant err-not-authorized (err u201))
(define-constant err-verifier-exists (err u202))
(define-constant err-verifier-not-found (err u203))
(define-constant err-verification-not-found (err u204))
(define-constant err-invalid-result (err u205))
(define-constant err-access-denied (err u206))
(define-constant err-verification-expired (err u207))

;; Verifier types
(define-constant verifier-type-student u1)
(define-constant verifier-type-employer u2)
(define-constant verifier-type-institution u3)
(define-constant verifier-type-public u4)

;; Data Variables
(define-data-var next-verifier-id uint u1)
(define-data-var next-verification-id uint u1)
(define-data-var total-verifiers uint u0)
(define-data-var total-verifications uint u0)
(define-data-var verification-fee uint u1000) ;; Fee in micro-STX

;; Data Maps
;; Registered verifiers (employers, institutions, etc.)
(define-map verifiers
  { verifier-id: uint }
  {
    name: (string-ascii 100),
    verifier-type: uint,
    principal-address: principal,
    active: bool,
    registration-block: uint,
    verification-count: uint
  }
)

;; Verifier lookup by principal
(define-map verifier-by-principal
  { principal-address: principal }
  { verifier-id: uint }
)

;; Verification records
(define-map verification-records
  { verification-id: uint }
  {
    result-id: uint,
    student-id: (string-ascii 50),
    verifier-id: uint,
    verified-by: principal,
    verification-block: uint,
    verification-status: bool,
    verification-hash: (buff 32),
    notes: (string-ascii 200)
  }
)

;; Result verification history
(define-map result-verification-history
  { result-id: uint }
  { verification-ids: (list 100 uint) }
)

;; Access grants for specific verifications
(define-map verification-access
  { verifier-id: uint, result-id: uint }
  { 
    granted: bool,
    grant-block: uint,
    expiry-block: uint
  }
)

;; Verification certificates
(define-map verification-certificates
  { verification-id: uint }
  {
    certificate-hash: (buff 32),
    issued-block: uint,
    valid: bool
  }
)

;; Public Functions

;; Register a new verifier
(define-public (register-verifier 
  (name (string-ascii 100)) 
  (verifier-type uint) 
  (verifier-address principal)
)
  (let
    (
      (verifier-id (var-get next-verifier-id))
    )
    ;; Check caller is contract owner
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    ;; Check verifier doesn't exist
    (asserts! (is-none (map-get? verifier-by-principal { principal-address: verifier-address })) err-verifier-exists)
    ;; Validate verifier type
    (asserts! (and (>= verifier-type u1) (<= verifier-type u4)) err-not-authorized)
    
    ;; Store verifier
    (map-set verifiers
      { verifier-id: verifier-id }
      {
        name: name,
        verifier-type: verifier-type,
        principal-address: verifier-address,
        active: true,
        registration-block: stacks-block-height,
        verification-count: u0
      }
    )
    
    ;; Map principal to verifier
    (map-set verifier-by-principal
      { principal-address: verifier-address }
      { verifier-id: verifier-id }
    )
    
    ;; Update counters
    (var-set next-verifier-id (+ verifier-id u1))
    (var-set total-verifiers (+ (var-get total-verifiers) u1))
    
    (ok verifier-id)
  )
)

;; Verify result authenticity
(define-public (verify-result
  (result-id uint)
  (student-id (string-ascii 50))
  (verification-hash (buff 32))
  (notes (string-ascii 200))
)
  (let
    (
      (verification-id (var-get next-verification-id))
      (verifier-data (map-get? verifier-by-principal { principal-address: tx-sender }))
    )
    ;; Check caller is registered verifier or contract owner
    (asserts! 
      (or 
        (is-some verifier-data) 
        (is-eq tx-sender contract-owner)
      ) 
      err-not-authorized
    )
    
    (let
      (
        (verifier-id 
          (if (is-some verifier-data)
            (get verifier-id (unwrap! verifier-data err-verifier-not-found))
            u0
          )
        )
      )
      ;; Check access if verifier is not owner
      (if (not (is-eq tx-sender contract-owner))
        (asserts! 
          (default-to false 
            (get granted 
              (map-get? verification-access { verifier-id: verifier-id, result-id: result-id })
            )
          )
          err-access-denied
        )
        true
      )
      
      ;; Store verification record
      (map-set verification-records
        { verification-id: verification-id }
        {
          result-id: result-id,
          student-id: student-id,
          verifier-id: verifier-id,
          verified-by: tx-sender,
          verification-block: stacks-block-height,
          verification-status: true,
          verification-hash: verification-hash,
          notes: notes
        }
      )
      
      ;; Update verification history
      (match (map-get? result-verification-history { result-id: result-id })
        existing-history
          (map-set result-verification-history
            { result-id: result-id }
            { verification-ids: (unwrap! (as-max-len? (append (get verification-ids existing-history) verification-id) u100) err-invalid-result) }
          )
        (map-set result-verification-history
          { result-id: result-id }
          { verification-ids: (list verification-id) }
        )
      )
      
      ;; Update verifier stats if not owner
      (if (> verifier-id u0)
        (match (map-get? verifiers { verifier-id: verifier-id })
          verifier-info
            (map-set verifiers
              { verifier-id: verifier-id }
              (merge verifier-info { verification-count: (+ (get verification-count verifier-info) u1) })
            )
          true
        )
        true
      )
      
      ;; Update counters
      (var-set next-verification-id (+ verification-id u1))
      (var-set total-verifications (+ (var-get total-verifications) u1))
      
      (ok verification-id)
    )
  )
)

;; Grant verification access
(define-public (grant-access
  (verifier-id uint)
  (result-id uint)
  (duration-blocks uint)
)
  (begin
    ;; Only contract owner can grant access
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    ;; Verify verifier exists
    (asserts! (is-some (map-get? verifiers { verifier-id: verifier-id })) err-verifier-not-found)
    
    ;; Grant access
    (map-set verification-access
      { verifier-id: verifier-id, result-id: result-id }
      {
        granted: true,
        grant-block: stacks-block-height,
        expiry-block: (+ stacks-block-height duration-blocks)
      }
    )
    
    (ok true)
  )
)

;; Revoke verification access
(define-public (revoke-access
  (verifier-id uint)
  (result-id uint)
)
  (begin
    ;; Only contract owner can revoke
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    
    ;; Revoke access
    (map-set verification-access
      { verifier-id: verifier-id, result-id: result-id }
      {
        granted: false,
        grant-block: stacks-block-height,
        expiry-block: stacks-block-height
      }
    )
    
    (ok true)
  )
)

;; Issue verification certificate
(define-public (issue-certificate
  (verification-id uint)
  (certificate-hash (buff 32))
)
  (let
    (
      (verification (unwrap! (map-get? verification-records { verification-id: verification-id }) err-verification-not-found))
    )
    ;; Check caller is verifier or owner
    (asserts! 
      (or 
        (is-eq tx-sender (get verified-by verification))
        (is-eq tx-sender contract-owner)
      )
      err-not-authorized
    )
    
    ;; Issue certificate
    (map-set verification-certificates
      { verification-id: verification-id }
      {
        certificate-hash: certificate-hash,
        issued-block: stacks-block-height,
        valid: true
      }
    )
    
    (ok true)
  )
)

;; Update verifier status
(define-public (update-verifier-status (verifier-id uint) (active bool))
  (let
    (
      (verifier (unwrap! (map-get? verifiers { verifier-id: verifier-id }) err-verifier-not-found))
    )
    ;; Only owner can update
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    
    ;; Update status
    (map-set verifiers
      { verifier-id: verifier-id }
      (merge verifier { active: active })
    )
    
    (ok true)
  )
)

;; Read Only Functions

;; Get verifier details
(define-read-only (get-verifier (verifier-id uint))
  (map-get? verifiers { verifier-id: verifier-id })
)

;; Get verifier by principal
(define-read-only (get-verifier-by-principal (principal-address principal))
  (match (map-get? verifier-by-principal { principal-address: principal-address })
    verifier-data (map-get? verifiers { verifier-id: (get verifier-id verifier-data) })
    none
  )
)

;; Get verification record
(define-read-only (get-verification-record (verification-id uint))
  (map-get? verification-records { verification-id: verification-id })
)

;; Get verification history for result
(define-read-only (get-verification-history (result-id uint))
  (map-get? result-verification-history { result-id: result-id })
)

;; Check verification access
(define-read-only (check-access (verifier-id uint) (result-id uint))
  (match (map-get? verification-access { verifier-id: verifier-id, result-id: result-id })
    access-data
      (and 
        (get granted access-data)
        (< stacks-block-height (get expiry-block access-data))
      )
    false
  )
)

;; Get verification certificate
(define-read-only (get-certificate (verification-id uint))
  (map-get? verification-certificates { verification-id: verification-id })
)

;; Get total verifiers
(define-read-only (get-total-verifiers)
  (ok (var-get total-verifiers))
)

;; Get total verifications
(define-read-only (get-total-verifications)
  (ok (var-get total-verifications))
)

;; Get verification fee
(define-read-only (get-verification-fee)
  (ok (var-get verification-fee))
)

;; Get contract owner
(define-read-only (get-contract-owner)
  (ok contract-owner)
)

;; Verify certificate validity
(define-read-only (is-certificate-valid (verification-id uint))
  (match (map-get? verification-certificates { verification-id: verification-id })
    cert-data (ok (get valid cert-data))
    err-verification-not-found
  )
)
