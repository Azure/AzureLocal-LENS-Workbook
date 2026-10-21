# Repository Guidance

Read [CONTRIBUTING.md](../CONTRIBUTING.md) before making changes. Its development guidelines are the shared source of truth for contributors and coding agents.

## Editing and Validation

- Edit the authoritative per-tab sources under `workbooks/` or the relevant `shared/` file. Never hand-edit the generated root workbook.
- Follow the "Editing workflow" section in [CONTRIBUTING.md](../CONTRIBUTING.md), including shared-parameter synchronization when applicable, then run `node scripts/build-monolithic.js` and `node scripts/run-tests.js`.
- Preserve unrelated working-tree changes. Do not commit, push, publish, or change Azure resources unless explicitly requested.
- Offline tests check structure and regressions, not live KQL execution or portal rendering. Report which checks actually ran. Live integration tests require an explicitly confirmed subscription and workspace; follow "Optional live Azure integration tests" in [CONTRIBUTING.md](../CONTRIBUTING.md).

## Release Readiness

- For release preparation, version changes, release-readiness reviews or promotion to `main`, use the [release-validation skill](skills/release-validation/SKILL.md) and follow "Release validation and approval" in [CONTRIBUTING.md](../CONTRIBUTING.md).
- Every new LENS version requires maintainer-confirmed manual friendly-customer testing of the release candidate's development-branch JSON before release to `main`. Missing or unsuccessful confirmation blocks release; automated tests and historical customer validation do not replace it.
- Keep evidence version/commit/artifact-specific and sanitized. Do not copy private memory into release guidance, invent customer sign-off or authorize Azure writes, commits, merges or publishing on a user's behalf.

## Consistency

- Follow "Column and metric consistency" in [CONTRIBUTING.md](../CONTRIBUTING.md). Reuse established display names, units, formatters, and nearby query patterns; do not independently redefine a metric.
- Use `Instance Name` for Azure Local display headings; preserve AKS cluster terminology and `Memory Used %`. Explain technical distinctions in existing help or supported tooltips instead of making headings more technical.
- Before changing memory calculations or labels, read "Accepted memory calculation and rationale" under "Hyper-V Node Capacity" in [README.md](../README.md), including its issue/PR provenance. Preserve the accepted Cluster Insights-aligned host-memory formula and `Memory Used %` heading. Do not substitute physical-total-minus-available or percent-of-commit-limit calculations, or conflate Perf usage with ARG workload allocation and N-1 risk. Reopening the decision requires reproducible evidence and explicit maintainer agreement.
- Preserve intentional differences in thresholds, sampling windows, and scope. Discuss changes to established metric semantics before implementing them; update documentation and focused regression coverage together.

## Repository Knowledge

Use "Repository knowledge" in [CONTRIBUTING.md](../CONTRIBUTING.md) to find maintained guidance and historical rationale. In particular:

- "Hyper-V Node Capacity" in [README.md](../README.md): metric definitions, identity, sampling, and unavailable values.
- [README](../README.md): features, filters, resource joins, operational links, and prior fixes. Consult relevant history before changing behavior, but verify it against current source and tests.
- [Historical v1.1.0 content audit](../CONTENT-AUDIT.md): rationale for earlier content decisions and unverified recommendations, not current conventions or validation evidence. Use CONTRIBUTING.md for active rules and `node scripts/audit-content.js` for fresh measurements; do not refresh the historical snapshot for each release.
- [DCR guide](../example-dcr-template/README.md): counters, collection prerequisites, associations, overlap, verification, and troubleshooting.
- [Regression runner](../scripts/run-tests.js) and [live-test harness](../scripts/run-live-tests.ps1): existing assertions and query scenarios to extend rather than duplicate.

## Public-Repository Privacy

Follow "Public-repository privacy" in [CONTRIBUTING.md](../CONTRIBUTING.md). Never copy personal details, private memory or session transcripts, customer telemetry, credentials, or environment identifiers into repository content or public discussions. Use generic placeholders and sanitized results; keep real environment values as runtime inputs.