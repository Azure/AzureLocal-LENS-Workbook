# Azure Local LENS Content Audit

Phase 1 baseline and recommendations, 2026-08-27.

## Scope and method

This audit covers customer-facing text and links in the 12 split workbook sources plus `shared/header.json` and `shared/parameters.json`. The generated monolithic workbook is excluded because it is built from those sources.

`node scripts/audit-content.js` walks rendered text fields, records their source item, counts words, inventories clickable links, identifies repeated text, and flags length outliers for editorial review. A flag is a triage signal, not an automatic failure.

Per-tab files embed copies of shared parameters and navigation. The audit counts `items[2]` from each tab and counts the shared files once, matching `scripts/build-monolithic.js`.

## Baseline

| Measure | Result |
| --- | ---: |
| Source files | 14 |
| Customer-facing text entries | 968 |
| Customer-facing words | 15,440 |
| Length-review flags | 88 |
| Unique clickable external destinations | 44 |
| Repeated text groups | 35 |

Capacity contains 10,513 words, 68% of all customer-facing copy. Capacity Overview and Hyper-V alone contain 7,548 words. This concentration, not a workbook-wide excess, is the primary scanability issue.

| Source | Words | Length flags |
| --- | ---: | ---: |
| Capacity Overview | 4,585 | 21 |
| Capacity Hyper-V | 2,963 | 22 |
| Capacity Single Cluster | 2,053 | 26 |
| System Health | 904 | 4 |
| Capacity Multi-Cluster | 826 | 7 |
| Update Progress | 720 | 2 |
| AKS Arc | 718 | 1 |
| Overview | 710 | 0 |
| ARB Status | 667 | 4 |
| Machines | 590 | 0 |
| Shared header | 292 | 1 |
| VMs | 269 | 0 |

The largest individual blocks are `dcr-setup-deploy-steps` (711 words), `hyperv-limitations-note` (661), `dcr-setup-arm-template` (450), `hyperv-inv-help` (435), and `dcr-setup-why-faq` (388).

## Priority findings

### Resolved in v1.1.0: navigation defects

The audit identified three customer links that required replacement. All three were corrected before v1.1.0 publication:

| Source item | Previous destination | Finding | Resolved destination |
| --- | --- | --- | --- |
| AKS Arc knowledge links | `azure/aks/hybrid/aks-hybrid-options-overview` | Redirects to the retired AKS on Windows Server offering, not AKS on Azure Local | `azure/aks/aksarc/aks-local-overview` |
| Capacity DCR links (Overview and Hyper-V) | `azure/azure-monitor/agents/data-collection-rule-associations` | Returns 404 | `azure/azure-monitor/data-collection/data-collection-rule-associations` |
| Capacity Overview DCR links | `windows-server/failover-clustering/manage-cluster-shared-volumes` | Returns 404 | `windows-server/failover-clustering/failover-cluster-csvs` |

The ARB links also used the fragment `#arc-resource-bridge-is-offline`, which was not present in the current article fetched during this audit. v1.1.0 removes the stale fragment and retains the working `troubleshoot-resource-bridge` article URL.

### P1: Restore Capacity's decision path

Keep the four-tab journey: Overview, Single Cluster, Multi-Cluster, Hyper-V VMs. Change the information hierarchy inside it:

1. Show state and risk first: current utilization, headroom, threshold crossings, and forecast confidence.
2. Put the next action beside the evidence: drill into a cluster, inspect a node or VM, review collection coverage, or open alert setup.
3. Keep one short inline explanation per concept.
4. Move setup procedures, counter inventories, formulas, and limitations behind progressive disclosure or to the existing repository guide.

The DCR guide is useful but currently interrupts the operational path. `dcr-setup-deploy-steps`, `dcr-setup-arm-template`, `dcr-setup-required-counters`, `dcr-setup-required-eventlogs`, and `dcr-setup-portal-method` should become a short readiness summary plus links to the maintained example DCR guide. Preserve exact counter and verification details in that guide.

Shorten `capacity-n1-memory-tip` to the decision-relevant explanation. Move formulas and edge cases into a tooltip or expanded “How calculated” section. Retain forecast disclaimers, but use one shared wording per view instead of repeating it near each chart.

The “real used” and “real available” explanation is important because thin provisioning makes portal and WAC figures differ. Retain the distinction, but avoid presenting a single value without its scope and assumptions. Use labels such as “physical footprint,” “logical written,” and “estimated new logical capacity,” with reserve and resiliency assumptions visible.

### P1: Make empty states diagnostic

No-data messages currently mix three different meanings:

- Healthy zero: no failures, disconnected resources, or expiring certificates.
- Empty scope: no resources match subscription or workbook filters.
- Missing telemetry: resources exist, but the required table, counter, event, or update summary is absent.

Each message should identify exactly one of these states where the query can distinguish it. Do not imply “healthy” when the query can also be empty because scope or telemetry is missing. System Health's “clusters may not be reporting Update Summaries yet” and Capacity's counter-specific messages are good diagnostic patterns, although the latter should link to setup instead of repeating setup prose.

### P1: Standardize operational terminology

- Use “Azure Local node” for the managed host concept. Reserve “physical machine” for text that must distinguish hardware from VMs.
- Expand “Arc Resource Bridge (ARB)” at first use on every independently reachable tab.
- Use one status pair consistently: “Connected/Disconnected” rather than mixing “Non-Connected,” “Disconnected,” and “Offline” for the same signal.
- Keep “Offline” for a resource state that is genuinely distinct from Azure Arc connection status.
- Define Capacity terms once: provisioned, committed, physical footprint, logical written, available, and forecast.
- Replace “Days how long the forecast should be” with “Number of days to project.”

## Per-tab disposition

| Area | Retain | Shorten | Move or consolidate | Remove |
| --- | --- | --- | --- | --- |
| Shared header | Global filters, support and learning links | `filter-instructions` to task-first steps | Detailed filter examples into one expandable help block | Repeated explanation already present in controls |
| Overview | Fleet summary, health and update risk hierarchy | Ambiguous “no clusters” messages | Keep detailed remediation in owning tabs | Parenthetical empty-state hedges such as “or no clusters match” |
| Machines | Node inventory, Arc status, failed extension sections | Intro and extension labels | Put one remediation link next to disconnected and failed states | Repeated warning symbols in prose |
| VMs | Inventory, status, OS and deployment trends | Scope-empty messages | Align intro with the operational jobs shown | None identified |
| AKS Arc | Cluster health, versions, extensions, Flux, certificate risk | Dense opening sentence | Put remediation links beside failed extension and Flux sections | Retired AKS on Windows Server link |
| ARB Status | Offline threshold, resource-specific alert links | `arb-manual-alert-steps` | One alert setup guide plus a “view rules” action | Duplicate generic alert navigation |
| System Health | Health checks, readiness matrix, remediation links | `detailed-health-check-results-tip` and matrix explainer | “How to read” detail into an expandable block | None identified |
| Update Progress | In-flight status, history, error details | Intro to “track, diagnose, verify” | Consolidate update phases, failures, and known-issues links | Duplicate troubleshooting links where row remediation already exists |
| Capacity Overview | Summary and coverage indicators | N-1 memory explanation | DCR procedure and formulas into progressive help or repository docs | Duplicate counter/setup prose |
| Capacity Single Cluster | Node and workload drill-down, source-specific no-data help | Repeated source and forecast caveats | One setup pointer and one disclaimer per section | Repeated “Show DCR Setup Guide” wording |
| Capacity Multi-Cluster | Exhaustion table, comparison charts, forecast caveat | Filter descriptions and “How this works” | Put alert/action entry beside the exhaustion table after validation | Repeated setup wording |
| Capacity Hyper-V | VM inventory, six performance views, scope caveats | Inventory help and 661-word limitations block | Counter deployment and verification into the common DCR guide | Duplicate setup guidance already maintained in Capacity Overview |

## Actions and alerts

The workbook already proves two action patterns:

- Standard resource links using `https://portal.azure.com/#@/resource{resourceId}`.
- Resource-aware alert links in ARB Status using `CreateAlertRuleFromResourceBlade` for Resource Health and Activity Log alerts.

Capacity forecast charts do not currently expose alert creation. Do not copy the ARB action blindly: forecast results are Log Analytics calculations, not Resource Health events. First test a grid or adjacent action that opens scheduled query rule creation with the correct workspace, query, scope, threshold, evaluation window, and dimensions. If full prefill is unsupported, link to concise alert guidance and expose the query for reuse.

Authenticated portal validation is required for these hard-coded blades before release:

- `CreateAlertRuleFromResourceBlade` and its `alertType` parameters.
- `DataCollectionRulesBlade`.
- `ActionGroupsTemplateBlade` and Alerts v2 browse blade.
- Azure Local `SingleInstanceHistoryDetails.ReactView`.
- Grid context blades populated with KQL `pack()` values.

## Recommended implementation sequence

1. Completed in v1.1.0: replace the three confirmed stale or mismatched links and remove the stale ARB fragment.
2. Establish a small terminology and empty-state style contract in contributor guidance and tests.
3. Redesign Capacity Overview copy first: compact the N-1 explanation and collapse the DCR setup material.
4. Apply the same setup pointer, forecast disclaimer, and terminology across Single Cluster, Multi-Cluster, and Hyper-V.
5. Tighten isolated long blocks in System Health and ARB Status.
6. Run an authenticated portal action spike, then implement only the alert actions that preserve correct scope and query semantics.
7. Validate with the full workbook test suite, shared-parameter parity, monolithic rebuild, accessibility lint, authenticated portal rendering, and representative live data.

## Acceptance measures

Measure the edited source set with the same inventory script. Suggested targets are directional and should not override clarity:

- Reduce Capacity customer-facing words by at least 30% while retaining all operational facts in context or linked documentation.
- Reduce Capacity markdown blocks over 140 words from 17 to no more than 5.
- Keep confirmed 404 and mismatched customer links eliminated through regression checks.
- Ensure every independently reachable tab expands acronyms at first use.
- Classify every no-data message as healthy zero, empty scope, missing telemetry, or insufficient history.
- Give each critical or warning result a next action or a clearly labeled reason why no direct action is available.

## Validation boundary

This phase validates source structure, copy inventory, public documentation destinations, and existing action construction. It does not claim that KQL returns correct live results, authenticated portal blades render, chart layouts fit at all viewport sizes, or alert rules can be safely pre-populated. Those require the live-data and portal checks listed above.