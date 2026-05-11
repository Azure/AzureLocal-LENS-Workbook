/**
 * scripts/split.js — One-shot extractor that splits the monolithic
 * AzureLocal-LENS-Workbook.json into:
 *
 *   shared/parameters.json     Canonical global parameters (item[0] of root)
 *   shared/header.json         Title/banner/quick-actions/main-tabs items (root items 1-7)
 *   workbooks/<Slug>/<Slug>.workbook   One self-contained sub-template per tab
 *
 * Each sub-template is gallery-ready: it carries its own copy of the global
 * parameters and the main-tabs navigation so it works when opened standalone
 * in the Azure Monitor portal. When loaded inside the outer template, the
 * duplicate parameters are merged out by the workbook runtime.
 *
 * The conditionalVisibility on each tab's content group is REMOVED in the
 * sub-template (the outer template re-applies it during the monolithic build).
 *
 * After running this script, scripts/build-monolithic.js is the inverse and
 * regenerates AzureLocal-LENS-Workbook.json from the split files.
 *
 * ⚠️  DESTRUCTIVE — RE-RUN GUARD
 * The split layout is the source of truth in this repo today. Re-running
 * split.js by accident (e.g., from muscle memory after editing a split
 * source file) would overwrite every workbooks/*\/*.workbook and
 * shared/*.json from the root JSON — which may be stale if you forgot to
 * run build-monolithic.js first. To protect against that, this script
 * refuses to run unless one of the following is true:
 *
 *   1. node scripts/build-monolithic.js --check passes (root JSON is in
 *      sync with the split sources — safe to re-extract).
 *   2. --force is passed on the command line (explicit override).
 *
 * Usage: node scripts/split.js          (safe; runs only if --check passes)
 *        node scripts/split.js --force  (override; overwrites split files)
 */
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..');
const SOURCE = path.join(ROOT, 'AzureLocal-LENS-Workbook.json');
const TAB_MAP = require('./template-ids.json');

const SHARED_DIR = path.join(ROOT, 'shared');
const WORKBOOKS_DIR = path.join(ROOT, 'workbooks');

const SCHEMA = 'https://github.com/Microsoft/Application-Insights-Workbooks/blob/master/schema/workbook.json';

// Header items at root: [1]=title, [2]=banner, [3]=quick-actions header, [4]=row1 links,
// [5]=row2 links, [6]=filter instructions, [7]=main-tabs nav.
const HEADER_ITEM_NAMES = [
  'workbook-title-version',
  'version-update-banner',
  'quick-actions-header',
  'quick-actions-links',
  'quick-actions-links-row2',
  'filter-instructions',
  'main-tabs'
];

function ensureDir(dir) {
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
}

function writeJson(file, obj) {
  // Match the format of the existing root file: 2-space indent, CRLF, trailing newline.
  const out = JSON.stringify(obj, null, 2).replace(/\n/g, '\r\n') + '\r\n';
  fs.writeFileSync(file, out, 'utf8');
}

function main() {
  // Re-run guard: refuse to overwrite split sources from a potentially stale
  // root JSON unless --force is passed or --check confirms the root is in
  // sync with the existing split files.
  const force = process.argv.includes('--force');
  if (!force) {
    if (!fs.existsSync(path.join(SHARED_DIR, 'parameters.json'))) {
      // First-time run — nothing to lose, proceed.
    } else {
      try {
        execFileSync(process.execPath, [path.join(__dirname, 'build-monolithic.js'), '--check'], {
          stdio: 'pipe'
        });
      } catch (err) {
        console.error('❌ Refusing to run: AzureLocal-LENS-Workbook.json is OUT OF SYNC with the split sources.');
        console.error('   The split layout (workbooks/*\\*.workbook + shared/*.json) is the source of truth.');
        console.error('   Re-running split.js now would overwrite your split sources from a stale root file.');
        console.error('');
        console.error('   To resolve:');
        console.error('     1. If your latest edits are in the split sources:');
        console.error('          node scripts/build-monolithic.js');
        console.error('        (this regenerates the root JSON; you do NOT need to re-run split.js)');
        console.error('     2. If you genuinely want to re-extract from the root JSON, override the guard:');
        console.error('          node scripts/split.js --force');
        process.exit(1);
      }
    }
  } else {
    console.warn('⚠️  --force passed; re-run guard bypassed. Overwriting split sources from root JSON.\n');
  }

  const raw = fs.readFileSync(SOURCE, 'utf8');
  const root = JSON.parse(raw);

  if (root.version !== 'Notebook/1.0') {
    throw new Error(`Unexpected workbook version: ${root.version}`);
  }
  if (!Array.isArray(root.items) || root.items.length === 0) {
    throw new Error('Root.items missing or empty');
  }

  // --- Extract shared parameters (item[0]) ---
  const paramsItem = root.items[0];
  if (paramsItem.type !== 9 || !paramsItem.content || !Array.isArray(paramsItem.content.parameters)) {
    throw new Error(`Expected items[0] to be a type=9 parameter group, got type=${paramsItem.type}`);
  }
  ensureDir(SHARED_DIR);
  writeJson(path.join(SHARED_DIR, 'parameters.json'), paramsItem);
  console.log(`shared/parameters.json   (${paramsItem.content.parameters.length} parameters)`);

  // --- Extract header items (banners/links/main-tabs) ---
  const headerItems = HEADER_ITEM_NAMES.map(name => {
    const it = root.items.find(i => i.name === name);
    if (!it) throw new Error(`Header item not found: ${name}`);
    return it;
  });
  writeJson(path.join(SHARED_DIR, 'header.json'), { items: headerItems });
  console.log(`shared/header.json       (${headerItems.length} header items)`);

  // --- Extract tab content groups ---
  ensureDir(WORKBOOKS_DIR);
  const tabSizes = [];
  for (const tab of TAB_MAP.tabs) {
    const group = root.items.find(i => i.name === tab.groupName);
    if (!group) throw new Error(`Tab group not found: ${tab.groupName}`);
    if (group.type !== 12) throw new Error(`Expected tab group ${tab.groupName} to be type=12, got ${group.type}`);

    // Strip conditionalVisibility — the outer template re-applies it during build.
    // Use a deep clone so the source tree remains intact.
    const groupClone = JSON.parse(JSON.stringify(group));
    delete groupClone.conditionalVisibility;

    // Build the self-contained sub-template:
    //   [0] global parameters (copy)
    //   [1] main-tabs nav (copy) — so users opening the sub-template standalone
    //       still see the tab strip and can navigate to siblings.
    //   [2] tab content group (no conditionalVisibility)
    const mainTabs = root.items.find(i => i.name === 'main-tabs');
    if (!mainTabs) throw new Error('main-tabs not found in root');

    const subTemplate = {
      version: 'Notebook/1.0',
      items: [
        JSON.parse(JSON.stringify(paramsItem)),
        JSON.parse(JSON.stringify(mainTabs)),
        groupClone
      ],
      fallbackResourceIds: ['azure monitor'],
      $schema: SCHEMA
    };

    const dir = path.join(WORKBOOKS_DIR, tab.slug);
    ensureDir(dir);
    const outFile = path.join(dir, `${tab.slug}.workbook`);
    writeJson(outFile, subTemplate);
    const sz = Buffer.byteLength(fs.readFileSync(outFile, 'utf8'), 'utf8');
    tabSizes.push({ slug: tab.slug, size: sz });
    console.log(`workbooks/${tab.slug}/${tab.slug}.workbook  (${(sz / 1024).toFixed(1)} KB)`);
  }

  // --- Sanity check: every root item is accounted for ---
  const expectedRootNames = new Set([
    'global-subscription-param',
    ...HEADER_ITEM_NAMES,
    ...TAB_MAP.tabs.map(t => t.groupName)
  ]);
  const unaccounted = root.items.filter(i => !expectedRootNames.has(i.name));
  if (unaccounted.length > 0) {
    console.warn(`\n⚠️  ${unaccounted.length} root item(s) NOT mapped to split files:`);
    unaccounted.forEach(i => console.warn(`     name="${i.name}" type=${i.type}`));
    console.warn('  These will be lost on build-monolithic. Add them to template-ids.json or shared/header.json.');
    process.exitCode = 2;
  }

  console.log('\nSummary:');
  console.log(`  Total tabs: ${tabSizes.length}`);
  const max = tabSizes.reduce((a, b) => (b.size > a.size ? b : a));
  console.log(`  Largest:    ${max.slug} (${(max.size / 1024).toFixed(1)} KB)`);
  const over = tabSizes.filter(t => t.size > 200 * 1024);
  if (over.length > 0) {
    console.warn(`  ⚠️  ${over.length} tab(s) exceed 200 KB (Azure Monitor recommended max):`);
    over.forEach(t => console.warn(`     ${t.slug}: ${(t.size / 1024).toFixed(1)} KB`));
  } else {
    console.log('  ✅ All tabs under 200 KB.');
  }

  // --- Chain: extract Capacity-* sub-sections from the freshly-emitted
  // workbooks/Capacity/Capacity.workbook so the split layout matches what
  // build-monolithic.js expects (trimmed orchestrator + 5 Capacity-* files).
  // Without this, split.js alone produces an un-trimmed orchestrator and a
  // subsequent build-monolithic --check would fail.
  console.log('\nExtracting Capacity sub-sections…');
  execFileSync(process.execPath, [path.join(__dirname, 'split-capacity.js')], { stdio: 'inherit' });
}

main();
