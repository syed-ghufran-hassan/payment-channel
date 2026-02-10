;; =========================================
;; Payment Channel Smart Contract
;; =========================================

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-CHANNEL-EXISTS (err u101))
(define-constant ERR-CHANNEL-NOT-FOUND (err u102))
(define-constant ERR-INSUFFICIENT-FUNDS (err u103))
(define-constant ERR-INVALID-SIGNATURE (err u104))
(define-constant ERR-CHANNEL-CLOSED (err u105))
(define-constant ERR-DISPUTE-PERIOD (err u106))
(define-constant ERR-INVALID-INPUT (err u107))

;; =========================================
;; Data Maps
;; =========================================

(define-map payment-channels 
  {
    channel-id: (buff 32),
    participant-a: principal,
    participant-b: principal
  }
  {
    total-deposited: uint,
    balance-a: uint,
    balance-b: uint,
    is-open: bool,
    dispute-deadline: uint,
    nonce: uint
  }
)

;; =========================================
;; Validation & Helpers
;; =========================================

(define-private (is-valid-channel-id (channel-id (buff 32)))
  (and (> (len channel-id) u0) (<= (len channel-id) u32))
)

(define-private (is-valid-deposit (amount uint))
  (> amount u0)
)

(define-private (uint-to-buff (n uint))
  (unwrap-panic (uint-to-buff? n))
)

;; NOTE: Placeholder signature verification (NOT cryptographically secure)
(define-private (verify-signature 
  (message (buff 256))
  (signature (buff 65))
  (signer principal)
)
  (is-eq tx-sender signer)
)

;; =========================================
;; Signed State Builder
;; =========================================

(define-private (build-state-message
  (channel-id (buff 32))
  (balance-a uint)
  (balance-b uint)
  (nonce uint)
)
  (concat
    (concat
      (concat channel-id (uint-to-buff balance-a))
      (uint-to-buff balance-b)
    )
    (uint-to-buff nonce)
  )
)

;; =========================================
;; Public Functions
;; =========================================

(define-public (create-channel 
  (channel-id (buff 32)) 
  (participant-b principal)
  (initial-deposit uint)
)
  (begin
    (asserts! (is-valid-channel-id channel-id) ERR-INVALID-INPUT)
    (asserts! (is-valid-deposit initial-deposit) ERR-INVALID-INPUT)
    (asserts! (not (is-eq tx-sender participant-b)) ERR-INVALID-INPUT)

    (asserts!
      (is-none (map-get? payment-channels {
        channel-id: channel-id,
        participant-a: tx-sender,
        participant-b: participant-b
      }))
      ERR-CHANNEL-EXISTS
    )

    (try! (stx-transfer? initial-deposit tx-sender (as-contract tx-sender)))

    (map-set payment-channels
      {
        channel-id: channel-id,
        participant-a: tx-sender,
        participant-b: participant-b
      }
      {
        total-deposited: initial-deposit,
        balance-a: initial-deposit,
        balance-b: u0,
        is-open: true,
        dispute-deadline: u0,
        nonce: u0
      }
    )

    (ok true)
  )
)

;; -----------------------------------------

(define-public (fund-channel 
  (channel-id (buff 32)) 
  (participant-b principal)
  (additional-funds uint)
)
  (let (
    (channel (unwrap!
      (map-get? payment-channels {
        channel-id: channel-id,
        participant-a: tx-sender,
        participant-b: participant-b
      })
      ERR-CHANNEL-NOT-FOUND
    ))
  )
    (asserts! (get is-open channel) ERR-CHANNEL-CLOSED)
    (asserts! (is-valid-deposit additional-funds) ERR-INVALID-INPUT)

    (try! (stx-transfer? additional-funds tx-sender (as-contract tx-sender)))

    (map-set payment-channels
      {
        channel-id: channel-id,
        participant-a: tx-sender,
        participant-b: participant-b
      }
      (merge channel {
        total-deposited: (+ (get total-deposited channel) additional-funds),
        balance-a: (+ (get balance-a channel) additional-funds)
      })
    )

    (ok true)
  )
)

;; -----------------------------------------

(define-public (close-channel-cooperative 
  (channel-id (buff 32)) 
  (participant-b principal)
  (balance-a uint)
  (balance-b uint)
  (nonce uint)
  (signature-a (buff 65))
  (signature-b (buff 65))
)
  (let (
    (channel (unwrap!
      (map-get? payment-channels {
        channel-id: channel-id,
        participant-a: tx-sender,
        participant-b: participant-b
      })
      ERR-CHANNEL-NOT-FOUND
    ))
    (message (build-state-message channel-id balance-a balance-b nonce))
  )
    (asserts! (get is-open channel) ERR-CHANNEL-CLOSED)
    (asserts! (> nonce (get nonce channel)) ERR-INVALID-INPUT)

    (asserts!
      (and
        (verify-signature message signature-a tx-sender)
        (verify-signature message signature-b participant-b)
      )
      ERR-INVALID-SIGNATURE
    )

    (asserts!
      (is-eq (+ balance-a balance-b) (get total-deposited channel))
      ERR-INSUFFICIENT-FUNDS
    )

    (try! (as-contract (stx-transfer? balance-a tx-sender tx-sender)))
    (try! (as-contract (stx-transfer? balance-b tx-sender participant-b)))

    (map-set payment-channels
      {
        channel-id: channel-id,
        participant-a: tx-sender,
        participant-b: participant-b
      }
      (merge channel {
        is-open: false,
        balance-a: u0,
        balance-b: u0,
        total-deposited: u0,
        nonce: nonce
      })
    )

    (ok true)
  )
)

;; -----------------------------------------
;; UNILATERAL CLOSE (FIXED)
;; -----------------------------------------

(define-public (initiate-unilateral-close 
  (channel-id (buff 32)) 
  (participant-a principal)
  (participant-b principal)
  (proposed-balance-a uint)
  (proposed-balance-b uint)
  (nonce uint)
  (signature (buff 65))
)
  (let (
    (channel (unwrap!
      (map-get? payment-channels {
        channel-id: channel-id,
        participant-a: participant-a,
        participant-b: participant-b
      })
      ERR-CHANNEL-NOT-FOUND
    ))
    (message (build-state-message channel-id proposed-balance-a proposed-balance-b nonce))
  )
    ;; Either party may initiate
    (asserts!
      (or (is-eq tx-sender participant-a) (is-eq tx-sender participant-b))
      ERR-NOT-AUTHORIZED
    )

    ;; Prevent deadline griefing
    (asserts! (is-eq (get dispute-deadline channel) u0) ERR-DISPUTE-PERIOD)

    (asserts! (get is-open channel) ERR-CHANNEL-CLOSED)
    (asserts! (> nonce (get nonce channel)) ERR-INVALID-INPUT)

    (asserts!
      (verify-signature message signature tx-sender)
      ERR-INVALID-SIGNATURE
    )

    (asserts!
      (is-eq (+ proposed-balance-a proposed-balance-b) (get total-deposited channel))
      ERR-INSUFFICIENT-FUNDS
    )

    (map-set payment-channels
      {
        channel-id: channel-id,
        participant-a: participant-a,
        participant-b: participant-b
      }
      (merge channel {
        balance-a: proposed-balance-a,
        balance-b: proposed-balance-b,
        dispute-deadline: (+ block-height u1008),
        nonce: nonce
      })
    )

    (ok true)
  )
)

;; -----------------------------------------

(define-public (resolve-unilateral-close 
  (channel-id (buff 32)) 
  (participant-a principal)
  (participant-b principal)
)
  (let (
    (channel (unwrap!
      (map-get? payment-channels {
        channel-id: channel-id,
        participant-a: participant-a,
        participant-b: participant-b
      })
      ERR-CHANNEL-NOT-FOUND
    ))
  )
    (asserts!
      (>= block-height (get dispute-deadline channel))
      ERR-DISPUTE-PERIOD
    )

    (try! (as-contract (stx-transfer? (get balance-a channel) tx-sender participant-a)))
    (try! (as-contract (stx-transfer? (get balance-b channel) tx-sender participant-b)))

    (map-set payment-channels
      {
        channel-id: channel-id,
        participant-a: participant-a,
        participant-b: participant-b
      }
      (merge channel {
        is-open: false,
        balance-a: u0,
        balance-b: u0,
        total-deposited: u0
      })
    )

    (ok true)
  )
)

;; =========================================
;; Emergency
;; =========================================

(define-public (emergency-withdraw)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (try! (stx-transfer?
      (stx-get-balance (as-contract tx-sender))
      (as-contract tx-sender)
      CONTRACT-OWNER
    ))
    (ok true)
  )
)
