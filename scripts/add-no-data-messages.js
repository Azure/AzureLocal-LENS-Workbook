// Source-of-truth-aware: adds noDataMessage + noDataMessageStyle:4 to every
// visible KqlItem (type 3) in the per-tab workbook files under workbooks/
// (and shared/header.json) that does not already have one. Skips invisible
// Merge/helper data sources (no visualization). After running this script,
// run `node scripts/build-monolithic.js` to refresh the root JSON.
//
// Run from repo root:  node scripts/add-no-data-messages.js
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const WORKBOOKS_DIR = path.join(ROOT, 'workbooks');
const SHARED_HEADER = path.join(ROOT, 'shared', 'header.json');

// Items used solely as Merge data sources / non-rendered helpers — skip.
const SKIP_NAMES = new Set([
  'all-clusters-base',
  'all-clusters-aksarc-count',
  'all-clusters-vm-count',
  'arb-vm-aks-counts',
  'arb-offline-base',
  'arb-all-base',
  'aks-all-clusters-base',
  'aks-azurelocal-mapping',
  'aks-network-base',
  'aks-loadbalancers-lookup',
  'sc-vms-perf-data',
  'updates-available-base',
  'updates-available-sbe',
  'single-cluster-storage-pool-trend - Copy',
]);

// Per-item messages. Keys are the workbook item `name`. Anything not listed
// falls back to a generic message based on the visualization type.
const MESSAGES = {
  // ── Overview / Fleet ────────────────────────────────────────────────
  'pie-cluster-connectivity': "No Azure Local clusters match the current Subscription / Resource Group / Cluster Tag filters.",
  'pie-cluster-health': "No clusters match the current filters, so no health summary is available.",
  'pie-arb-status': "No Arc Resource Bridge appliances found in the selected scope.",
  'tile-total-clusters': "No clusters match the current filters.",
  'tile-connected-clusters': "No connected clusters found in the selected scope.",
  'tile-disconnected-clusters': "No disconnected clusters — all clusters appear to be connected (or no clusters match the filters).",
  'tile-percent-connected': "No clusters match the current filters.",
  'tile-total-azure-local-nodes': "No Azure Local nodes (Arc machines with kind=HCI) found in the selected scope.",
  'tile-arb-offline': "No offline Arc Resource Bridges in the selected scope.",
  'tile-healthy-clusters': "No cluster health data available — clusters may not be reporting Update Summaries yet.",
  'tile-warnings': "No warning-level health checks across the fleet.",
  'tile-failed-prechecks': "No failed pre-checks across the fleet.",
  'tile-inprogress-health': "No in-progress health checks.",
  'tile-failed-extensions': "No failed extensions across Azure Local nodes in the selected scope.",
  'tile-percent-healthy': "No cluster health data available for the selected scope.",
  'tile-total-vms': "No Arc-enabled VMs found in the selected scope.",
  'tile-total-aks-arc': "No AKS Arc clusters found in the selected scope.",
  'tile-supported-version': "No solution version data — clusters may not be reporting Update Summaries yet.",
  'tile-unsupported-version': "No clusters on unsupported versions (or no version data available).",
  'tile-update-available': "No clusters report an available update at this time.",
  'tile-update-in-progress': "No update runs currently in progress.",
  'tile-update-failed': "No clusters in a Failed update state.",
  'chart-solution-version-distribution': "No solution version data — clusters may not be reporting Update Summaries yet.",
  'cluster-deployments-bar': "No cluster deployments found in the selected time range.",
  'cluster-deployments-table': "No cluster deployments found in the selected time range.",
  'table-all-clusters': "No clusters match the current Subscription / Resource Group / Cluster Tag filters.",
  'pie-azure-hybrid-benefit': "No Azure Hybrid Benefit data — no clusters match the filters.",
  'pie-windows-server-subscription': "No Windows Server Subscription data — no clusters match the filters.",
  'pie-azure-verification-vms': "No Azure Verification for VMs data — no clusters match the filters.",
  'chart-os-version': "No node OS version data — no Arc machines (kind=HCI) match the filters.",
  'chart-hardware-class': "No hardware class data — no Arc machines (kind=HCI) match the filters.",
  'chart-billing-model': "No billing model data — no clusters match the filters.",
  'chart-hardware-vendor': "No hardware vendor data — no Arc machines (kind=HCI) match the filters.",
  'chart-cores-by-billing': "No core/billing data available for the selected scope.",
  'chart-node-count-distribution': "No node-count data — no clusters match the filters.",

  // ── Capacity & Performance ──────────────────────────────────────────
  'capacity-overview-table': "No capacity data — ensure Azure Managed Prometheus is enabled and the selected Azure Monitor Workspace is receiving metrics from your clusters.",
  'node-cpu-trend': "No CPU metrics. Confirm Azure Managed Prometheus is enabled and the cluster is sending node CPU metrics to the selected workspace.",
  'node-memory-trend': "No memory metrics. Confirm Azure Managed Prometheus is enabled and the cluster is sending node memory metrics to the selected workspace.",
  'node-storage-trend': "No storage utilisation metrics. Confirm Azure Managed Prometheus is collecting storage metrics from this cluster.",
  'node-storage-latency-trend': "No storage latency metrics. Confirm Azure Managed Prometheus is collecting S2D / volume latency metrics from this cluster.",
  'node-storage-iops-trend': "No storage IOPS metrics. Confirm Azure Managed Prometheus is collecting volume IOPS metrics from this cluster.",
  'node-network-throughput-trend': "No network throughput metrics. Confirm Azure Managed Prometheus is collecting NIC counters from this cluster.",
  'mc-cpu-forecast': "Not enough historical CPU data in the selected time range to build a forecast. Try widening the time range.",
  'mc-mem-forecast': "Not enough historical memory data in the selected time range to build a forecast. Try widening the time range.",
  'mc-stor-pct-forecast': "Not enough historical storage data in the selected time range to build a forecast. Try widening the time range.",
  'mc-stor-tb-forecast': "Not enough historical storage data in the selected time range to build a forecast. Try widening the time range.",
  'mc-storage-latency': "No multi-cluster storage latency metrics for the selected scope and time range.",
  'mc-storage-iops': "No multi-cluster storage IOPS metrics for the selected scope and time range.",
  'mc-network-throughput': "No multi-cluster network throughput metrics for the selected scope and time range.",
  'sc-cpu-usage-machine': "No per-node CPU metrics for this cluster in the selected time range.",
  'sc-memory-usage-machine': "No per-node memory metrics for this cluster in the selected time range.",
  'sc-storage-usage-machine': "No per-node storage metrics for this cluster in the selected time range.",
  'sc-storage-latency-node': "No per-node storage latency metrics for this cluster in the selected time range.",
  'sc-storage-iops-node': "No per-node storage IOPS metrics for this cluster in the selected time range.",
  'sc-network-throughput-node': "No per-node network throughput metrics for this cluster in the selected time range.",
  'single-cluster-volume-usage': "No volume usage data for this cluster. Confirm Azure Managed Prometheus is collecting cluster_storage_volume_* metrics.",
  'single-cluster-storage-pool-trend': "No storage pool capacity data for this cluster in the selected time range.",
  'single-cluster-cpu-trend': "No CPU trend data for this cluster in the selected time range.",
  'single-cluster-memory-trend': "No memory trend data for this cluster in the selected time range.",

  // ── Hyper-V ─────────────────────────────────────────────────────────
  'hyperv-tile-active-vms': "No active Hyper-V VMs found. Confirm AMA + a DCR with Hyper-V performance counters is configured on the nodes.",
  'hyperv-tile-hosts': "No Hyper-V hosts found in the selected workspace(s). Confirm AMA + a DCR with Hyper-V performance counters is configured on the nodes.",
  'hyperv-tile-vm-host-pairs': "No Hyper-V VM/host pairs found in the selected workspace(s). Confirm AMA + a DCR with Hyper-V performance counters is configured on the nodes.",
  'hyperv-vms-per-host': "No Hyper-V VM-per-host data. Confirm AMA + a DCR with Hyper-V performance counters is configured on the nodes.",

  // ── Arc Resource Bridge ─────────────────────────────────────────────
  'arcbridge-status': "No Arc Resource Bridge resources found in the selected scope.",
  'query - 1': "No data available for the current selection.",
  'arb-offline-table': "No offline Arc Resource Bridges — all ARBs in scope appear to be Running.",
  'arb-all-table': "No Arc Resource Bridge resources found in the selected scope.",
  'arb-alert-rules-table': "No Resource Health alert rules found for Arc Resource Bridges in the selected scope.",

  // ── Nodes ───────────────────────────────────────────────────────────
  'tile-total-machines': "No Arc-enabled machines (kind=HCI) found in the selected scope.",
  'tile-connected-machines': "No connected Arc machines (kind=HCI) found in the selected scope.",
  'tile-disconnected-machines': "No disconnected Arc machines — all nodes in scope appear to be connected.",
  'node-connection-pie': "No Arc machines (kind=HCI) match the current filters.",
  'node-vendor-pie': "No vendor data — no Arc machines (kind=HCI) match the filters.",
  'node-version-pie': "No OS version data — no Arc machines (kind=HCI) match the filters.",
  'node-agent-version-pie': "No Arc agent version data — no Arc machines (kind=HCI) match the filters.",
  'node-license-type-pie': "No license-type data — no Arc machines (kind=HCI) match the filters.",
  'all-nodes-table': "No Azure Local nodes match the current filters.",
  'disconnected-nodes-table': "No disconnected nodes — all nodes in the selected scope appear to be connected.",
  'extension-status-table': "No Arc extension status data found for the nodes in scope.",
  'extension-status-chart': "No Arc extension data found for the nodes in scope.",
  'failed-extensions-table': "No failed Arc extensions in the selected scope.",
  'nic-status-pie-chart': "No NIC status data found for the nodes in scope.",
  'nic-status-table': "No NIC inventory data found for the nodes in scope.",

  // ── VMs ─────────────────────────────────────────────────────────────
  'vm-total-tile': "No Arc-enabled VMs (Azure Local) found in the selected scope.",
  'vm-connected-tile': "No connected Arc-enabled VMs found in the selected scope.",
  'vm-status-pie': "No VM status data — no Arc-enabled VMs match the filters.",
  'vm-os-distribution': "No VM OS distribution data — no Arc-enabled VMs match the filters.",
  'vm-by-rg': "No VMs grouped by resource group — no Arc-enabled VMs match the filters.",
  'vm-deployments-bar': "No VM deployments found in the selected time range.",
  'vm-deployments-table': "No VM deployments found in the selected time range.",
  'vm-all-list': "No Arc-enabled VMs match the current filters.",
  'vm-by-cluster': "No VM-by-cluster data — no Arc-enabled VMs match the filters.",
  'vm-count-by-cluster-bar': "No VM-by-cluster data — no Arc-enabled VMs match the filters.",

  // ── AKS Arc ────────────────────────────────────────────────────────
  'aks-summary-tile': "No AKS Arc clusters found in the selected scope.",
  'aks-connectivity-chart': "No AKS Arc connectivity data — no AKS Arc clusters match the filters.",
  'aks-version-distribution': "No AKS Arc version data — no AKS Arc clusters match the filters.",
  'aks-provisioning-state': "No AKS Arc provisioning-state data — no AKS Arc clusters match the filters.",
  'aks-deployments-bar': "No AKS Arc deployments found in the selected time range.",
  'aks-deployments-table': "No AKS Arc deployments found in the selected time range.",
  'aks-all-clusters': "No AKS Arc clusters match the current filters.",
  'aks-network-details': "No AKS Arc network details available for the selected scope.",
  'aks-load-balancers': "No AKS Arc load balancers (MetalLB / SLB / Citrix) found in the selected scope.",
  'aks-upgrade-status-pie': "No AKS Arc upgrade status data available.",
  'aks-version-upgrade-summary': "No AKS Arc version upgrade information available.",
  'aks-version-upgrades-detail': "No AKS Arc version upgrade detail available.",
  'aks-extension-status-table': "No AKS Arc extension status data found for the clusters in scope.",
  'aks-extension-status-chart': "No AKS Arc extension data found for the clusters in scope.",
  'flux-compliance-chart': "No Flux configurations found on the AKS Arc clusters in scope.",
  'flux-summary-tiles': "No Flux configurations found on the AKS Arc clusters in scope.",
  'flux-all-configurations-table': "No Flux configurations found on the AKS Arc clusters in scope.",

  // ── Update Health (Update Summaries) ───────────────────────────────
  'query - 2': "No update data — clusters may not be reporting Update Summaries yet.",
  'version-distribution-chart': "No solution version data — clusters may not be reporting Update Summaries yet.",
  'top5-health-check-issues-pie': "No failed health checks reported across the fleet.",
  'query - 3': "No data for the current selection.",
  'query - 4': "No data for the current selection.",
  'query - 6': "No data for the current selection.",

  // ── Updates ────────────────────────────────────────────────────────
  'update-state-tiles': "No update runs found across the fleet for the workbook time range.",
  'update-state-pie': "No update runs found across the fleet for the workbook time range.",
  'update-attempts-by-day-chart': "No update attempts found in the selected time range.",
  'update-duration-statistics': "No completed update runs found in the selected time range.",
  'update-duration-statistics-by-solution': "No completed update runs found in the selected time range.",
  'update-success-analysis': "No update runs found in the selected time range to compute success analysis.",
  'update-outcomes-pie': "No update outcomes found in the selected time range.",
  'update-attempts-details-table': "No update attempts found in the selected time range.",
  'update-attempts-status-pie': "No update attempts found in the selected time range.",
  'update-attempts-summary-table': "No update attempts found in the selected time range.",
  'all-cluster-update-status': "No clusters report update status — clusters may not be reporting Update Summaries yet.",
  'clusters-updating': "No clusters are currently updating.",
  'clusters-updates-available': "No clusters in scope have an update available right now (or none match the filters).",
};

const FALLBACK_BY_VIZ = {
  tiles: "No data for the current selection.",
  piechart: "No data for the current selection.",
  barchart: "No data for the current selection.",
  linechart: "No data for the current selection.",
  timechart: "No data for the current selection.",
  categoricalbar: "No data for the current selection.",
  table: "No data for the current selection.",
};

function vizOf(c) {
  if (c.visualization) return c.visualization;
  if (c.gridSettings) return 'table';
  if (c.chartSettings) return 'chart';
  if (c.tileSettings) return 'tiles';
  return null;
}

let added = 0, skipped = 0;

function walk(o) {
  if (Array.isArray(o)) { o.forEach(walk); return; }
  if (!o || typeof o !== 'object') return;
  if (o.type === 3 && o.content && o.content.query !== undefined && o.content.noDataMessage === undefined) {
    const name = o.name || '';
    if (SKIP_NAMES.has(name)) {
      skipped++;
    } else {
      const viz = vizOf(o.content);
      if (!viz) {
        // No visualization metadata — treat as helper.
        skipped++;
      } else {
        const msg = MESSAGES[name] || FALLBACK_BY_VIZ[viz] || "No data for the current selection.";
        o.content.noDataMessage = msg;
        o.content.noDataMessageStyle = 4;
        added++;
      }
    }
  }
  for (const k of Object.keys(o)) walk(o[k]);
}

function processFile(file) {
  const original = fs.readFileSync(file, 'utf8');
  const doc = JSON.parse(original);
  walk(doc);
  let out = JSON.stringify(doc, null, 2);
  out = out.replace(/\r?\n/g, '\r\n');
  if (original.endsWith('\r\n') && !out.endsWith('\r\n')) out += '\r\n';
  if (out !== original) {
    fs.writeFileSync(file, out, 'utf8');
    return true;
  }
  return false;
}

const files = [SHARED_HEADER];
for (const slug of fs.readdirSync(WORKBOOKS_DIR)) {
  const f = path.join(WORKBOOKS_DIR, slug, `${slug}.workbook`);
  if (fs.existsSync(f)) files.push(f);
}

let changed = 0;
for (const f of files) {
  if (processFile(f)) changed++;
}

console.log(`Added noDataMessage to ${added} items; skipped ${skipped} helper/invisible items.`);
console.log(`Updated ${changed} of ${files.length} source files.`);
if (changed > 0) {
  console.log('Next: node scripts/build-monolithic.js');
}
