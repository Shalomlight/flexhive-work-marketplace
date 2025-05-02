;; flexhive-marketplace.clar
;; This contract manages the complete lifecycle of gigs in the FlexHive platform.
;; It handles job posting, applications, freelancer selection, escrow payments,
;; completion verification, and dispute resolution to create a trustless
;; decentralized marketplace for flexible work opportunities.

;; =======================================
;; Constants and Error Codes
;; =======================================

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-GIG-NOT-FOUND (err u101))
(define-constant ERR-INVALID-STATUS (err u102))
(define-constant ERR-INSUFFICIENT-FUNDS (err u103))
(define-constant ERR-NOT-APPLICANT (err u104))
(define-constant ERR-NOT-CLIENT (err u105))
(define-constant ERR-NOT-FREELANCER (err u106))
(define-constant ERR-NOT-ARBITRATOR (err u107))
(define-constant ERR-ALREADY-APPLIED (err u108))
(define-constant ERR-MILESTONE-NOT-FOUND (err u109))
(define-constant ERR-DISPUTE-EXISTS (err u110))
(define-constant ERR-DISPUTE-NOT-FOUND (err u111))
(define-constant ERR-PAYMENT-FAILED (err u112))
(define-constant ERR-INVALID-AMOUNT (err u113))

;; Status codes for gigs
(define-constant STATUS-OPEN u1)             ;; Gig is open for applications
(define-constant STATUS-IN-PROGRESS u2)      ;; Freelancer selected and work in progress
(define-constant STATUS-COMPLETED u3)        ;; Work completed and payment released
(define-constant STATUS-CANCELLED u4)        ;; Gig cancelled by client
(define-constant STATUS-DISPUTED u5)         ;; Dispute raised, requires arbitration

;; Platform fee percentage (0.5% = 5 basis points)
(define-constant PLATFORM-FEE-BASIS-POINTS u50)
(define-constant BASIS-POINTS u10000)

;; =======================================
;; Data Maps and Variables
;; =======================================

;; Gig data structure
(define-map gigs
  { gig-id: uint }
  {
    client: principal,
    title: (string-ascii 100),
    description: (string-utf8 1000),
    requirements: (string-utf8 500),
    budget: uint,
    deadline: uint,
    status: uint,
    selected-freelancer: (optional principal),
    creation-time: uint
  }
)

;; Applications for gigs
(define-map applications
  { gig-id: uint, applicant: principal }
  {
    bid-amount: uint,
    proposal: (string-utf8 500),
    application-time: uint
  }
)

;; Track all applicants for a specific gig
(define-map gig-applicants
  { gig-id: uint }
  { applicants: (list 50 principal) }
)

;; Escrow for payments
(define-map escrows
  { gig-id: uint }
  {
    amount: uint,
    release-time: (optional uint)
  }
)

;; Milestone data structure
(define-map milestones
  { gig-id: uint, milestone-id: uint }
  {
    description: (string-utf8 200),
    amount: uint,
    deadline: uint,
    status: uint,    ;; 1=pending, 2=completed, 3=disputed
    completion-time: (optional uint)
  }
)

;; Milestone counter per gig
(define-map gig-milestone-count
  { gig-id: uint }
  { count: uint }
)

;; Disputes
(define-map disputes
  { gig-id: uint }
  {
    client-evidence: (optional (string-utf8 1000)),
    freelancer-evidence: (optional (string-utf8 1000)),
    arbitrator: (optional principal),
    resolution: (optional (string-utf8 500)),
    client-refund-amount: (optional uint),
    freelancer-payment-amount: (optional uint),
    dispute-time: uint,
    resolution-time: (optional uint)
  }
)

;; User reputation
(define-map user-reputation
  { user: principal }
  {
    completed-gigs: uint,
    total-ratings: uint,
    rating-sum: uint,
    disputes-won: uint,
    disputes-lost: uint
  }
)

;; Authorized arbitrators
(define-map arbitrators
  { address: principal }
  { authorized: bool }
)

;; Count of all gigs created (used for gig-id generation)
(define-data-var gig-count uint u0)

;; Platform treasury address
(define-constant PLATFORM-TREASURY 'SP000000000000000000002Q6VF78) ;; Replace with actual address

;; =======================================
;; Private Functions
;; =======================================

;; Helper to get current gig ID and increment the counter
(define-private (get-and-increment-gig-id)
  (let ((current-id (var-get gig-count)))
    (var-set gig-count (+ current-id u1))
    current-id
  )
)

;; Calculate platform fee amount
(define-private (calculate-platform-fee (amount uint))
  (/ (* amount PLATFORM-FEE-BASIS-POINTS) BASIS-POINTS)
)

;; Initialize user reputation if not exists
(define-private (initialize-reputation (user principal))
  (match (map-get? user-reputation { user: user })
    existing-data true ;; Already exists, return true
    (begin ;; Does not exist, create it and return true
      (map-set user-reputation
        { user: user }
        {
          completed-gigs: u0,
          total-ratings: u0,
          rating-sum: u0,
          disputes-won: u0,
          disputes-lost: u0
        }
      )
      true
    )
  )
)

;; Add applicant to the list of applicants for a gig
(define-private (add-applicant (gig-id uint) (applicant principal))
  (let ((current-applicants (default-to { applicants: (list) } 
                            (map-get? gig-applicants { gig-id: gig-id }))))
    (map-set gig-applicants
      { gig-id: gig-id }
      { applicants: (unwrap-panic (as-max-len? 
                                   (append (get applicants current-applicants) applicant)
                                   u50)) }
    )
  )
)

;; Check if user is an applicant
(define-private (is-applicant (gig-id uint) (user principal))
  (let ((applicants-data (default-to { applicants: (list) } 
                        (map-get? gig-applicants { gig-id: gig-id }))))
    (is-some (index-of (get applicants applicants-data) user))
  )
)

;; Check if user is an authorized arbitrator
(define-private (is-arbitrator (user principal))
  (default-to false (get authorized (map-get? arbitrators { address: user })))
)

;; Update reputation after gig completion
(define-private (update-reputation-after-completion (user principal) (rating uint))
  (let ((reputation (default-to 
                    { completed-gigs: u0, total-ratings: u0, rating-sum: u0, disputes-won: u0, disputes-lost: u0 } 
                    (map-get? user-reputation { user: user }))))
    (map-set user-reputation
      { user: user }
      {
        completed-gigs: (+ (get completed-gigs reputation) u1),
        total-ratings: (+ (get total-ratings reputation) u1),
        rating-sum: (+ (get rating-sum reputation) rating),
        disputes-won: (get disputes-won reputation),
        disputes-lost: (get disputes-lost reputation)
      }
    )
  )
)

;; Update reputation after dispute resolution
(define-private (update-reputation-after-dispute (winner principal) (loser principal))
  (begin ;; Wrap the body in a begin block
    ;; Update winner reputation
    (let ((winner-reputation (default-to 
                            { completed-gigs: u0, total-ratings: u0, rating-sum: u0, disputes-won: u0, disputes-lost: u0 } 
                            (map-get? user-reputation { user: winner }))))
      (map-set user-reputation
        { user: winner }
        {
          completed-gigs: (get completed-gigs winner-reputation),
          total-ratings: (get total-ratings winner-reputation),
          rating-sum: (get rating-sum winner-reputation),
          disputes-won: (+ (get disputes-won winner-reputation) u1),
          disputes-lost: (get disputes-lost winner-reputation)
        }
      )
    )
    
    ;; Update loser reputation
    (let ((loser-reputation (default-to 
                           { completed-gigs: u0, total-ratings: u0, rating-sum: u0, disputes-won: u0, disputes-lost: u0 } 
                           (map-get? user-reputation { user: loser }))))
      (map-set user-reputation
        { user: loser }
        {
          completed-gigs: (get completed-gigs loser-reputation),
          total-ratings: (get total-ratings loser-reputation),
          rating-sum: (get rating-sum loser-reputation),
          disputes-won: (get disputes-won loser-reputation),
          disputes-lost: (+ (get disputes-lost loser-reputation) u1)
        }
      )
    )
  ) ;; End begin block
)

;; Create a new milestone
(define-private (create-milestone (gig-id uint) (description (string-utf8 200)) (amount uint) (deadline uint))
  (let ((milestone-count (default-to { count: u0 } (map-get? gig-milestone-count { gig-id: gig-id })))
        (milestone-id (get count milestone-count)))
    ;; Increment milestone count
    (map-set gig-milestone-count 
      { gig-id: gig-id } 
      { count: (+ milestone-id u1) })
    
    ;; Create milestone
    (map-set milestones
      { gig-id: gig-id, milestone-id: milestone-id }
      {
        description: description,
        amount: amount,
        deadline: deadline,
        status: u1, ;; pending
        completion-time: none
      }
    )
    milestone-id
  )
)

;; =======================================
;; Read-Only Functions
;; =======================================

;; Get gig details
(define-read-only (get-gig (gig-id uint))
  (map-get? gigs { gig-id: gig-id })
)

;; Get all applicants for a gig
(define-read-only (get-gig-applicants (gig-id uint))
  (default-to { applicants: (list) } (map-get? gig-applicants { gig-id: gig-id }))
)

;; Get application details
(define-read-only (get-application (gig-id uint) (applicant principal))
  (map-get? applications { gig-id: gig-id, applicant: applicant })
)

;; Get escrow details
(define-read-only (get-escrow (gig-id uint))
  (map-get? escrows { gig-id: gig-id })
)

;; Get user reputation
(define-read-only (get-reputation (user principal))
  (map-get? user-reputation { user: user })
)

;; Get milestone details
(define-read-only (get-milestone (gig-id uint) (milestone-id uint))
  (map-get? milestones { gig-id: gig-id, milestone-id: milestone-id })
)

;; Get dispute details
(define-read-only (get-dispute (gig-id uint))
  (map-get? disputes { gig-id: gig-id })
)

;; Calculate average rating for a user
(define-read-only (get-average-rating (user principal))
  (let ((reputation (default-to 
                    { completed-gigs: u0, total-ratings: u0, rating-sum: u0, disputes-won: u0, disputes-lost: u0 } 
                    (map-get? user-reputation { user: user }))))
    (if (> (get total-ratings reputation) u0)
      (/ (get rating-sum reputation) (get total-ratings reputation))
      u0
    )
  )
)

;; Check if a user is authorized to interact with a gig
(define-read-only (is-gig-participant (gig-id uint) (user principal))
  (match (map-get? gigs { gig-id: gig-id })
    gig-data (or (is-eq user (get client gig-data))
                 (match (get selected-freelancer gig-data)
                   freelancer (is-eq user freelancer)
                   false))
    false
  )
)

;; Get milestone count for a gig
(define-read-only (get-milestone-count (gig-id uint))
  (default-to { count: u0 } (map-get? gig-milestone-count { gig-id: gig-id }))
)

;; =======================================
;; Public Functions
;; =======================================

;; Create a new gig listing
(define-public (create-gig 
  (title (string-ascii 100)) 
  (description (string-utf8 1000)) 
  (requirements (string-utf8 500)) 
  (budget uint) 
  (deadline uint))
  
  (let ((gig-id (get-and-increment-gig-id))
        (client tx-sender)
        (block-time block-height))
    
    ;; Initialize client reputation if needed
    (initialize-reputation client)
    
    ;; Create the gig
    (map-set gigs
      { gig-id: gig-id }
      {
        client: client,
        title: title,
        description: description,
        requirements: requirements,
        budget: budget,
        deadline: deadline,
        status: STATUS-OPEN,
        selected-freelancer: none,
        creation-time: block-time
      }
    )
    
    ;; Initialize empty applicants list
    (map-set gig-applicants
      { gig-id: gig-id }
      { applicants: (list) }
    )
    
    ;; Return the new gig ID
    (ok gig-id)
  )
)

;; Apply for a gig
(define-public (apply-for-gig 
  (gig-id uint) 
  (bid-amount uint) 
  (proposal (string-utf8 500)))
  
  (let ((applicant tx-sender)
        (block-time block-height))
    
    ;; Check if gig exists and is open
    (match (map-get? gigs { gig-id: gig-id })
      gig-data (begin
        (asserts! (is-eq (get status gig-data) STATUS-OPEN) ERR-INVALID-STATUS)
        (asserts! (not (is-eq applicant (get client gig-data))) ERR-NOT-AUTHORIZED)
        (asserts! (not (is-applicant gig-id applicant)) ERR-ALREADY-APPLIED)
        
        ;; Initialize freelancer reputation if needed
        (initialize-reputation applicant)
        
        ;; Store application data
        (map-set applications
          { gig-id: gig-id, applicant: applicant }
          {
            bid-amount: bid-amount,
            proposal: proposal,
            application-time: block-time
          }
        )
        
        ;; Add to applicants list
        (add-applicant gig-id applicant)
        
        (ok true)
      )
      ERR-GIG-NOT-FOUND
    )
  )
)

;; Select freelancer for a gig and fund escrow
(define-public (select-freelancer (gig-id uint) (freelancer principal) (amount uint))
  (let ((client tx-sender))
    
    ;; Check if gig exists, is open, and sender is client
    (match (map-get? gigs { gig-id: gig-id })
      gig-data (begin
        (asserts! (is-eq client (get client gig-data)) ERR-NOT-CLIENT)
        (asserts! (is-eq (get status gig-data) STATUS-OPEN) ERR-INVALID-STATUS)
        (asserts! (is-applicant gig-id freelancer) ERR-NOT-APPLICANT)
        (asserts! (>= amount u0) ERR-INVALID-AMOUNT)
        
        ;; Transfer STX to escrow
        (try! (stx-transfer? amount client (as-contract tx-sender)))
        
        ;; Update gig status
        (map-set gigs
          { gig-id: gig-id }
          {
            client: (get client gig-data),
            title: (get title gig-data),
            description: (get description gig-data),
            requirements: (get requirements gig-data),
            budget: (get budget gig-data),
            deadline: (get deadline gig-data),
            status: STATUS-IN-PROGRESS,
            selected-freelancer: (some freelancer),
            creation-time: (get creation-time gig-data)
          }
        )
        
        ;; Create escrow
        (map-set escrows
          { gig-id: gig-id }
          {
            amount: amount,
            release-time: none
          }
        )
        
        (ok true)
      )
      ERR-GIG-NOT-FOUND
    )
  )
)

;; Add milestone to a gig
(define-public (add-milestone 
  (gig-id uint) 
  (description (string-utf8 200)) 
  (amount uint) 
  (deadline uint))
  
  (let ((client tx-sender))
    
    ;; Check if gig exists, is in progress, and sender is client
    (match (map-get? gigs { gig-id: gig-id })
      gig-data (begin
        (asserts! (is-eq client (get client gig-data)) ERR-NOT-CLIENT)
        (asserts! (is-eq (get status gig-data) STATUS-IN-PROGRESS) ERR-INVALID-STATUS)
        
        ;; Create the milestone
        (let ((milestone-id (create-milestone gig-id description amount deadline)))
          (ok milestone-id))
      )
      ERR-GIG-NOT-FOUND
    )
  )
)

;; Complete a milestone
(define-public (complete-milestone (gig-id uint) (milestone-id uint))
  (let ((freelancer tx-sender))
    
    ;; Check if gig exists, is in progress, and sender is selected freelancer
    (match (map-get? gigs { gig-id: gig-id })
      gig-data (begin
        (asserts! (is-eq (get status gig-data) STATUS-IN-PROGRESS) ERR-INVALID-STATUS)
        (asserts! (is-eq (some freelancer) (get selected-freelancer gig-data)) ERR-NOT-FREELANCER)
        
        ;; Check if milestone exists
        (match (map-get? milestones { gig-id: gig-id, milestone-id: milestone-id })
          milestone-data (begin
            (asserts! (is-eq (get status milestone-data) u1) ERR-INVALID-STATUS) ;; must be pending
            
            ;; Update milestone status
            (map-set milestones
              { gig-id: gig-id, milestone-id: milestone-id }
              {
                description: (get description milestone-data),
                amount: (get amount milestone-data),
                deadline: (get deadline milestone-data),
                status: u2, ;; completed
                completion-time: (some block-height)
              }
            )
            
            (ok true)
          )
          ERR-MILESTONE-NOT-FOUND
        )
      )
      ERR-GIG-NOT-FOUND
    )
  )
)

;; Approve a milestone and release payment
(define-public (approve-milestone (gig-id uint) (milestone-id uint))
  (let ((client tx-sender))
    
    ;; Check if gig exists, is in progress, and sender is client
    (match (map-get? gigs { gig-id: gig-id })
      gig-data (begin
        (asserts! (is-eq client (get client gig-data)) ERR-NOT-CLIENT)
        (asserts! (is-eq (get status gig-data) STATUS-IN-PROGRESS) ERR-INVALID-STATUS)
        
        ;; Check if milestone exists
        (match (map-get? milestones { gig-id: gig-id, milestone-id: milestone-id })
          milestone-data (begin
            (asserts! (is-eq (get status milestone-data) u2) ERR-INVALID-STATUS) ;; must be completed
            
            ;; Check escrow has sufficient funds
            (match (map-get? escrows { gig-id: gig-id })
              escrow-data (begin
                (asserts! (>= (get amount escrow-data) (get amount milestone-data)) ERR-INSUFFICIENT-FUNDS)
                
                ;; Calculate platform fee
                (let ((freelancer (unwrap! (get selected-freelancer gig-data) ERR-NOT-FREELANCER))
                      (milestone-amount (get amount milestone-data))
                      (platform-fee (calculate-platform-fee milestone-amount))
                      (freelancer-amount (- milestone-amount platform-fee)))
                  
                  ;; Transfer to freelancer
                  (try! (as-contract (stx-transfer? freelancer-amount tx-sender freelancer)))
                  
                  ;; Transfer platform fee
                  (try! (as-contract (stx-transfer? platform-fee tx-sender PLATFORM-TREASURY)))
                  
                  ;; Update escrow
                  (map-set escrows
                    { gig-id: gig-id }
                    {
                      amount: (- (get amount escrow-data) milestone-amount),
                      release-time: (get release-time escrow-data)
                    }
                  )
                  
                  (ok true)
                )
              )
              ERR-GIG-NOT-FOUND
            )
          )
          ERR-MILESTONE-NOT-FOUND
        )
      )
      ERR-GIG-NOT-FOUND
    )
  )
)

;; Mark gig as complete from client side
(define-public (complete-gig (gig-id uint) (rating uint))
  (let ((client tx-sender))
    
    ;; Check if gig exists, is in progress, and sender is client
    (match (map-get? gigs { gig-id: gig-id })
      gig-data (begin
        (asserts! (is-eq client (get client gig-data)) ERR-NOT-CLIENT)
        (asserts! (is-eq (get status gig-data) STATUS-IN-PROGRESS) ERR-INVALID-STATUS)
        (asserts! (<= rating u5) ERR-INVALID-AMOUNT) ;; Rating must be between 0-5
        
        ;; Check escrow
        (match (map-get? escrows { gig-id: gig-id })
          escrow-data (begin
            (let ((freelancer (unwrap! (get selected-freelancer gig-data) ERR-NOT-FREELANCER))
                  (remaining-amount (get amount escrow-data))
                  (platform-fee (calculate-platform-fee remaining-amount))
                  (freelancer-amount (- remaining-amount platform-fee)))
              
              ;; Update gig status
              (map-set gigs
                { gig-id: gig-id }
                {
                  client: (get client gig-data),
                  title: (get title gig-data),
                  description: (get description gig-data),
                  requirements: (get requirements gig-data),
                  budget: (get budget gig-data),
                  deadline: (get deadline gig-data),
                  status: STATUS-COMPLETED,
                  selected-freelancer: (get selected-freelancer gig-data),
                  creation-time: (get creation-time gig-data)
                }
              )
              
              ;; Transfer remaining funds to freelancer
              (try! (as-contract (stx-transfer? freelancer-amount tx-sender freelancer)))
              
              ;; Transfer platform fee
              (try! (as-contract (stx-transfer? platform-fee tx-sender PLATFORM-TREASURY)))
              
              ;; Update reputations
              (update-reputation-after-completion freelancer rating)
              
              (ok true)
            )
          )
          ERR-GIG-NOT-FOUND
        )
      )
      ERR-GIG-NOT-FOUND
    )
  )
)

;; Raise a dispute for a gig
(define-public (raise-dispute (gig-id uint) (evidence (string-utf8 1000)))
  (let ((sender tx-sender))
    
    ;; Check if gig exists and is in progress
    (match (map-get? gigs { gig-id: gig-id })
      gig-data (begin
        (asserts! (is-eq (get status gig-data) STATUS-IN-PROGRESS) ERR-INVALID-STATUS)
        (asserts! (is-gig-participant gig-id sender) ERR-NOT-AUTHORIZED)
        
        ;; Check if dispute already exists
        (asserts! (is-none (map-get? disputes { gig-id: gig-id })) ERR-DISPUTE-EXISTS)
        
        ;; Create dispute
        (map-set disputes
          { gig-id: gig-id }
          {
            client-evidence: (if (is-eq sender (get client gig-data)) 
                                 (some evidence) 
                                 none),
            freelancer-evidence: (if (is-eq sender (unwrap-panic (get selected-freelancer gig-data))) 
                                    (some evidence) 
                                    none),
            arbitrator: none,
            resolution: none,
            client-refund-amount: none,
            freelancer-payment-amount: none,
            dispute-time: block-height,
            resolution-time: none
          }
        )
        
        ;; Update gig status
        (map-set gigs
          { gig-id: gig-id }
          {
            client: (get client gig-data),
            title: (get title gig-data),
            description: (get description gig-data),
            requirements: (get requirements gig-data),
            budget: (get budget gig-data),
            deadline: (get deadline gig-data),
            status: STATUS-DISPUTED,
            selected-freelancer: (get selected-freelancer gig-data),
            creation-time: (get creation-time gig-data)
          }
        )
        
        (ok true)
      )
      ERR-GIG-NOT-FOUND
    )
  )
)

;; Add evidence to an existing dispute
(define-public (add-dispute-evidence (gig-id uint) (evidence (string-utf8 1000)))
  (let ((sender tx-sender))
    
    ;; Check if gig exists and is disputed
    (match (map-get? gigs { gig-id: gig-id })
      gig-data (begin
        (asserts! (is-eq (get status gig-data) STATUS-DISPUTED) ERR-INVALID-STATUS)
        (asserts! (is-gig-participant gig-id sender) ERR-NOT-AUTHORIZED)
        
        ;; Get dispute
        (match (map-get? disputes { gig-id: gig-id })
          dispute-data (begin
            ;; Update the appropriate evidence field
            (if (is-eq sender (get client gig-data))
              (map-set disputes
                { gig-id: gig-id }
                {
                  client-evidence: (some evidence),
                  freelancer-evidence: (get freelancer-evidence dispute-data),
                  arbitrator: (get arbitrator dispute-data),
                  resolution: (get resolution dispute-data),
                  client-refund-amount: (get client-refund-amount dispute-data),
                  freelancer-payment-amount: (get freelancer-payment-amount dispute-data),
                  dispute-time: (get dispute-time dispute-data),
                  resolution-time: (get resolution-time dispute-data)
                }
              )
              (map-set disputes
                { gig-id: gig-id }
                {
                  client-evidence: (get client-evidence dispute-data),
                  freelancer-evidence: (some evidence),
                  arbitrator: (get arbitrator dispute-data),
                  resolution: (get resolution dispute-data),
                  client-refund-amount: (get client-refund-amount dispute-data),
                  freelancer-payment-amount: (get freelancer-payment-amount dispute-data),
                  dispute-time: (get dispute-time dispute-data),
                  resolution-time: (get resolution-time dispute-data)
                }
              )
            )
            
            (ok true)
          )
          ERR-DISPUTE-NOT-FOUND
        )
      )
      ERR-GIG-NOT-FOUND
    )
  )
)

;; Resolve a dispute
(define-public (resolve-dispute 
  (gig-id uint) 
  (resolution (string-utf8 500)) 
  (client-refund-amount uint) 
  (freelancer-payment-amount uint))
  
  (let ((arbitrator tx-sender))
    
    ;; Check if arbitrator is authorized
    (asserts! (is-arbitrator arbitrator) ERR-NOT-ARBITRATOR)
    
    ;; Check if gig exists and is disputed
    (match (map-get? gigs { gig-id: gig-id })
      gig-data (begin
        (asserts! (is-eq (get status gig-data) STATUS-DISPUTED) ERR-INVALID-STATUS)
        
        ;; Get dispute
        (match (map-get? disputes { gig-id: gig-id })
          dispute-data (begin
            ;; Check escrow amount
            (match (map-get? escrows { gig-id: gig-id })
              escrow-data (begin
                (asserts! (>= (get amount escrow-data) (+ client-refund-amount freelancer-payment-amount)) ERR-INSUFFICIENT-FUNDS)
                
                ;; Update dispute resolution
                (map-set disputes
                  { gig-id: gig-id }
                  {
                    client-evidence: (get client-evidence dispute-data),
                    freelancer-evidence: (get freelancer-evidence dispute-data),
                    arbitrator: (some arbitrator),
                    resolution: (some resolution),
                    client-refund-amount: (some client-refund-amount),
                    freelancer-payment-amount: (some freelancer-payment-amount),
                    dispute-time: (get dispute-time dispute-data),
                    resolution-time: (get resolution-time dispute-data)
                  }
                )
                
                ;; Update reputations based on who gets more funds
                (let ((client (get client gig-data))
                      (freelancer (unwrap-panic (get selected-freelancer gig-data))))
                  (if (> freelancer-payment-amount client-refund-amount)
                    (update-reputation-after-dispute freelancer client)
                    (update-reputation-after-dispute client freelancer)
                  )
                )
                
                (ok true)
              )
              ERR-GIG-NOT-FOUND
            )
          )
          ERR-DISPUTE-NOT-FOUND
        )
      )
      ERR-GIG-NOT-FOUND
    )
  )
)