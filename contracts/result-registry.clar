;; title: result-registry
;; version: 1.0.0
;; summary: Smart contract to record and store verified exam scores
;; description: Manages the registration of institutions and publication of exam results on the blockchain

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-authorized (err u101))
(define-constant err-institution-exists (err u102))
(define-constant err-institution-not-found (err u103))
(define-constant err-result-exists (err u104))
(define-constant err-result-not-found (err u105))
(define-constant err-invalid-score (err u106))
(define-constant err-invalid-student (err u107))
(define-constant err-result-published (err u108))

;; Data Variables
(define-data-var next-institution-id uint u1)
(define-data-var next-result-id uint u1)
(define-data-var total-institutions uint u0)
(define-data-var total-results uint u0)

;; Data Maps
;; Institution registry
(define-map institutions
  { institution-id: uint }
  {
    name: (string-ascii 100),
    admin: principal,
    active: bool,
    registration-block: uint,
    results-count: uint
  }
)

;; Institution by principal for quick lookup
(define-map institution-by-principal
  { admin: principal }
  { institution-id: uint }
)

;; Exam results storage
(define-map exam-results
  { result-id: uint }
  {
    student-id: (string-ascii 50),
    student-name: (string-ascii 100),
    institution-id: uint,
    exam-name: (string-ascii 100),
    exam-year: uint,
    score: uint,
    grade: (string-ascii 5),
    published-by: principal,
    publication-block: uint,
    result-hash: (buff 32),
    is-published: bool
  }
)

;; Student results mapping for quick lookup
(define-map student-results
  { student-id: (string-ascii 50), institution-id: uint }
  { result-ids: (list 50 uint) }
)

;; Institution authorization
(define-map authorized-institutions
  { institution-id: uint }
  { authorized: bool }
)

;; Public Functions

;; Register a new institution
(define-public (register-institution (name (string-ascii 100)) (admin principal))
  (let
    (
      (institution-id (var-get next-institution-id))
    )
    ;; Check if caller is contract owner
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    ;; Check if institution admin already registered
    (asserts! (is-none (map-get? institution-by-principal { admin: admin })) err-institution-exists)
    
    ;; Store institution
    (map-set institutions
      { institution-id: institution-id }
      {
        name: name,
        admin: admin,
        active: true,
        registration-block: stacks-block-height,
        results-count: u0
      }
    )
    
    ;; Map principal to institution
    (map-set institution-by-principal
      { admin: admin }
      { institution-id: institution-id }
    )
    
    ;; Authorize institution
    (map-set authorized-institutions
      { institution-id: institution-id }
      { authorized: true }
    )
    
    ;; Update counters
    (var-set next-institution-id (+ institution-id u1))
    (var-set total-institutions (+ (var-get total-institutions) u1))
    
    (ok institution-id)
  )
)

;; Publish exam result
(define-public (publish-result 
  (student-id (string-ascii 50))
  (student-name (string-ascii 100))
  (exam-name (string-ascii 100))
  (exam-year uint)
  (score uint)
  (grade (string-ascii 5))
  (result-hash (buff 32))
)
  (let
    (
      (result-id (var-get next-result-id))
      (institution-data (map-get? institution-by-principal { admin: tx-sender }))
    )
    ;; Validate caller is registered institution
    (asserts! (is-some institution-data) err-not-authorized)
    
    (let
      (
        (institution-id (get institution-id (unwrap! institution-data err-not-authorized)))
        (institution-info (unwrap! (map-get? institutions { institution-id: institution-id }) err-institution-not-found))
      )
      ;; Check institution is active
      (asserts! (get active institution-info) err-not-authorized)
      ;; Validate score (0-100)
      (asserts! (<= score u100) err-invalid-score)
      
      ;; Store result
      (map-set exam-results
        { result-id: result-id }
        {
          student-id: student-id,
          student-name: student-name,
          institution-id: institution-id,
          exam-name: exam-name,
          exam-year: exam-year,
          score: score,
          grade: grade,
          published-by: tx-sender,
          publication-block: stacks-block-height,
          result-hash: result-hash,
          is-published: true
        }
      )
      
      ;; Update student results mapping
      (match (map-get? student-results { student-id: student-id, institution-id: institution-id })
        existing-results
          (map-set student-results
            { student-id: student-id, institution-id: institution-id }
            { result-ids: (unwrap! (as-max-len? (append (get result-ids existing-results) result-id) u50) err-result-exists) }
          )
        (map-set student-results
          { student-id: student-id, institution-id: institution-id }
          { result-ids: (list result-id) }
        )
      )
      
      ;; Update institution results count
      (map-set institutions
        { institution-id: institution-id }
        (merge institution-info { results-count: (+ (get results-count institution-info) u1) })
      )
      
      ;; Update counters
      (var-set next-result-id (+ result-id u1))
      (var-set total-results (+ (var-get total-results) u1))
      
      (ok result-id)
    )
  )
)

;; Update institution status
(define-public (update-institution-status (institution-id uint) (active bool))
  (let
    (
      (institution (unwrap! (map-get? institutions { institution-id: institution-id }) err-institution-not-found))
    )
    ;; Only contract owner can update
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    
    ;; Update institution
    (map-set institutions
      { institution-id: institution-id }
      (merge institution { active: active })
    )
    
    (ok true)
  )
)

;; Read Only Functions

;; Get institution details
(define-read-only (get-institution (institution-id uint))
  (map-get? institutions { institution-id: institution-id })
)

;; Get institution by principal
(define-read-only (get-institution-by-principal (admin principal))
  (match (map-get? institution-by-principal { admin: admin })
    inst-data (map-get? institutions { institution-id: (get institution-id inst-data) })
    none
  )
)

;; Get result details
(define-read-only (get-result (result-id uint))
  (map-get? exam-results { result-id: result-id })
)

;; Get student results
(define-read-only (get-student-results (student-id (string-ascii 50)) (institution-id uint))
  (map-get? student-results { student-id: student-id, institution-id: institution-id })
)

;; Check if institution is authorized
(define-read-only (is-institution-authorized (institution-id uint))
  (match (map-get? authorized-institutions { institution-id: institution-id })
    auth-data (get authorized auth-data)
    false
  )
)

;; Get total institutions
(define-read-only (get-total-institutions)
  (ok (var-get total-institutions))
)

;; Get total results
(define-read-only (get-total-results)
  (ok (var-get total-results))
)

;; Get contract owner
(define-read-only (get-contract-owner)
  (ok contract-owner)
)

;; Verify result hash
(define-read-only (verify-result-hash (result-id uint) (hash (buff 32)))
  (match (map-get? exam-results { result-id: result-id })
    result-data (ok (is-eq (get result-hash result-data) hash))
    err-result-not-found
  )
)
