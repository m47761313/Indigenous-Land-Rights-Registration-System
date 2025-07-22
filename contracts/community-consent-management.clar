;; Community Consent Management Contract
;; Manages community decision-making processes for land use

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u200))
(define-constant ERR-PROPOSAL-EXISTS (err u201))
(define-constant ERR-INVALID-PROPOSAL (err u202))
(define-constant ERR-VOTING-CLOSED (err u203))
(define-constant ERR-PROPOSAL-NOT-FOUND (err u204))
(define-constant ERR-ALREADY-VOTED (err u205))

;; Data Variables
(define-data-var next-proposal-id uint u1)

;; Data Maps
(define-map proposals
  { proposal-id: uint }
  {
    community: (string-ascii 100),
    land-id: uint,
    proposal-type: (string-ascii 50),
    description: (string-ascii 500),
    proposer: principal,
    creation-date: uint,
    voting-deadline: uint,
    status: (string-ascii 20),
    yes-votes: uint,
    no-votes: uint,
    abstain-votes: uint,
    quorum-required: uint
  }
)

(define-map proposal-votes
  { proposal-id: uint, voter: principal }
  { vote: (string-ascii 10), vote-date: uint }
)

(define-map community-governance
  { community: (string-ascii 100) }
  {
    voting-period: uint,
    quorum-percentage: uint,
    approval-threshold: uint,
    elder-veto-power: bool
  }
)

(define-map elder-decisions
  { proposal-id: uint, elder: principal }
  { decision: (string-ascii 10), decision-date: uint }
)

;; Public Functions

;; Create a new proposal
(define-public (create-proposal
  (community (string-ascii 100))
  (land-id uint)
  (proposal-type (string-ascii 50))
  (description (string-ascii 500))
  (voting-period uint))
  (let ((proposal-id (var-get next-proposal-id))
        (governance (default-to
          { voting-period: u1440, quorum-percentage: u50, approval-threshold: u60, elder-veto-power: true }
          (map-get? community-governance { community: community }))))

    (asserts! (> (len description) u0) ERR-INVALID-PROPOSAL)
    (asserts! (> voting-period u0) ERR-INVALID-PROPOSAL)

    (map-set proposals
      { proposal-id: proposal-id }
      {
        community: community,
        land-id: land-id,
        proposal-type: proposal-type,
        description: description,
        proposer: tx-sender,
        creation-date: block-height,
        voting-deadline: (+ block-height voting-period),
        status: "active",
        yes-votes: u0,
        no-votes: u0,
        abstain-votes: u0,
        quorum-required: (get quorum-percentage governance)
      }
    )

    (var-set next-proposal-id (+ proposal-id u1))
    (ok proposal-id)
  )
)

;; Cast vote on proposal
(define-public (cast-vote (proposal-id uint) (vote (string-ascii 10)) (community (string-ascii 100)))
  (let ((proposal (unwrap! (map-get? proposals { proposal-id: proposal-id }) ERR-PROPOSAL-NOT-FOUND))
        (existing-vote (map-get? proposal-votes { proposal-id: proposal-id, voter: tx-sender })))

    (asserts! (is-none existing-vote) ERR-ALREADY-VOTED)
    (asserts! (is-eq (get status proposal) "active") ERR-VOTING-CLOSED)
    (asserts! (<= block-height (get voting-deadline proposal)) ERR-VOTING-CLOSED)
    (asserts! (or (is-eq vote "yes") (or (is-eq vote "no") (is-eq vote "abstain"))) ERR-INVALID-PROPOSAL)

    ;; Record the vote
    (map-set proposal-votes
      { proposal-id: proposal-id, voter: tx-sender }
      { vote: vote, vote-date: block-height }
    )

    ;; Update vote counts
    (let ((updated-proposal
           (if (is-eq vote "yes")
             (merge proposal { yes-votes: (+ (get yes-votes proposal) u1) })
             (if (is-eq vote "no")
               (merge proposal { no-votes: (+ (get no-votes proposal) u1) })
               (merge proposal { abstain-votes: (+ (get abstain-votes proposal) u1) })))))

      (map-set proposals { proposal-id: proposal-id } updated-proposal)
      (ok true)
    )
  )
)

;; Finalize proposal voting
(define-public (finalize-proposal (proposal-id uint))
  (let ((proposal (unwrap! (map-get? proposals { proposal-id: proposal-id }) ERR-PROPOSAL-NOT-FOUND)))

    (asserts! (is-eq (get status proposal) "active") ERR-VOTING-CLOSED)
    (asserts! (> block-height (get voting-deadline proposal)) ERR-VOTING-CLOSED)

    (let ((total-votes (+ (+ (get yes-votes proposal) (get no-votes proposal)) (get abstain-votes proposal)))
          (governance (default-to
            { voting-period: u1440, quorum-percentage: u50, approval-threshold: u60, elder-veto-power: true }
            (map-get? community-governance { community: (get community proposal) }))))

      ;; Check quorum
      (if (>= (* total-votes u100) (* (get quorum-required proposal) u10))
        ;; Quorum met, check approval
        (let ((approval-rate (if (> total-votes u0) (/ (* (get yes-votes proposal) u100) total-votes) u0)))
          (if (>= approval-rate (get approval-threshold governance))
            (map-set proposals { proposal-id: proposal-id } (merge proposal { status: "approved" }))
            (map-set proposals { proposal-id: proposal-id } (merge proposal { status: "rejected" }))
          )
        )
        ;; Quorum not met
        (map-set proposals { proposal-id: proposal-id } (merge proposal { status: "failed-quorum" }))
      )

      (ok true)
    )
  )
)

;; Elder veto power
(define-public (elder-veto (proposal-id uint) (community (string-ascii 100)))
  (let ((proposal (unwrap! (map-get? proposals { proposal-id: proposal-id }) ERR-PROPOSAL-NOT-FOUND)))

    ;; Check if sender is authorized elder (simplified check)
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (or (is-eq (get status proposal) "active") (is-eq (get status proposal) "approved")) ERR-VOTING-CLOSED)

    (map-set elder-decisions
      { proposal-id: proposal-id, elder: tx-sender }
      { decision: "veto", decision-date: block-height }
    )

    (map-set proposals
      { proposal-id: proposal-id }
      (merge proposal { status: "vetoed" })
    )

    (ok true)
  )
)

;; Set community governance parameters
(define-public (set-governance-params
  (community (string-ascii 100))
  (voting-period uint)
  (quorum-percentage uint)
  (approval-threshold uint)
  (elder-veto-power bool))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (and (> voting-period u0) (<= quorum-percentage u100)) ERR-INVALID-PROPOSAL)
    (asserts! (<= approval-threshold u100) ERR-INVALID-PROPOSAL)

    (map-set community-governance
      { community: community }
      {
        voting-period: voting-period,
        quorum-percentage: quorum-percentage,
        approval-threshold: approval-threshold,
        elder-veto-power: elder-veto-power
      }
    )

    (ok true)
  )
)

;; Read-only functions

(define-read-only (get-proposal (proposal-id uint))
  (map-get? proposals { proposal-id: proposal-id })
)

(define-read-only (get-vote (proposal-id uint) (voter principal))
  (map-get? proposal-votes { proposal-id: proposal-id, voter: voter })
)

(define-read-only (get-governance-params (community (string-ascii 100)))
  (map-get? community-governance { community: community })
)

(define-read-only (get-elder-decision (proposal-id uint) (elder principal))
  (map-get? elder-decisions { proposal-id: proposal-id, elder: elder })
)

(define-read-only (get-next-proposal-id)
  (var-get next-proposal-id)
)
