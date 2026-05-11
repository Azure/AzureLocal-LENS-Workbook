# Example DCR — `dcr-azurelocal-lens-capacity-perf`

A ready-to-deploy **Azure Data Collection Rule (DCR)** ARM template that collects every performance counter and Windows event the **Azure Local LENS Workbook** Capacity tab needs to render — host-level **and** per-VM Hyper-V — in a single resource.

This is the same template that ships embedded inside the workbook's **Capacity → Overview → Show DCR Setup Guide → 🛠️ Alternative — ARM / CLI Deployment** section. It's reproduced here as a standalone, source-controllable file so you can deploy it with `az deployment group create --template-file …` (or pipe it into your IaC repo) without having to copy-paste JSON out of the workbook UI.

## What it collects

| Stream | Source | Count | Purpose |
|---|---|---:|---|
| `Microsoft-Perf` | 13 **host** performance counter paths (Processor, Memory, LogicalDisk, Network Interface, Cluster CSV File System) | 13 | Cluster-aggregate CPU / memory / storage / latency / IOPS / network throughput tiles on every Capacity sub-tab |
| `Microsoft-Perf` | 14 **Hyper-V VM** counter paths (Hypervisor Virtual Processor, Dynamic Memory VM, Virtual Storage Device, Virtual Network Adapter) | 14 | The 🖥️ **Hyper-V VMs** sub-tab and the 🪟 **Hyper-V VMs on: {cluster}** section on the 🔍 **Single cluster** sub-tab |
| `Microsoft-Event` | `Microsoft-Windows-SDDC-Management/Operational` — `EventID=3002` | 1 XPath | Storage Pool / Volume health, capacity, and forecast tiles |

**27 counter paths + 1 event XPath**, sampled at 60 s, all routed to a single Log Analytics workspace.

## Prerequisites

- An **Azure Log Analytics workspace** in the same region as the DCR. Note its **resource ID**.
- A **resource group** to hold the DCR (often the same RG as your Azure Local cluster, but any RG in the same subscription/region works).
- Every Azure Local node should already be **Arc-enabled** (`microsoft.hybridcompute/machines`) with the **Azure Monitor Agent (AMA)** extension installed. If you can already see your nodes in the portal under *Machines — Azure Arc*, you're set.

## Deploy

### 1. Save the template locally

Either clone this repo or download just the JSON:

```bash
curl -L -o dcr-azurelocal-capacity-perf.json \
  https://raw.githubusercontent.com/Azure/AzureLocal-LENS-Workbook/main/example-dcr-template/dcr-azurelocal-capacity-perf.json
```

### 2. Deploy the DCR

```bash
az deployment group create \
  --resource-group <rg> \
  --template-file dcr-azurelocal-capacity-perf.json \
  --parameters \
      workspaceResourceId=/subscriptions/<subId>/resourceGroups/<la-rg>/providers/Microsoft.OperationalInsights/workspaces/<la-workspace>
```

Optional overrides:

| Parameter | Default | Notes |
|---|---|---|
| `dcrName` | `dcr-azurelocal-lens-capacity-perf` | Must be unique in the resource group. |
| `location` | `[resourceGroup().location]` | **Must match the Log Analytics workspace region** — see callout below. |
| `workspaceResourceId` | *(required)* | Full ARM resource ID of the LAW. |

> 🌍 **Region note — RG location vs. DCR/LAW region.** A resource group's `location` is metadata only; the resources *inside* it can live in any region. What matters here is that the **DCR and the Log Analytics workspace must be in the same region** (it's a hard Azure Monitor requirement). The template's `location` parameter defaults to `[resourceGroup().location]`, which is convenient when the RG you're deploying into is already in the LAW's region — but if you're deploying the DCR into an RG whose default location is **different** from the LAW's region, you **must** override the parameter explicitly, otherwise the deployment will fail with a region-mismatch error:
>
> ```bash
> # Look up the LAW's region
> LAW_REGION=$(az monitor log-analytics workspace show \
>                --ids /subscriptions/<subId>/resourceGroups/<la-rg>/providers/Microsoft.OperationalInsights/workspaces/<la-workspace> \
>                --query location -o tsv)
>
> # Pass it through at deployment time
> az deployment group create \
>   --resource-group <rg> \
>   --template-file dcr-azurelocal-capacity-perf.json \
>   --parameters \
>       workspaceResourceId=/subscriptions/<subId>/resourceGroups/<la-rg>/providers/Microsoft.OperationalInsights/workspaces/<la-workspace> \
>       location=$LAW_REGION
> ```
>
> The DCR will land in `$LAW_REGION` while still belonging to whatever RG you chose. **DCR associations (DCRAs) are region-agnostic** — they follow the *Arc machine's* region, not the DCR's — so the step-3 association loop works regardless of whether your Arc-enabled nodes, the DCR, the LAW, and the RG are all in the same region or spread across regions.

### 3. Associate the DCR to every Azure Local node

A DCR doesn't collect anything until it's *associated* with the machines it should pull from. Loop over the Arc-enabled machines in your cluster's resource group:

```bash
DCR_ID=$(az deployment group show \
            -g <rg> -n dcr-azurelocal-capacity-perf \
            --query properties.outputs.dcrResourceId.value -o tsv)

az connectedmachine list -g <cluster-rg> --query "[].id" -o tsv | while read MACHINE_ID; do
  az monitor data-collection rule association create \
    --name azlocal-capacity-dcra \
    --resource "$MACHINE_ID" \
    --rule-id "$DCR_ID"
done
```

> The association name (`azlocal-capacity-dcra` above) is per-machine — re-running the loop with the **same name** against the **same DCR** is idempotent.

Data typically begins flowing within a few minutes. Open the LENS workbook's Capacity tab and confirm every sub-tab populates — including the **🖥️ Hyper-V VMs** sub-tab and the per-cluster **🪟 Hyper-V VMs on: {cluster}** section.

## 💡 Multiple DCRs per machine — additive, not exclusive

A single Arc-enabled machine can have **multiple DCR associations**, and the Azure Monitor Agent collects the **union** of counters, events, and other data sources defined by **every** associated DCR. You do **not** have to choose between this DCR and any existing one.

That means you can safely:

- Deploy this template as a **dedicated `dcr-azurelocal-lens-capacity-perf`** DCR alongside whatever DCRs you already have (Defender for Cloud, custom application telemetry, `Microsoft-Process`, etc.) — both sets of counters will be collected.
- Keep operational and capacity telemetry in **separate DCRs** with different retention/destination choices.
- Roll out new counter sets incrementally without disturbing existing collection.

> ⚠️ **What you should NOT do:** redeploy this template *into the name of an existing DCR you didn't create from this file*. ARM is declarative and **replaces the entire `properties` block** of the target DCR, wiping out any counters or streams it had that aren't in this template. Either:
> 1. **(Recommended)** deploy as a **new** DCR with a unique `dcrName` and associate it alongside your existing DCRs, **or**
> 2. **Merge** — export the existing DCR (`az monitor data-collection rule show -n <name> -g <rg> -o json > existing.json`), copy the additional `counterSpecifiers` and the `windowsEventLogs` block from this template into the existing definition, and redeploy that merged file.

## 💰 Review your Log Analytics workspace data retention & cost settings

This DCR ships **27 performance counter paths sampled every 60 seconds** plus the SDDC `Event 3002` stream, ingested into your Log Analytics workspace (LAW). Ingestion volume and retention policy on that LAW are what drive Azure Monitor cost — **not** the DCR itself — so before associating this DCR to a production fleet, take a few minutes to align the workspace settings with your business monitoring and cost-optimization requirements.

Recommended quick checks on the target workspace:

- **Workspace retention period** — default is **30 days (free)**; can be extended up to 730 days (billed). Review under *Log Analytics workspace → Usage and estimated costs → Data Retention*.
- **Per-table retention overrides** — `Perf` and `Event` can be set independently of the workspace default. If you only need long-term forecast history from a subset of tables, consider lowering retention on the chatty ones.
- **Interactive vs. long-term retention** — for compliance archives, consider moving older data to **long-term (archive) retention**, which is significantly cheaper per GB than interactive retention.
- **Commitment tiers / Capacity Reservations** — at sustained ingestion above ~100 GB/day, a commitment tier (or a dedicated cluster) can materially reduce $/GB versus pay-as-you-go.
- **Daily cap** — set a daily ingestion cap as a safety net against unexpected runaway ingestion, but be aware it stops *all* ingestion to the workspace once hit (including security tables) until the cap resets.
- **Estimate impact first** — use *Log Analytics workspace → Usage and estimated costs → Data Ingestion* to see your current 30-day baseline and project the delta this DCR will add (a typical 4-node Azure Local cluster running this DCR adds on the order of low single-digit GB/day at 60 s sampling, but YMMV).

📚 **Reference**: [Azure Monitor — Cost optimization and Azure Monitor (best practices)](https://learn.microsoft.com/azure/azure-monitor/fundamentals/best-practices-cost) — covers all of the above plus DCR-side filtering / transformations you can use to drop unwanted rows *before* they hit the workspace (the cheapest GB is the one you never ingest).

> **TL;DR:** the LENS workbook only **reads** from your LAW; it does not influence retention, sampling, or cost. Choose retention and tier on the workspace itself, not on the DCR.

## 🔁 Heads-up: overlap with the Arc *Cluster Insights* auto-managed DCR

If the cluster you're deploying this DCR onto **also has Arc *Cluster Insights* enabled**, the Microsoft auto-managed DCR that comes with it is already collecting a curated set of host performance counters plus the following Windows event streams:

```text
Microsoft-Windows-SDDC-Management/Operational!*[System[(EventID=3000 or EventID=3001 or EventID=3002 or EventID=3003 or EventID=3004)]]
microsoft-windows-health/operational!*
```

The **Azure Monitor Agent does NOT deduplicate across DCRs** — it evaluates each associated DCR independently. So when two DCRs collect the **same** counter or event into the **same** workspace, each matching row is ingested **twice** (same `TimeGenerated`, same `Computer`, same value), which means **2× ingestion cost** for the overlap and KQL aggregates like `avg(CounterValue)` double-count unless you pre-summarize per minute / per source.

**Overlap with this template by default (`EventID=3002` only):**

| Item | In this template | In Cluster Insights' DCR | Same workspace → duplicate? |
|---|:---:|:---:|:---:|
| `Microsoft-Windows-SDDC-Management/Operational` Event 3002 | ✅ | ✅ | ⚠️ Yes |
| `Microsoft-Windows-SDDC-Management/Operational` Events 3000 / 3001 / 3003 / 3004 | ❌ | ✅ | — |
| `microsoft-windows-health/operational!*` | ❌ | ✅ | — |
| `Cluster CSV File System(*)` perf counters | ✅ | ❌ (the gap LENS exists to close) | — |
| `Hyper-V *` perf counters | ✅ | ❌ (typically) | — |
| Generic host counters (`Processor`, `Memory`, `LogicalDisk`, `Network Interface`) | ✅ | Partial overlap | ⚠️ Possible duplication on overlapping paths |

**Recommendations to keep cost in check:**

1. **Pick *one* workspace per data domain.** The simplest answer is: if Cluster Insights is enabled on the cluster, point Cluster Insights and this DCR at the **same** workspace and accept the small Event 3002 duplication (~one event per node per cluster-membership change — typically a handful per day, negligible cost) **OR** point this DCR at a **different** workspace and keep them fully separated.
2. **Don't broaden this template's `windowsEventLogs` block by default.** LENS today only consumes `EventID=3002` (used to build the cluster-node map for storage forecasts). The other four SDDC IDs and the `microsoft-windows-health` channel are not read by any LENS query — so adding them to *this* DCR while Cluster Insights is also enabled would simply double-ingest data the workbook doesn't display.
3. **Use DCR transformations / filters** ([Cost optimization guide](https://learn.microsoft.com/azure/azure-monitor/fundamentals/best-practices-cost)) if you do need overlap for other reasons but want to drop a subset before ingestion.

### ✏️ Optional — extend this template's event scope for Cluster-Insights parity

If Cluster Insights is **not** enabled on this cluster (or it points to a different workspace), and you'd like *this* DCR to also collect the broader SDDC event set + the Windows health channel — so the same LAW has the full Azure Local event stream available for ad-hoc KQL and future LENS features — replace the existing `windowsEventLogs` block in `dcr-azurelocal-capacity-perf.json`:

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

## Verifying it works

After ~5–10 minutes you should see rows when you run these against your LAW:

```kusto
Perf
| where TimeGenerated > ago(15m)
| where ObjectName == "Cluster CSV File System"
| summarize count() by Computer, CounterName
| order by Computer asc
```

```kusto
Perf
| where TimeGenerated > ago(15m)
| where ObjectName startswith "Hyper-V"
| summarize count() by Computer, ObjectName
| order by Computer asc
```

```kusto
Event
| where TimeGenerated > ago(1h)
| where Source == "Microsoft-Windows-SDDC-Management" and EventID == 3002
| project TimeGenerated, Computer, RenderedDescription
| take 10
```

If `Cluster CSV File System` or `Hyper-V *` returns no rows after 10+ minutes:

1. Confirm the **DCR association exists** for the machine:
   `az monitor data-collection rule association list --resource <machine-id>`
2. Confirm the **AMA extension is installed** and healthy on the node:
   `az connectedmachine extension list -g <cluster-rg> -m <node> -o table`
3. Confirm the **DCR and the LAW are in the same region** (a common gotcha).

## Related

- **Workbook**: the same template is embedded under Capacity → Overview → *Show DCR Setup Guide* → 🛠️ *Alternative — ARM / CLI Deployment*.
- **Hyper-V-only scope**: if you want to collect *only* the 14 Hyper-V counters (e.g. one DCR per data domain), the 🖥️ **Hyper-V VMs** sub-tab inside the workbook ships its own dedicated, scoped ARM template.
- **Portal alternative**: the *Custom counter specifier* flow described in the workbook lets you add the 5 missing `Cluster CSV File System(*)` paths to an **existing** DCR without ARM — useful for ad-hoc additions, but not source-controlled.
