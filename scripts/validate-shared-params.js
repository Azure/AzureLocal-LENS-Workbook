/**
 * scripts/validate-shared-params.js — Asserts every per-tab sub-template has
 * an items[0] parameter group that is byte-identical to shared/parameters.json.
 *
 * If parameter names/types/IDs drift between sub-templates and the shared
 * canonical block, the workbook runtime will NOT merge them out and users
 * will see duplicate dropdowns when navigating between gallery sub-templates.
 *
 * Exits non-zero on any mismatch (suitable for CI).
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const SHARED = path.join(ROOT, 'shared', 'parameters.json');
const WORKBOOKS_DIR = path.join(ROOT, 'workbooks');
const TAB_MAP = require('./template-ids.json');

const canonical = JSON.parse(fs.readFileSync(SHARED, 'utf8'));
const canonicalJson = JSON.stringify(canonical);

let failed = 0;
for (const tab of TAB_MAP.tabs) {
  const file = path.join(WORKBOOKS_DIR, tab.slug, `${tab.slug}.workbook`);
  if (!fs.existsSync(file)) {
    console.error(`❌ ${tab.slug}: sub-template missing (${file})`);
    failed++;
    continue;
  }
  const sub = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (!Array.isArray(sub.items) || sub.items.length === 0) {
    console.error(`❌ ${tab.slug}: empty items array`);
    failed++;
    continue;
  }
  const first = sub.items[0];
  if (first.type !== 9) {
    console.error(`❌ ${tab.slug}: items[0] is type=${first.type}, expected 9 (parameter group)`);
    failed++;
    continue;
  }
  if (JSON.stringify(first) !== canonicalJson) {
    console.error(`❌ ${tab.slug}: items[0] differs from shared/parameters.json`);
    // Emit a useful hint about what differs.
    const subNames = (first.content && first.content.parameters || []).map(p => p.name).sort();
    const canonNames = canonical.content.parameters.map(p => p.name).sort();
    const missingInSub = canonNames.filter(n => !subNames.includes(n));
    const extraInSub = subNames.filter(n => !canonNames.includes(n));
    if (missingInSub.length) console.error(`    missing parameters: ${missingInSub.join(', ')}`);
    if (extraInSub.length)  console.error(`    extra parameters:   ${extraInSub.join(', ')}`);
    if (!missingInSub.length && !extraInSub.length) {
      console.error('    (parameter names match — content of one or more parameters drifted)');
    }
    failed++;
    continue;
  }
  console.log(`✅ ${tab.slug}`);
}

if (failed > 0) {
  console.error(`\n❌ ${failed} sub-template(s) have parameter drift.`);
  console.error('   Run: node scripts/sync-shared-params.js   (or edit shared/parameters.json then re-run)');
  process.exit(1);
}
console.log(`\n✅ All ${TAB_MAP.tabs.length} sub-templates have canonical parameters.`);
