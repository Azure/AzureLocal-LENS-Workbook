// Adds `showAnalytics: true` to every visible KqlItem (type 3) in the per-tab
// workbook files under workbooks/ (and shared/header.json) that does not
// already have it. `showAnalytics` enables the "Open in query mode" toolbar
// button so users can inspect/edit the underlying KQL or ARG query in Logs /
// Resource Graph Explorer.
//
// Skips invisible Merge/helper data sources (no visualization metadata) and
// the explicit SKIP_NAMES list — same convention as add-no-data-messages.js.
//
// After running this script, run `node scripts/build-monolithic.js` to
// refresh the root JSON.
//
// Run from repo root:  node scripts/add-show-analytics.js
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const WORKBOOKS_DIR = path.join(ROOT, 'workbooks');
const SHARED_HEADER = path.join(ROOT, 'shared', 'header.json');

// Items used solely as Merge data sources / non-rendered helpers — skip.
// Mirrors add-no-data-messages.js to stay consistent.
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

// Visualization metadata keys that indicate a rendered tile.
function hasVisualization(c) {
  if (!c || typeof c !== 'object') return false;
  if (typeof c.visualization === 'string' && c.visualization.length) return true;
  // Tile size 0/1/2/3/4 with a title or chartSettings/gridSettings is rendered.
  if (c.gridSettings || c.chartSettings || c.tileSettings || c.graphSettings || c.mapSettings) return true;
  // Default workbook visualization is "table" when size is set and no merge.
  if (typeof c.size === 'number' && !c.mergeOnRender) return true;
  return false;
}

let added = 0, alreadySet = 0, skipped = 0;

function walk(o) {
  if (Array.isArray(o)) { o.forEach(walk); return; }
  if (!o || typeof o !== 'object') return;
  if (o.type === 3 && o.content && o.content.query !== undefined) {
    const name = o.name || '';
    if (SKIP_NAMES.has(name)) {
      skipped++;
    } else if (!hasVisualization(o.content)) {
      // No visualization metadata — treat as helper / merge source.
      skipped++;
    } else if (o.content.showAnalytics === true) {
      alreadySet++;
    } else {
      // Insert showAnalytics:true while preserving stable key ordering: place
      // it immediately after `size` if present, else before `title`, else at
      // the end. Re-create the object to control key order.
      const c = o.content;
      const newContent = {};
      let inserted = false;
      const keys = Object.keys(c);
      for (const k of keys) {
        if (k === 'showAnalytics') continue; // shouldn't happen (false case)
        newContent[k] = c[k];
        if (!inserted && (k === 'size' || k === 'query')) {
          // Prefer to place after `size`; if no `size`, after `query`.
          // We only insert once — choose the first match.
          // If both keys are present we want it after `size`, so wait for size.
        }
      }
      // Now build with explicit ordering: insert after `size` if present.
      const ordered = {};
      let placed = false;
      for (const k of Object.keys(newContent)) {
        ordered[k] = newContent[k];
        if (!placed && k === 'size') {
          ordered.showAnalytics = true;
          placed = true;
        }
      }
      if (!placed) {
        // No size key — insert just after `query`.
        const fallback = {};
        let p2 = false;
        for (const k of Object.keys(newContent)) {
          fallback[k] = newContent[k];
          if (!p2 && k === 'query') {
            fallback.showAnalytics = true;
            p2 = true;
          }
        }
        if (!p2) fallback.showAnalytics = true; // append at end as last resort
        o.content = fallback;
      } else {
        o.content = ordered;
      }
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

console.log(`Added showAnalytics to ${added} items; ${alreadySet} already set; skipped ${skipped} helper/invisible items.`);
console.log(`Updated ${changed} of ${files.length} source files.`);
if (changed > 0) {
  console.log('Next: node scripts/build-monolithic.js');
}
