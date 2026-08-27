# Azure Local LENS Content Audit

Post-v1.1.0 status and remaining recommendations, updated 2026-08-27.

## Scope and method

This audit covers customer-facing text and links in the 12 split workbook sources plus `shared/header.json` and `shared/parameters.json`. The generated monolithic workbook is excluded because it is built from those sources.

`node scripts/audit-content.js` walks rendered text fields, records their source item, counts words, inventories clickable links, identifies repeated text, and flags length outliers for editorial review. A flag is a triage signal, not an automatic failure.

Per-tab files embed copies of shared parameters and navigation. The audit counts `items[2]` from each tab and counts the shared files once, matching `scripts/build-monolithic.js`.

## Current baseline

| Measure | Result |
| --- | ---: |
| Source files | 14 |
| Customer-facing text entries | 949 |
| Customer-facing words | 10,030 |
| Length-review flags | 72 |
| Unique clickable external destinations | 40 |
| Repeated text groups | 33 |

Capacity contains 5,330 words, 53% of all customer-facing copy, down from the pre-v1.1.0 baseline of 10,513 words. Capacity Overview and Hyper-V together contain 2,858 words, down from 7,548. Capacity remains the largest content area, but v1.1.0 removed the previous concentration of embedded setup procedures and repeated guidance.

| Source | Words | Length flags |
| --- | ---: | ---: |
| Capacity Single Cluster | 1,718 | 25 |
| Capacity Overview | 1,646 | 12 |
| Capacity Hyper-V | 1,212 | 17 |
| System Health | 750 | 4 |
| Update Progress | 720 | 2 |
| AKS Arc | 718 | 1 |
| Overview | 710 | 0 |
| Capacity Multi-Cluster | 667 | 6 |
| ARB Status | 614 | 4 |
| Machines | 570 | 0 |
| Shared header | 292 | 1 |
| VMs | 269 | 0 |
| Capacity navigation | 87 | 0 |
| Shared parameters | 57 | 0 |

The largest individual blocks are `filter-instructions` (157 words), `hyperv-limitations-note` (152), `dcr-setup-readiness` (151), `sc-hyperv-notes` (140), and `hyperv-dcr-readiness` (128). Length flags remain editorial triage signals, not automatic defects.

## Priority findings

### Resolved in v1.1.0: navigation defects

The audit identified three customer links that required replacement. All three were corrected before v1.1.0 publication:

| Source item | Previous destination | Finding | Resolved destination |
| --- | --- | --- | --- |
| AKS Arc knowledge links | `azure/aks/hybrid/aks-hybrid-options-overview` | Redirects to the retired AKS on Windows Server offering, not AKS on Azure Local | `azure/aks/aksarc/aks-local-overview` |
| Capacity DCR links (Overview and Hyper-V) | `azure/azure-monitor/agents/data-collection-rule-associations` | Returns 404 | `azure/azure-monitor/data-collection/data-collection-rule-associations` |
| Capacity Overview DCR links | `windows-server/failover-clustering/manage-cluster-shared-volumes` | Returns 404 | `windows-server/failover-clustering/failover-cluster-csvs` |

The ARB links also used the fragment `#arc-resource-bridge-is-offline`, which was not present in the current article fetched during this audit. v1.1.0 removes the stale fragment and retains the working `troubleshoot-resource-bridge` article URL.

### Completed in v1.1.0: Restored Capacity's decision path

The four-tab journey remains Overview, Single Cluster, Multi-Cluster, and Hyper-V VMs. v1.1.0 changed the information hierarchy inside it to:

1. Show state and risk first: current utilization, headroom, threshold crossings, and forecast confidence.
2. Put the next action beside the evidence: drill into a cluster, inspect a node or VM, review collection coverage, or open alert setup.
3. Keep one short inline explanation per concept.
4. Move setup procedures, counter inventories, formulas, and limitations behind progressive disclosure or to the existing repository guide.

The embedded DCR procedures no longer interrupt the operational path. `dcr-setup-deploy-steps`, `dcr-setup-arm-template`, `dcr-setup-required-counters`, `dcr-setup-required-eventlogs`, and `dcr-setup-portal-method` were replaced by a short readiness summary and links to the maintained example DCR guide, where the exact counter and verification details remain.

`capacity-n1-memory-tip` now contains the decision-relevant explanation, and forecast guidance is consolidated by view instead of repeated near each chart.

The thin-provisioning distinction remains in `capacity-arg-vs-monitor-tip`, including the restored PowerShell example for calculating pool-level real available capacity with reserve and resiliency adjustments.

### Completed in v1.1.0: Made empty states diagnostic

No-data messages previously mixed four different meanings:

- Healthy zero: no failures, disconnected resources, or expiring certificates.
- Empty scope: no resources match subscription or workbook filters.
- Missing telemetry: resources exist, but the required table, counter, event, or update summary is absent.
- Insufficient history: the selected time range does not contain enough samples for the calculation.

Customer-facing guidance now defines these four states in `CONTRIBUTING.md`, and regression tests reject generic “No data/results/resources/records/information” messages. Query-specific messages name scope, telemetry, history, or the absent warning condition where the query can distinguish it. Live-data validation remains necessary to prove that each query selects the correct state at runtime.

### Completed in v1.1.0: Standardized operational terminology

- Use “Azure Local node” for the managed host concept. Reserve “physical machine” for text that must distinguish hardware from VMs.
- Expand “Arc Resource Bridge (ARB)” at first use on every independently reachable tab.
- Use one status pair consistently: “Connected/Disconnected” rather than mixing “Non-Connected,” “Disconnected,” and “Offline” for the same signal.
- Keep “Offline” for a resource state that is genuinely distinct from Azure Arc connection status.
- Define Capacity terms once: provisioned, committed, physical footprint, logical written, available, and forecast.
- Replaced “Days how long the forecast should be” with “Number of days to project.”

Contributor guidance and regression tests now enforce the principal terminology and empty-state rules. First-use acronym expansion on every independently reachable tab remains a manual release review item.

## Current per-tab disposition

| Area | v1.1.0 outcome | Remaining follow-up |
| --- | --- | --- |
| Shared header | Global filters, support links, and task guidance retained | `filter-instructions` is now the largest block at 157 words; review only if usability testing shows friction |
| Overview | Fleet summary and diagnostic empty states retained | Validate authenticated portal remediation paths |
| Machines | Node inventory, Arc status, extension terminology, and remediation retained | No content defect identified |
| VMs | Inventory, status, OS, deployment trends, and scope guidance retained | No content defect identified |
| AKS Arc | Retired AKS on Windows Server destination replaced by the AKS on Azure Local overview | No content defect identified |
| ARB Status | Alert guidance consolidated and shortened | Validate authenticated alert blades and parameters |
| System Health | Health-check and readiness guidance shortened while preserving operational facts | Review authenticated remediation links during portal validation |
| Update Progress | In-flight status, history, error details, and troubleshooting retained | No content defect identified |
| Capacity Overview | DCR procedures moved to maintained docs; N-1 and storage guidance shortened; S2D example retained | Validate any future alert action before adding it |
| Capacity Single Cluster | Setup pointers and forecast/source caveats consolidated | Length flags remain available for editorial review |
| Capacity Multi-Cluster | Forecast and setup guidance consolidated | Validate any future scheduled-query alert workflow |
| Capacity Hyper-V | Limitations reduced from 661 to 152 words; inventory help from 435 to 125; deployment detail moved to maintained docs | Length flags remain available for editorial review |

## Actions and alerts

The workbook already proves two action patterns:

- Standard resource links using `https://portal.azure.com/#@/resource{resourceId}`.
- Resource-aware alert links in ARB Status using `CreateAlertRuleFromResourceBlade` for Resource Health and Activity Log alerts.

Capacity forecast charts do not currently expose alert creation. Do not copy the ARB action blindly: forecast results are Log Analytics calculations, not Resource Health events. First test a grid or adjacent action that opens scheduled query rule creation with the correct workspace, query, scope, threshold, evaluation window, and dimensions. If full prefill is unsupported, link to concise alert guidance and expose the query for reuse.

Authenticated portal validation remains outstanding for these hard-coded blades. It does not block this content-only fast-follow because no blade or action URL changed:

- `CreateAlertRuleFromResourceBlade` and its `alertType` parameters.
- `DataCollectionRulesBlade`.
- `ActionGroupsTemplateBlade` and Alerts v2 browse blade.
- Azure Local `SingleInstanceHistoryDetails.ReactView`.
- Grid context blades populated with KQL `pack()` values.

## Implementation status and remaining sequence

1. Completed in v1.1.0: replace the three stale or mismatched links and remove the stale ARB fragment.
2. Completed in v1.1.0: establish terminology and empty-state guidance in contributor documentation and tests.
3. Completed in v1.1.0: compact Capacity Overview guidance and move detailed DCR procedures to maintained documentation.
4. Completed in v1.1.0: consolidate setup pointers, forecast disclaimers, and terminology across Capacity views.
5. Completed in v1.1.0: tighten the identified long blocks in System Health and ARB Status.
6. Remaining: run an authenticated portal action spike, then implement only alert actions that preserve correct scope and query semantics.
7. Local validation completed: full workbook suite, shared-parameter parity, monolithic rebuild, gallery validation, and accessibility checks. Authenticated portal rendering and representative live-data checks remain separate release activities when runtime behavior changes.

## Acceptance measures

The edited source set was measured with the same inventory script:

- Completed: Capacity customer-facing words fell 49% from 10,513 to 5,330, exceeding the 30% target while retaining detailed procedures in linked documentation.
- Completed: Capacity markdown blocks over 140 words fell from 17 to 2, below the target of 5.
- Completed: confirmed 404 and mismatched customer links are eliminated and covered by regression checks.
- Implemented: the contributor contract requires first-use acronym expansion; independently reachable tabs still need manual release review.
- Implemented: no-data guidance defines healthy zero, empty scope, missing telemetry, and insufficient history; regression checks reject generic empty messages.
- Remaining design criterion: each critical or warning result should provide a next action or clearly state why no direct action is available.

## Validation boundary

This audit validates source structure, copy inventory, public documentation destinations, and existing action construction. It does not claim that KQL returns correct live results, authenticated portal blades render, chart layouts fit at all viewport sizes, or alert rules can be safely pre-populated. Those require the live-data and portal checks listed above. No KQL changed in the v1.1.0 content release or this fast-follow.