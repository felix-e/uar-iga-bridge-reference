# Control boundaries — illustrative, not operational

Catalogue validation precedes candidate routing. A blocked run returns no candidate
list; no partial candidates are published. A missing mapping, dynamic mapping,
unknown classification or duplicate mapping requires correction, not a default.
The whole supplied catalogue is checked, including unused entries.

Manager/owner/delegate selection is illustrative only. `manager_active` must be
JSON `true`, not a truthy string. An owner takes precedence over a delegate;
a selected self-reviewer blocks even if another configured reviewer exists.
No exception approval or fallback authority is inferred. Real identity aliases,
ownership validity and escalation workflows are outside this reference.

## Decision record is not a remediation receipt

A proposed decision record should identify the scoped application, account,
entitlement, tag and cycle; subject; reviewer; action; decision time; and decision
evidence reference. The fixture's minimal decision rows exist only for preview
filtering and do not claim a complete audit schema or actual decisions.

A **separate** remediation receipt should correlate to that decision and identify
the target account-entitlement, requested operation, executor, attempt time,
verified outcome and authoritative evidence reference. Pending, failed and
unverified outcomes must remain distinguishable from verified completion.

For example, a synthetic `remove` decision for `account-002/entitlement-002` with
**no receipt** means removal is requested, not that access is revoked. A notification
preview is neither a delivery receipt nor a remediation receipt. Even an attempted
operation is not proof of the target's final access state. No receipt ingestion,
revocation state calculation or execution is implemented here.

## Book boundaries

WORKBOOK prepares data **and writes work tables**. STAGEBOOK promotes prepared
work. MAILBOOK handles notification. TESTBOOK concerns tagged **live smoke**
activity. These conceptual boundaries come from the task brief, not inspection of
historical source. The offline suite neither runs these books nor reproduces their
storage, promotion, delivery, target access or live-smoke effects.
