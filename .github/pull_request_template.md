## Summary

Describe the change and any intentional behavior/metric changes.

## Validation evidence

Follow [CONTRIBUTING.md](../CONTRIBUTING.md#release-validation-and-approval).

- Candidate version and development commit:
- Automated checks actually run and results:
- Applicable live query suites and results, or why not applicable:
- Workload/counter coverage and DCR lifecycle/cleanup evidence, where applicable:
- Failures, skipped checks, limitations and release blockers:

## Mandatory friendly-customer preview for a new LENS version

Every new version requires this manual gate before release to `main`. CI/lab
tests and customer validation of a previous version are not substitutes.
For a non-release PR only, state why this gate is not applicable.

- New LENS version: yes/no; if no, reason:
- Development-branch JSON version, source commit and SHA-256 hash:
- Preview test date and sanitized manual test scope:
- Customer-reported outcomes, loading/rendering observations and limitations:
- Maintainer confirmation of the result and any post-preview changes/retesting:

- [ ] For a new version, the consenting friendly customer's manual test of this
      development-branch JSON is complete, successful and maintainer-confirmed.
- [ ] Current validation evidence has been reviewed and release blockers resolved.
- [ ] Public content is sanitized; no customer identities, private correspondence,
      environment identifiers, credentials or raw telemetry are included.

Missing, unavailable or unsuccessful customer confirmation blocks a new-version
release. Leave unchecked items pending; do not treat this template as sign-off.
