# Example LENS Data Collection Rule (DCR) — `dcr-azurelocal-lens-capacity-perf`

A ready-to-deploy **Azure Data Collection Rule (DCR)** ARM template that collects every performance counter and Windows event the **Azure Local LENS Workbook** Capacity tab needs to render — host-level **and** per-VM Hyper-V — in a single resource.

This is the same template referenced by the workbook's **Capacity → Overview → Show DCR Setup Guide** section. This standalone, source-controllable file is the **recommended deployment path**: deploy it with `az deployment group create --template-file …` (or integrate it into your IaC repository) without copying JSON out of the workbook UI.

## Contents

- [What it collects](#what-it-collects)
- [Prerequisites](#prerequisites)
- [Deploy](#deploy)
- [Keep current and future hosts associated with Azure Policy](#keep-current-and-future-hosts-associated-with-azure-policy)
- [Multiple DCRs per machine](#multiple-dcrs-per-machine)
- [Review retention and costs](#review-retention-and-costs)
- [Measure one machine](#measure-one-node)
- [Cluster Insights overlap](#cluster-insights-overlap)
- [Optional broader event scope](#optional-broader-event-scope)
- [Manual portal fallback](#manual-portal-fallback)
- [Verify collection](#verify-collection)
- [Related](#related)

## What it collects

| Stream | Source | Count | Purpose |
|---|---|---:|---|
| `Microsoft-Perf` | 12 **host** performance counter paths (Processor, Memory, LogicalDisk, Network Interface, Cluster CSVFS) | 12 | Host CPU / memory / logical-disk usage / CSV and logical-disk latency and IOPS / network throughput |
| `Microsoft-Perf` | 14 **Hyper-V VM** counter paths (Hypervisor Virtual Processor, Dynamic Memory VM, Virtual Storage Device, Virtual Network Adapter) | 14 | The 🖥️ **Hyper-V** sub-tab and the 🪟 **Hyper-V VMs on: {instance}** section on the 🔍 **Single instance** sub-tab |
| `Microsoft-Event` | `Microsoft-Windows-SDDC-Management/Operational` — `EventID=3002` | 1 XPath | CSV logical volume capacity and forecasts; not physical S2D pool headroom |

**26 performance counter paths sampled every 60 seconds, plus 1 event XPath**, all routed to a single Log Analytics workspace. Wildcard paths expand into separate counter instances. Event 3002 supplies CSV volume capacity and forecasts when emitted; it is not sampled by the 60-second performance-counter setting. Optional Managed Prometheus metrics use separate collection and are not configured by this template.

### CSV storage sources

Version 1.1.2 corrects the five invalid CSV paths reported in [Issue #108](https://github.com/Azure/AzureLocal-LENS-Workbook/issues/108). The `Cluster CSV File System` object can exist without exposing those counter names. The template now uses these four catalog-verified paths:

```text
\Cluster CSVFS(*)\Avg. sec/Read
\Cluster CSVFS(*)\Avg. sec/Write
\Cluster CSVFS(*)\Reads/sec
\Cluster CSVFS(*)\Writes/sec
```

CSV latency is the mean of read and write latency, converted from seconds to milliseconds. CSV IOPS is reads/sec plus writes/sec. Queries deduplicate per-instance, per-counter minute samples, require both directions, and exclude aggregate instances. Cluster charts average daily host values; they are not cluster-total IOPS. CSV and logical-disk series remain separate, including when both are present. Logical-disk data may include the OS disk and does not establish CSV coverage.

CSV **capacity** comes from Event 3002 `VolumeList`, not percentage counters. Queries select the latest cluster snapshot per day, deduplicate volume identities, validate size/used values, and exclude `ClusterPerformanceHistory`. Cluster percentages are size-weighted across volumes. These are logical volume capacities, not physical S2D pool headroom or resiliency-adjusted capacity.

Successful counter samples, including zero values, prove that a path can be read, not that it captures the intended VM storage workload. CSVFS file-system counters must not be presented as physical-disk metrics or assumed to cover every direct/redirected I/O path. Check them during known activity. The separate Hyper-V VHD charts measure a different layer and are not substituted for CSV data.

Existing deployments must **update the DCR definition**, not only the workbook. Preview the deployment script, then use its `-UpdateExistingDcr` option after reviewing the existing rule and taking a definition backup. An update affects every machine associated with that rule. The association-only rollback does not restore an earlier rule definition.

## Prerequisites

- An **Azure Log Analytics workspace** in the same region as the DCR. Note its **resource ID**.
- An existing **resource group** to hold the DCR in the selected subscription. Its metadata location need not match the workspace region.
- Every Azure Local machine must be **Arc-enabled** (`microsoft.hybridcompute/machines`) with the **Azure Monitor Agent (AMA)** extension installed and healthy. Appearing under *Machines — Azure Arc* confirms registration, not AMA installation or successful data collection.
- **Permissions** to deploy the DCR and create Data Collection Rule Associations on each target Arc machine, such as `Monitoring Contributor` (or `Contributor`) at the applicable scopes.

### Choose a Log Analytics workspace

**LENS does not require a dedicated Log Analytics workspace.** Reuse an existing operational workspace where its access controls, region, retention, and cost model meet your requirements. Choose a separate workspace when isolation, ownership, billing, or compliance requirements justify it. A dedicated LENS DCR does not require a dedicated workspace.

Microsoft's [workspace design guidance](https://learn.microsoft.com/azure/azure-monitor/logs/workspace-design) recommends starting with a single workspace and using the fewest workspaces needed to meet your requirements. Retention can be configured per table, so different retention needs do not always require another workspace. Separate workspaces may be needed when different resources sending data to the same table require different retention periods.

Review existing DCRs before enabling collection. Sending overlapping telemetry to the same workspace can create duplicate records; sending it to separate workspaces still incurs ingestion charges for each copy. Reuse existing collection where it already meets LENS requirements, and add only the missing coverage. See [Cluster Insights overlap](#cluster-insights-overlap) before associating another DCR.

## Deploy

> ⚠️ **Use a unique DCR name.** Do not deploy this template over an unrelated existing DCR. ARM deployments replace the target DCR's complete `properties` block and would remove data sources not present in this template. To preserve an organization-managed DCR, use the [manual portal fallback](#manual-portal-fallback) or intentionally merge the exported definitions.
>
> If Arc Cluster Insights is enabled, review [Cluster Insights overlap](#cluster-insights-overlap) before deployment. AMA does not deduplicate data sources collected by multiple DCRs into the same workspace.

### End-to-end PowerShell workflow

Use [deploy-lens-capacity-dcr.ps1](deploy-lens-capacity-dcr.ps1) with the [ARM template](dcr-azurelocal-capacity-perf.json). The script discovers reported Azure Local machines across the specified subscription, deploys the DCR in the workspace's region, associates each selected machine, and verifies every association. It does not create the resource group or workspace, install AMA, or modify other DCRs.

**Download example: PowerShell on Windows.** Download both files into the same directory. Review downloaded code before executing it; for controlled deployments, replace `main` with a reviewed release tag or commit. The `Unblock-File` step below is for this Windows workflow; omit it when running in Linux or Azure Cloud Shell.

```powershell
$BaseUrl = 'https://raw.githubusercontent.com/Azure/AzureLocal-LENS-Workbook/main/example-dcr-template'
Invoke-WebRequest "$BaseUrl/deploy-lens-capacity-dcr.ps1" -OutFile './deploy-lens-capacity-dcr.ps1'
Invoke-WebRequest "$BaseUrl/dcr-azurelocal-capacity-perf.json" -OutFile './dcr-azurelocal-capacity-perf.json'
Unblock-File './deploy-lens-capacity-dcr.ps1'
```

Sign in to the intended tenant and install the required Azure CLI extensions:

```powershell
az login --tenant '<tenant-id>'
az extension add --name resource-graph
az extension add --name monitor-control-service
```

Replace every placeholder in this example. `SubId` scopes discovery and deployment; `DcrRG` is the existing resource group that will hold the DCR, not a filter on the instance machines.

```powershell
$Settings = @{
    SubId = '<subscription-id>'
    DcrRG = '<dcr-resource-group>'
    DcrName = 'dcr-azurelocal-lens-capacity-perf'
    DcraName = 'azlocal-lens-capacity-dcra'
    LawResourceId = '/subscriptions/<subscription-id>/resourceGroups/<workspace-resource-group>/providers/Microsoft.OperationalInsights/workspaces/<workspace-name>'
}

./deploy-lens-capacity-dcr.ps1 @Settings -WhatIf
```

**Review the discovered machine list BEFORE proceeding.** The script matches `AzSHCI` Arc machines to `properties.reportedProperties.nodes` within the same subscription and resource group. Fully qualified names must agree when both sides provide them; short-name matching is allowed when one side reports only a short name. Each reported machine must match exactly one Arc resource, each Arc resource must resolve to exactly one reported machine, and exactly one instance membership is required. These checks protect both deployment and rollback. Nested lab machines can legitimately report model `Virtual Machine`; the model alone is not a membership test. Missing or ambiguous matches are displayed for review and excluded, not assumed to be guests. Cross-resource-group registrations or stale instance metadata may require investigation before those machines can be included. Discovery follows all Resource Graph pages.

`-WhatIf` performs read-only discovery and checks, then previews the proposed operation. It does not deploy or associate anything. If the DCR already exists, preview an intentional update with `@Settings -UpdateExistingDcr -WhatIf`; without that switch, the existing-DCR guard stops the script.

**After reviewing the destination**, machine list, and [collection overlap](#cluster-insights-overlap), run:

```powershell
./deploy-lens-capacity-dcr.ps1 @Settings -Confirm
```

The script prompts before changes. An intentional replacement of an existing LENS DCR requires `-UpdateExistingDcr -Confirm`. This replaces its definition and affects **all machines using that DCR**, including machines outside the current discovery results. Export and review any customized definition first. Existing same-name associations pointing to another DCR cause the script to stop before deployment.

**Example successful output (synthetic, abbreviated):**

```text
Workspace: example-operations; region: eastus; hosts: 4
WARNING: Review overlapping DCRs: AMA does not deduplicate ingestion. This script does not install AMA.
Verified 4 host associations. Verify Perf and Event ingestion after AMA refreshes.
```

The final count includes existing and newly created associations that were verified against the requested DCR. It excludes machines requiring membership review. A CLI failure stops the script without printing this success message; earlier successful changes may remain. Association success is **not** proof that AMA is sending data. Complete [Verify collection](#verify-collection) after agent configuration refreshes, and allow enough history for forecasts.

### Template-only deployment

For an existing IaC workflow, deploy the template directly and manage reviewed machine associations separately:

```bash
az deployment group create \
  --subscription '<subscription-id>' \
  --resource-group '<dcr-resource-group>' \
  --name dcr-azurelocal-capacity-perf \
  --template-file dcr-azurelocal-capacity-perf.json \
  --parameters \
      dcrName='dcr-azurelocal-lens-capacity-perf' \
      location='<workspace-region>' \
      workspaceResourceId='/subscriptions/<subscription-id>/resourceGroups/<workspace-resource-group>/providers/Microsoft.OperationalInsights/workspaces/<workspace-name>'
```

The DCR must be in the same region as its Log Analytics workspace. A resource group's location is metadata and does not constrain the region of its resources. The template defaults `location` to the resource group's location, so explicitly supply the workspace region. The PowerShell workflow resolves this automatically. Deployment alone does not create machine associations.

### Optional rollback

To remove matching associations from the **currently discovered machines**, first preview and then confirm:

```powershell
./deploy-lens-capacity-dcr.ps1 @Settings -Rollback -WhatIf
./deploy-lens-capacity-dcr.ps1 @Settings -Rollback -Confirm
```

Rollback removes only associations with the specified name that still point to the specified DCR. It is not a transaction undo: it can remove matching associations that existed before the last deployment. Machines no longer discoverable are not included. Other association names, the DCR resource, AMA, and collected Log Analytics data are retained. It does not restore a previous DCR definition or remove associations outside the selected subscription. Review any remaining users of the DCR before separately deciding whether to delete the resource.

## Keep current and future hosts associated with Azure Policy

The PowerShell workflow above is intended for an initial rollout or an explicit repair. For ongoing enforcement, assign an **Azure Policy** that associates Azure Arc-enabled Windows servers with this DCR whenever matching machines are created.

- Scope the assignment to the subscription or resource groups that contain your Azure Local physical hosts.
- Supply this DCR's full resource ID as the policy's **Data Collection Rule Resource Id** parameter.
- Review the assignment scope and exclusions carefully so Arc-enabled guest VMs do not receive the association unintentionally.
- Create a **remediation task** after assigning the policy. Policy handles new matching resources automatically, but existing machines are not updated until remediation runs.
- Keep the CLI association workflow available for targeted verification and repair.

See [Use Azure Policy to install Azure Monitor Agent and associate a DCR](https://learn.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-policy) and [Remediate noncompliant resources](https://learn.microsoft.com/azure/governance/policy/how-to/remediate-resources). For Arc-enabled servers, the Azure Monitor policy flow uses the machine's system-assigned managed identity.

## Multiple DCRs per machine

A single Arc-enabled machine can have **multiple DCR associations**, and the Azure Monitor Agent collects the **union** of counters, events, and other data sources defined by **every** associated DCR. You do **not** have to choose between this DCR and any existing one.

That means you can safely:

- Deploy this template as a **dedicated `dcr-azurelocal-lens-capacity-perf`** DCR alongside whatever DCRs you already have (Defender for Cloud, custom application telemetry, `Microsoft-Process`, etc.) — both sets of counters will be collected.
- Keep operational and capacity collection in **separate DCRs** with different sources or destinations. Retention is configured on the destination workspace or table, not on a DCR.
- Roll out new counter sets incrementally without disturbing existing collection.

> ⚠️ **Additive does not mean deduplicated.** AMA evaluates each associated DCR independently. If two DCRs collect the same performance counter or event from a machine into the same workspace, duplicate rows can be ingested and billed. Review existing DCRs before rollout and avoid overlapping data sources where practical. In particular, do **not** also deploy a separate Hyper-V DCR from the workbook: this all-in-one template already contains all 14 Hyper-V counter paths.

> ⚠️ **What you should NOT do:** redeploy this template *into the name of an existing DCR you didn't create from this file*. ARM is declarative and **replaces the entire `properties` block** of the target DCR, wiping out any counters or streams it had that aren't in this template. Either:
> 1. **(Recommended)** deploy as a **new** DCR with a unique `dcrName` and associate it alongside your existing DCRs, **or**
> 2. **Merge** — export the existing DCR (`az monitor data-collection rule show -n <name> -g <rg> -o json > existing.json`), copy the additional `counterSpecifiers` and the `windowsEventLogs` block from this template into the existing definition, and redeploy that merged file.

## Review retention and costs

This DCR ships **26 performance counter paths sampled every 60 seconds** plus the SDDC `Event 3002` stream, ingested into your Log Analytics workspace (LAW). Ingestion volume and retention policy on that LAW are what drive Azure Monitor cost — **not** the DCR itself — so before associating this DCR to a production fleet, take a few minutes to align the workspace settings with your business monitoring and cost-optimization requirements.

Recommended quick checks on the target workspace:

- **Recommended table plan: Analytics for both `Perf` and `Event`.** Use this configuration for LENS. Check each table's plan under *Log Analytics workspace → Tables*; the DCR template does not set or change table plans. Although Azure supports Basic for `Perf`, LENS has not been validated with that configuration, so Basic is not currently recommended for LENS. `Event` requires Analytics. See Microsoft's table references for [Perf](https://learn.microsoft.com/azure/azure-monitor/reference/tables/perf) and [Event](https://learn.microsoft.com/azure/azure-monitor/reference/tables/event).
- **Included retention** — Analytics Logs ingestion pricing normally includes **31 days** of analytics retention at no extra charge. This does not make ingestion free. Check your table plan and any service-specific allowances; extended retention can incur charges.
- **Per-table retention overrides** — `Perf` and `Event` can be set independently of the workspace default. If you only need long-term forecast history from a subset of tables, consider lowering retention on the chatty ones.
- **Interactive vs. long-term retention** — for compliance archives, consider moving older data to **long-term (archive) retention**, which is significantly cheaper per GB than interactive retention.
- **Commitment tiers / Capacity Reservations** — at sustained ingestion above ~100 GB/day, a commitment tier (or a dedicated cluster) can materially reduce $/GB versus pay-as-you-go.
- **Daily cap** — consider a cap only with awareness of the monitoring gaps it can cause. It is not an exact spending limit: ingestion can exceed the cap, and collection for affected tables is interrupted until reset. Use cost alerts and collection design as your primary controls.
- **Estimate impact first** — use *Log Analytics workspace → Usage and estimated costs* to review the baseline, then measure representative machines. Machine count alone is not enough: VM density, vCPU count, disks, network adapters, event volume, and overlapping DCRs all affect ingestion.

📚 **Reference**: [Azure Monitor — Cost optimization and Azure Monitor (best practices)](https://learn.microsoft.com/azure/azure-monitor/fundamentals/best-practices-cost) — covers all of the above plus DCR-side filtering / transformations you can use to drop unwanted rows *before* they hit the workspace (the cheapest GB is the one you never ingest).

> **TL;DR:** LENS reads the collected Log Analytics data. Closing the workbook does not stop collection. Configure sampling in the DCR and retention on the destination workspace or table. Preserve the required counters and sufficient history for the views you use.

**More VMs generally means more counter instances, more Log Analytics records, and higher ingestion costs.** The DCR is associated with the Arc-enabled physical host servers. AMA collects both host and per-VM Hyper-V counters from those hosts; these per-VM counters do not require AMA or a LENS DCR association inside each guest VM. More running VMs, vCPUs, virtual disks, and virtual network adapters can increase the records collected even when the physical host count stays the same.

**26 paths does not mean 26 records per machine per minute.** The configured paths remain the same, but wildcards such as `Hyper-V Hypervisor Virtual Processor(*)` expand across the available instances. The three virtual-processor paths can each produce a record for every vCPU instance at every sample. Additional aggregate instances, where exposed, also contribute.

**Estimate from measured data, not machine count.** Measure representative machines after collection stabilizes, then apply your region's current rate, currency, agreement, applicable allowances, and pricing tier using [Azure Monitor pricing](https://azure.microsoft.com/pricing/details/monitor/). For pay-as-you-go ingestion, a starting estimate is measured billable GB/day multiplied by days and the applicable price/GB, adjusted for any available allowance. An account-level allowance is shared, not a separate allowance for each machine or workspace. Retention and other enabled services can add charges. Azure bills ingestion in decimal GB (1 GB = 1,000,000,000 bytes), not GiB; see [Log Analytics cost calculations](https://learn.microsoft.com/azure/azure-monitor/logs/cost-logs).

### Example ingestion volume

**Illustrative ingestion estimate:** A two-host instance with **20 observed VMs** (12 on one host and 8 on the other, totaling 160 observed vCPUs), using 60-second performance sampling including the CSVFS counters, has an estimated billable ingestion volume of **21.1 MB/hour across both hosts**, or **15.2 GB over 30 days if sustained**. MB and GB use decimal units. This is a data-volume example, not a price estimate.

**Caveat:** This illustrative estimate is based on a one-hour ingestion baseline. Actual data volume varies with the number of machines, VM density, CSV volume count, resulting performance-counter instances, event activity, and overlapping data collection.

<a id="measure-one-node"></a>

### Measure one machine

In the target workspace's Logs view, replace the machine resource ID below. Set the query time picker to include the previous complete UTC day. This measures **all Perf and Event records attributed to that machine**, including other DCRs; it does not attribute individual records to LENS.

```kusto
let nodeResourceId = '/subscriptions/<subscription-id>/resourceGroups/<node-resource-group>/providers/Microsoft.HybridCompute/machines/<node-name>';
let windowEnd = startofday(now());
let windowStart = windowEnd - 1d;
union withsource=DataType Perf, Event
| where TimeGenerated >= windowStart and TimeGenerated < windowEnd
| where _ResourceId =~ nodeResourceId
| summarize Records=count(), BillableRecords=countif(_IsBillable =~ 'true'),
  BilledBytes=sumif(_BilledSize, _IsBillable =~ 'true') by DataType
| extend BilledGB=BilledBytes / 1e9,
  AverageBilledBytes=iff(BillableRecords > 0, todouble(BilledBytes) / BillableRecords, real(null))
| order by DataType asc
```

Before treating the result as a LENS-only estimate, inspect every association and its DCR sources/destinations. Current associations do not prove which rules were active throughout the measurement window. A single DCR can contain unrelated sources, and matching counter names do not prove exclusive origin. Use a representative period after configuration stabilizes; measure busy and quiet machines and check for data gaps. Missing rows are not proof of zero cost or complete collection. Records with missing resource IDs and late arrivals need separate investigation. This sample-time estimate is not an invoice reconciliation; use workspace usage and Azure Cost Management for actual charges.

## Cluster Insights overlap

If the instance you're deploying this DCR onto **also has Arc *Cluster Insights* enabled**, inspect its current auto-managed DCR before adding sources. The configuration commonly includes host performance counters and the following Windows event streams; managed definitions can change:

```text
Microsoft-Windows-SDDC-Management/Operational!*[System[(EventID=3000 or EventID=3001 or EventID=3002 or EventID=3003 or EventID=3004)]]
microsoft-windows-health/operational!*
```

The **Azure Monitor Agent does NOT deduplicate across DCRs**. Overlapping collection into the same workspace can produce duplicate rows and additional billed ingestion. Different sampling schedules can also produce additional samples without identical timestamps. This can inflate `count()` and `sum()` results and alter percentile weighting. Query-side deduplication does not undo ingestion charges.

**Overlap with this template by default (`EventID=3002` only):**

| Item | In this template | In Cluster Insights' DCR | Same workspace → duplicate? |
|---|:---:|:---:|:---:|
| `Microsoft-Windows-SDDC-Management/Operational` Event 3002 | ✅ | ✅ | ⚠️ Yes |
| `Microsoft-Windows-SDDC-Management/Operational` Events 3000 / 3001 / 3003 / 3004 | ❌ | ✅ | — |
| `microsoft-windows-health/operational!*` | ❌ | ✅ | — |
| `Cluster CSVFS(*)` latency and IOPS counters | ✅ | Verify existing collection | File-system layer; verify workload coverage |
| `Hyper-V *` perf counters | ✅ | ❌ (typically) | — |
| Generic host counters (`Processor`, `Memory`, `LogicalDisk`, `Network Interface`) | ✅ | Partial overlap | ⚠️ Possible duplication on overlapping paths |

**Recommendations to keep cost in check:**

1. **Reuse existing collection and add only missing coverage.** Do not assume Event 3002 volume or cost is negligible. Review the actual DCRs and measured data. Separate workspaces can provide isolation, but sending the same data to both still incurs ingestion for each copy. Choose workspace boundaries according to the [workspace guidance](#choose-a-log-analytics-workspace), not as a deduplication mechanism.
2. **Don't broaden this template's `windowsEventLogs` block by default.** LENS today only consumes `EventID=3002` (used to build the instance-machine map for storage forecasts). The other four SDDC IDs and the `microsoft-windows-health` channel are not read by any LENS query — so adding them to *this* DCR while Cluster Insights is also enabled would simply double-ingest data the workbook doesn't display.
3. **Filter only where supported and preserve required data.** Review [transformation support](https://learn.microsoft.com/azure/azure-monitor/essentials/data-collection-transformations) for the source and destination before adding a transformation. Prefer removing overlapping source definitions from a customer-managed rule when possible; do not modify an auto-managed rule without checking its service guidance.

### Optional broader event scope

If Cluster Insights is **not** enabled on this instance (or it points to a different workspace), and you'd like *this* DCR to also collect the broader SDDC event set + the Windows health channel — so the same LAW has the full Azure Local event stream available for ad-hoc KQL and future LENS features — replace the existing `windowsEventLogs` block in `dcr-azurelocal-capacity-perf.json`:

```json
"windowsEventLogs": [
  {
    "name": "azureLocalSddcEvents",
    "streams": [ "Microsoft-Event" ],
    "xPathQueries": [
      "Microsoft-Windows-SDDC-Management/Operational!*[System[(EventID=3000 or EventID=3001 or EventID=3002 or EventID=3003 or EventID=3004)]]",
      "microsoft-windows-health/operational!*"
    ]
  }
]
```

> ⚠️ **Only do this if you've confirmed Cluster Insights is NOT also ingesting these events into the same workspace** — otherwise you'll pay twice for every matching event. The LENS workbook itself does not require this expansion today.

## Manual portal fallback

Use the portal only for a small environment, a one-off correction, or when your organization requires these sources to be merged into an existing managed DCR. LENS Capacity collection uses **all 26 performance counter paths plus Event 3002**, not only the four CSVFS paths. Verify that the paths expose the expected instances on your hosts.

1. Open **Azure Monitor → Data Collection Rules** and select the existing DCR associated with the Azure Local physical hosts.
2. Inspect its current data sources and destination workspace. Do not add paths or events that another associated DCR already sends to the same workspace.
3. Under **Data sources → Performance Counters**, add or edit a source and select **Custom** mode.
4. Compare the existing coverage with all 26 exact paths in [`performanceCounters.counterSpecifiers`](dcr-azurelocal-capacity-perf.json). Remove the five obsolete CSV paths from earlier LENS versions, add missing paths, keep the sample rate at **60 seconds**, and save.
5. If Event 3002 is not already collected into this workspace, under **Data sources → Windows Event Logs**, add a **Custom** source with `Microsoft-Windows-SDDC-Management/Operational!*[System[(EventID=3002)]]`.
6. Confirm the DCR is associated with every Azure Local physical host, then run the verification queries below after AMA has refreshed.

For a new dedicated DCR or a fleet-wide rollout, use the ARM / Azure CLI deployment above instead.

## Verify collection

Allow time for AMA to refresh its configuration and for ingestion to complete. Performance data often appears within 5–10 minutes, but this is not guaranteed. Event 3002 appears only after a matching event is emitted and ingested; it does not follow the performance-counter sampling interval. Forecasts require additional history.

**Verify every machine in the deployment's reviewed machine list.** Run these queries in the destination Log Analytics workspace, replacing `<node-resource-id>` with one reviewed machine's full Arc resource ID, then repeat for the remaining machines. Set the Logs time picker to include the past hour. Each query is scoped to that machine so data from another instance cannot be mistaken for successful collection on the intended machine.

```kusto
let nodeResourceId = '<node-resource-id>';
Perf
| where TimeGenerated > ago(15m)
| where _ResourceId =~ nodeResourceId
| where ObjectName == "Cluster CSVFS"
| summarize Samples = count(), Latest = max(TimeGenerated), Maximum = max(CounterValue) by Computer, CounterName, InstanceName
| order by Computer asc
```

```kusto
let nodeResourceId = '<node-resource-id>';
Perf
| where TimeGenerated > ago(15m)
| where _ResourceId =~ nodeResourceId
| where ObjectName startswith "Hyper-V"
| summarize count() by Computer, ObjectName, CounterName
| order by Computer asc
```

```kusto
let nodeResourceId = '<node-resource-id>';
Event
| where TimeGenerated > ago(1h)
| where _ResourceId =~ nodeResourceId
| where Source == "Microsoft-Windows-SDDC-Management" and EventID == 3002
| project TimeGenerated, Computer, RenderedDescription
| take 10
```

These are targeted checks for CSV counters, Hyper-V counters, and Event 3002, not proof of all 26 counter paths. Compare the reporting machines with the reviewed deployment list and confirm the required counter coverage against the template. Check all four CSVFS counter names and non-aggregate instances during known storage activity. Missing counters are unavailable, not zero; successful all-zero samples do not prove workload coverage. Counter instances depend on the machine's roles and running workloads; investigate missing expected data rather than treating any nonempty result as complete coverage. These queries also cannot distinguish overlapping DCRs that send the same data. Event 3002 volume snapshots are instance-level data and need not be emitted by every machine.

If expected data remains absent after configuration refresh and ingestion:

1. Confirm the **DCR association exists** for the machine:
  `az monitor data-collection rule association list-by-resource --subscription <subscription-id> --resource <machine-id>`
2. Confirm the **AMA extension is installed** and healthy on the machine:
   `az connectedmachine extension list -g <cluster-rg> -m <node> -o table`
3. Confirm the **DCR and the LAW are in the same region** (a common gotcha).

## Related

- **Workbook**: Capacity → Overview → *Show DCR Setup Guide* links here as its recommended ARM / Azure CLI deployment path.
- **Hyper-V coverage**: this all-in-one DCR already contains all 14 Hyper-V counter paths required by the Capacity Hyper-V views. Do not associate another DCR that collects the same paths into the same workspace.
- **Portal alternative**: use the [manual portal fallback](#manual-portal-fallback) to merge all 26 counter paths plus Event 3002 into an existing organization-managed DCR.
