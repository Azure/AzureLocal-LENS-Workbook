/**
 * scripts/sync-shared-params.js — Rewrites items[0] in every per-tab
 * sub-template with the canonical block from shared/parameters.json.
 * Run this after editing shared/parameters.json.
 *
 * After running, also run: node scripts/build-monolithic.js
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const SHARED = path.join(ROOT, 'shared', 'parameters.json');
const WORKBOOKS_DIR = path.join(ROOT, 'workbooks');
const TAB_MAP = require('./template-ids.json');

const canonical = JSON.parse(fs.readFileSync(SHARED, 'utf8'));

for (const tab of TAB_MAP.tabs) {
  const file = path.join(WORKBOOKS_DIR, tab.slug, `${tab.slug}.workbook`);
  const sub = JSON.parse(fs.readFileSync(file, 'utf8'));
  sub.items[0] = JSON.parse(JSON.stringify(canonical));
  const out = JSON.stringify(sub, null, 2).replace(/\n/g, '\r\n') + '\r\n';
  fs.writeFileSync(file, out, 'utf8');
  console.log(`synced: ${path.relative(ROOT, file)}`);
}
console.log(`\n✅ Synced ${TAB_MAP.tabs.length} sub-template(s).`);
console.log('   Next: node scripts/build-monolithic.js');
