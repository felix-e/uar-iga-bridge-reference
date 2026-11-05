# Historical books — reference only

These four complete, sanitised historical derivatives preserve the original macOS books for inspection. **Do not execute, dot-source, import or run selected blocks.** Each starts with an unconditional throw. Removing it or selecting later blocks exposes historical database, authentication, filesystem and email call sites, including ungated mutations in WORKBOOK.

| Derivative (repository root) | Source basename | Functions | Ordered STEP markers |
| --- | --- | ---: | ---: |
| WORKBOOK.ps1 | WORKBOOK-mac.ps1 | 3 | 13 |
| STAGEBOOK.ps1 | STAGEBOOK-mac.ps1 | 10 | 12 |
| MAILBOOK.ps1 | MAILBOOK-mac.ps1 | 8 | 9 |
| TESTBOOK.ps1 | TESTBOOK-mac.ps1 | 4 | 10 |

Books remain at repository root, preserving the historical `ops/` relationships. [Provenance](books-provenance.json) records source and derivative hashes. The [offline validator](../tools/validate-books.ps1) parses files and checks their static properties without executing them.

## Deliberate differences

- Added the initial execution barrier and reference-only notice; retained historical bodies, functions/parameters, step order and SQL table/column/statement structure.
- Replaced environment names, applications/role examples, identities/mailbox, tenant/cycle UUIDs, hosts/IP, absolute paths, run-folder references, credential filenames and internal review-application labels with consistent synthetic values. Hosts/URL targets use `.invalid`, IP uses TEST-NET-1, UUIDs are stable fake examples and paths are repository-relative. Associated review URL variable and smoke-test tags are renamed consistently.
- Set Execute/Allow flags, replace-existing and create-item opt-ins false. Historical text describing true flags remains descriptive, not permission. UTF-8/LF text normalisation only otherwise.

## Missing dependencies and historical limitations

No helpers or private populations, configurations, credentials, sessions or history are included. Missing dependencies include the referenced `ops/` Python/SQL/PowerShell helpers, mail runners/module/templates/config template, CSV inputs, run artefacts, sqlcmd, Python environment and mail modules. Referenced synthetic paths do not supply these dependencies.

Warnings and inconsistencies are intentionally retained, not repaired: development comments beside production-target defaults; mixed macOS/Windows credential guidance; WORKBOOK's immediate RoleGroups inserts and interactive Dynamic updates; MAILBOOK's differing historical queue-scope descriptions and SQL CTE reuse across statements. Static parsing does not validate SQL-engine semantics or runtime behaviour. This is not an operational runbook or a synthetic replacement implementation.

## Provenance and offline checks

The public-safe provenance records source/derivative SHA-256, the locally verified source revision, differences and limits. The operator explicitly confirmed author publication rights for the originals; **no new licence grant or ownership claim is made here**. No licence notice was added or removed.

From the repository root, with an existing PowerShell installation, offline inspection only:

```powershell
pwsh -NoProfile -NonInteractive -File ./tools/validate-books.ps1
# Optional: compare with a local read-only source checkout; no Git access:
pwsh -NoProfile -NonInteractive -File ./tools/validate-books.ps1 -SourceDirectory <local-source-directory>
```

The validator uses `Parser.ParseFile` and static assertions only: parse errors, first-statement throw, hashes, false mutation opt-ins, selected sensitive-pattern/endpoint checks and manifest counts. With source files it compares AST function signatures/parameters, ordered step identifiers, AST node-type order (excluding the added guard) and SQL shapes with literal payloads/comments masked. Literal sanitisation still requires human review; this is not a complete data-loss-prevention scanner. No book was run and no live integration was exercised.
