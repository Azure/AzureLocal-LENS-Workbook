---
name: release-validation
description: "Prepare or review an Azure Local LENS release, version bump, release-readiness check or promotion from development to main. Use for release testing, development-branch JSON friendly-customer previews, validation evidence and release approval guardrails."
---

# LENS release validation

## Authority and scope

Read [CONTRIBUTING.md](../../../CONTRIBUTING.md), especially "Release validation
and approval", before acting. It is the maintained source of truth; private
session memory and previous release outcomes are not release evidence.
Use the [PR template](../../pull_request_template.md) to record sanitized results.

## Procedure

1. Identify the candidate version, development branch and commit. Inspect the
   working tree and changed surfaces; preserve unrelated work. Agree acceptance
   expectations and any intentional metric, sampling or filtering changes.
2. Follow the guide's editing/versioning workflow. Edit authoritative sources,
   synchronize shared parameters when applicable and rebuild the monolithic JSON.
3. Run the existing [CI checks](../../workflows/test.yml). Report the actual
   commands, totals and outcomes; inspect proposed public content for private
   identifiers or credentials. Do not add tooling merely to restate existing checks.
4. Plan applicable live tests under the guide's environment-confirmation rules.
   For Capacity/Hyper-V query, discovery or map-transport changes, run both full
   live cohorts. Do not reuse a stored environment ID as approval or replace full
   release cohorts with focused fixtures.
5. If DCR scripts/templates change, follow the guide's separately approved
   lifecycle plan. Preflight host scope, overlap, agents, inherited locks and
   cleanup. Read-only approval is not write approval. Never silently remove locks
   or leave test resources behind; report blocked actions and verify preservation.
6. Keep these evidence categories separate: offline regressions, live query
   execution, applicable workload/counter coverage, DCR lifecycle/cleanup, and
   manual portal/customer validation. Never infer fleet coverage from a successful
   query, fabricate zeroes for absent data or claim unique shared-workspace attribution.
7. **Require the mandatory friendly-customer preview for every new LENS version.**
   A maintainer must arrange consent through trusted customer relationships and
   provide the generated JSON from the development branch, identified by version,
   commit and SHA-256 hash. Follow the guide's manual test scope and record the
   test date, sanitized outcomes/limitations and maintainer-confirmed result.
   Automated tests and validation of an older release do not satisfy this gate.
8. If the candidate changes after sign-off, apply the guide's retest and
   identical-artifact rules. Missing, unavailable or failed customer confirmation
   blocks release to `main`; leave the candidate in development rather than
   waiving the gate or inventing evidence.
9. Summarize current passes, failures, skipped checks and blockers in the PR.
   Obtain explicit authorization before committing, pushing, merging or
   publishing. Maintainer approval and customer evidence must precede the merge
   because the existing release workflow can publish a new version from `main`.

## Completion

Report the candidate/artifact tested, checks actually run, customer preview
status, unresolved blockers and authorization still needed. A checklist or skill
invocation is not proof that a human performed the preview. Keep customer
identities, environment values, correspondence and raw telemetry private.
