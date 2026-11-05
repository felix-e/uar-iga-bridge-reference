# Provenance and limits

This repository contains two different kinds of material. Do not treat their origins or test results as interchangeable.

## Sanitised historical PowerShell derivatives

The four root `*BOOK.ps1` files derive from the historical macOS variants. They preserve the step order, functions, parameters and SQL structure for inspection, while deliberately substituting identifying/configuration values, disabling mutation opt-ins and blocking full-file execution. They are not the unchanged originals, the Windows variants or a runnable production package.

[Book documentation](books.md) and [source/derivative hashes](books-provenance.json) record their provenance, deliberate changes, validation and absent dependencies. No private Git history, real review populations, credentials, environment configuration or operational outputs are included. An execution guard does not make extracted fragments safe; no book was run for this publication.

The author explicitly confirmed rights to publish these sanitised derivatives. No licence has been added or changed, and no ownership attribution is invented. Public availability alone is not an open-source licence grant.

## Independently authored synthetic Python example

`bridge.py`, its fixtures and tests were independently authored from conceptual behaviours, not ported from the historical implementation. All example identifiers, inputs and expected outputs are fabricated.

This example checks the whole supplied catalogue, including unused entries. That is intentionally stricter than a historical gate scoped to roles present in an application's input. Owner-first/delegate-fallback routing and the `retain`/`remove` preview are illustrative, not the original routing or notification catalogue. No database promotion, approval ingestion, message delivery, live smoke test or remediation verification is implemented by the Python example.

## Media

The author superseded the earlier original-intro selection with **03:46 of `uar-workbook-intro-redacted-x1.15.mp4`**, using that edited export's own timeline (226 seconds). The source export and original recordings remain unchanged and private. Only a separate cropped still is included. Its source hash, decoded frame, actual presentation timestamp and crop are in [media-provenance.json](media-provenance.json); no timeline translation or final-frame substitution was used. The same derivative is used by the companion article. The earlier still is retained as a historical asset. This bridge drawing is explanatory, not proof of execution or migration.

## Evidence limits

Python test results establish the local synthetic assertions only. PowerShell parsing/static comparisons establish syntax and the checked structural/sanitisation properties only. Neither is campaign approval, a delivery receipt, completed remediation, successful IGA migration or evidence of a successful historical runner execution. No third-party research text or images have been republished.
