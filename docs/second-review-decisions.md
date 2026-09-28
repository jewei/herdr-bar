# Second review decisions — 2026-09-28

Two fresh agents independently checked all seven sections of the second review.
Both confirmed the two reported defects. Both also reproduced or identified
adjacent cases in the same state and protocol contracts. The review examined
`5c40c78`; later native verification and the owner's VoiceOver exclusion are
recorded separately in [native verification](native-verification.md).

| Review item | Decision and change |
| --- | --- |
| 1. Earlier fixes | Agree. Keep the buffering, cancellation, task ownership, off-main discovery, and release construction fixes closed. |
| 2. Status before layout | Agree; fix before release. Separate committed snapshot state from provisional pane-addressed observations. Layout invalidation discards provisional evidence and retains established unread state by identity. A changed mapping in a snapshot has the same protection even if its layout event has not arrived. |
| 2. Incorrect notification effects | Strengthen the recommendation. A complete provisional work cycle can reach the client before a layout notice. Rollback alone is insufficient. Only committed attention can send a notification. |
| 3. Success response variants | Agree. Require `ok` for focus and `subscription_started` for subscription acceptance. Also require `session_snapshot` for snapshot replies. Keep additive fields and correct matching-ID/error behavior. Correct permissive mock successes. |
| 4. Performance | Agree with measurement before caching. Add a repeatable workload matrix and a read-only joint app/server counter tool. Do not claim a speedup, total-memory bound, or completed performance matrix from correctness tests. Keep summary and sorting caches deferred. |
| 5. Architecture | Agree. Keep the package split, service boundary, and store. Use bounded committed/provisional state in the tracker. Give topology invalidation and transport-history gaps distinct inputs and document their effects. |
| 6. Timing tests | Agree. Add status-before-layout, complete-cycle-before-layout, unchanged-sequence delayed events, changed-mapping snapshots, and unread-move controls. Add an integration model with independent subscription positions and held snapshot replies. |
| 6. Optimized tests | Agree. Run `swift test -c release` in CI and the pinned-source release script in addition to debug tests. Test that a failed optimized suite preserves the previous release artifact. |
| 6. Runtime support | Agree. Compilation and metadata do not establish support on the oldest OS. Keep macOS 14 and real logout/login checks open. Only built and verified architectures may be distributed. |
| 7. Release process | Agree. Retain the existing fixed-source build, signing, notarization, provenance, and rollback design. Native results are evidence for their recorded candidate, not every later build. |
| 7. Documentation and UI checks | Agree. Distinguish arrival order from server chronology. Preserve completed native keyboard, notification, terminal, reconnect, contrast, and long-label evidence. VoiceOver is skipped by owner request. Larger-text and login-startup checks remain open. No new license grant or broad UI redesign is needed. |

## Additional findings

- Old status events can arrive after a newer snapshot. An unchanged authoritative
  sequence must not validate a second local work cycle. The new tests cover this
  alongside the reported late-layout case.
- Snapshot success types were unchecked too. A payload with a snapshot field
  and an unrelated discriminator must fail rather than being accepted by shape.
- A newer incompatible snapshot must break a provisional cycle. Keeping its old
  `working` evidence across a later blocked/unknown state could create another
  false completion. The reviewers checked this case during implementation.

## Accepted behavior limits

Status events contain an address, not a stable agent identity and shared event
watermark. Short event-only cycles require unchanged identity/address, a known
advanced sequence, and a matching snapshot status before attention is committed.
Missing sequences and uncertain topology can therefore lose a short completion.
Several cycles before validation produce one latest occurrence. Snapshot-only
`working` to `idle` still works without sequences.

No client-only policy can prove every address relationship if an agent moves
away and back between snapshots without an identity-bearing event. A stronger
server contract remains the long-term fix. This change does not claim globally
ordered delivery or one notification for every raw transition.
