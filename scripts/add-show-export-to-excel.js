// Adds `showExportToExcel: true` to every visible KqlItem (type 3) that
// renders as a grid/table in the per-tab workbook files under workbooks/
// (and shared/header.json) and does not already have it. The Workbooks
// toolbar's "Export" button (when this flag is true) provides the
// Excel/CSV download menu users expect.
//
// "Grid/table" detection rules (must match ALL):
//   - type === 3 (KqlItem)
//   - has a query string
//   - either visualization === "table" / "grid", OR no visualization key
//     and `size` is a number (default render = table). Charts (timechart,
//     linechart, barchart, piechart, areachart, scatterchart, map, tiles,
//     graph) are excluded so we don't add an Excel button to a line chart.
//
// Skips invisible Merge/helper data sources (no visualization metadata)
// and the explicit SKIP_NAMES list — same convention as
// add-no-data-messages.js / add-show-analytics.js.
//
// After running this script, run `node scripts/build-monolithic.js` to
// refresh the root JSON.
//
// Run from repo root:  node scripts/add-show-export-to-excel.js
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const WORKBOOKS_DIR = path.join(ROOT, 'workbooks');
const SHARED_HEADER = path.join(ROOT, 'shared', 'header.json');

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

const CHART_VIZ = new Set([
  'timechart', 'linechart', 'barchart', 'piechart', 'areachart',
  'scatterchart', 'map', 'tiles', 'graph', 'categoricalbar', 'unstackedbar',
  'sparklines'
]);

function isGridLike(c) {
  if (!c || typeof c !== 'object') return false;
  if (typeof c.visualization === 'string' && c.visualization.length) {
    const v = c.visualization.toLowerCase();
    if (v === 'table' || v === 'grid') return true;
    if (CHART_VIZ.has(v)) return false;
    // Unknown viz — don't assume grid.
    return false;
  }
  // No visualization key → workbooks default render is grid/table.
  if (typeof c.size === 'number') return true;
  return false;
}

let added = 0, alreadySet = 0, skippedHelper = 0, skippedChart = 0;

function walk(o) {
  if (Array.isArray(o)) { o.forEach(walk); return; }
  if (!o || typeof o !== 'object') return;
  if (o.type === 3 && o.content && o.content.query !== undefined) {
    const name = o.name || '';
    if (SKIP_NAMES.has(name)) {
      skippedHelper++;
    } else if (!isGridLike(o.content)) {
      // Either no viz metadata at all (helper) or a chart visualization.
      // Treat anything not grid-like as not eligible.
      if (!o.content.visualization && typeof o.content.size !== 'number') {
        skippedHelper++;
      } else {
        skippedChart++;
      }
    } else if (o.content.showExportToExcel === true) {
      alreadySet++;
    } else {
      // Insert showExportToExcel:true right after showRefreshButton if
      // present (mirrors existing convention), else after showAnalytics,
      // else after `title`, else after `size`.
      const c = o.content;
      const ordered = {};
      let placed = false;
      const anchorPriority = ['showRefreshButton', 'showAnalytics', 'title', 'size'];
      // Find the latest-occurring anchor in priority order so the new key
      // sits in a stable, conventional spot.
      const keys = Object.keys(c);
      let chosenAnchor = null;
      for (const a of anchorPriority) {
        if (keys.includes(a)) { chosenAnchor = a; break; }
      }
      if (chosenAnchor === null) {
        // Append at end.
        for (const k of keys) ordered[k] = c[k];
        ordered.showExportToExcel = true;
      } else {
        for (const k of keys) {
          ordered[k] = c[k];
          if (!placed && k === chosenAnchor) {
            ordered.showExportToExcel = true;
            placed = true;
          }
        }
      }
      o.content = ordered;
      added++;
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

console.log(`Added showExportToExcel to ${added} grid/table tiles; ${alreadySet} already set; skipped ${skippedHelper} helper and ${skippedChart} non-grid (chart) tiles.`);
console.log(`Updated ${changed} of ${files.length} source files.`);
if (changed > 0) {
  console.log('Next: node scripts/build-monolithic.js');
}
