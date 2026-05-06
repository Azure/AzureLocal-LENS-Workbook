/**
 * scripts/build-monolithic.js — Inverse of split.js. Assembles
 * the per-tab .workbook files plus shared/parameters.json and
 * shared/header.json into the single AzureLocal-LENS-Workbook.json
 * at the repo root (the artifact users copy/paste today).
 *
 * The assembled file matches the historical structure: 16 top-level items
 * (1 params group, 7 header items, 8 tab groups with conditionalVisibility).
 *
 * Run after editing any split file:
 *   node scripts/build-monolithic.js
 *
 * Use --check to exit non-zero if the on-disk root file would change
 * (intended for CI to enforce that the root is regenerated on every PR).
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const TARGET = path.join(ROOT, 'AzureLocal-LENS-Workbook.json');
const SHARED_DIR = path.join(ROOT, 'shared');
const WORKBOOKS_DIR = path.join(ROOT, 'workbooks');
const TAB_MAP = require('./template-ids.json');

const SCHEMA = 'https://github.com/Microsoft/Application-Insights-Workbooks/blob/master/schema/workbook.json';

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function buildMonolithic() {
  const params = readJson(path.join(SHARED_DIR, 'parameters.json'));
  const header = readJson(path.join(SHARED_DIR, 'header.json'));

  const items = [params, ...header.items];

  for (const tab of TAB_MAP.tabs) {
    const subFile = path.join(WORKBOOKS_DIR, tab.slug, `${tab.slug}.workbook`);
    if (!fs.existsSync(subFile)) {
      throw new Error(`Sub-template missing: ${subFile}`);
    }
    const sub = readJson(subFile);

    // Sub-template layout (set by split.js):
    //   items[0] = parameters (drop, replaced by canonical shared one)
    //   items[1] = main-tabs nav (drop, already in header)
    //   items[2] = tab content group (use this)
    if (!Array.isArray(sub.items) || sub.items.length < 3) {
      throw new Error(`Sub-template ${tab.slug} has fewer than 3 items`);
    }
    const contentGroup = JSON.parse(JSON.stringify(sub.items[2]));

    if (contentGroup.name !== tab.groupName) {
      throw new Error(
        `Sub-template ${tab.slug} content group name mismatch: ` +
        `expected "${tab.groupName}", got "${contentGroup.name}"`
      );
    }

    // If this tab has subSections (currently only Capacity), each sub-section
    // lives in its own sub-template file. Merge their content groups back into
    // this tab's content group so the monolithic file matches v0.8.9 layout.
    if (Array.isArray(tab.subSections)) {
      for (const sect of tab.subSections) {
        const sectFile = path.join(WORKBOOKS_DIR, sect.slug, `${sect.slug}.workbook`);
        if (!fs.existsSync(sectFile)) {
          throw new Error(`Sub-section template missing: ${sectFile}`);
        }
        const sectSub = readJson(sectFile);
        // Sub-section layout (set by split-capacity.js):
        //   items[0] = canonical shared parameters (drop)
        //   items[1] = section-driver param (cap-shared-params; drop, already in orchestrator)
        //   items[2] = the section group (use this)
        if (!Array.isArray(sectSub.items) || sectSub.items.length < 3) {
          throw new Error(`Sub-section ${sect.slug} has fewer than 3 items`);
        }
        const sectGroup = JSON.parse(JSON.stringify(sectSub.items[2]));
        if (sectGroup.name !== sect.groupName) {
          throw new Error(
            `Sub-section ${sect.slug} group name mismatch: ` +
            `expected "${sect.groupName}", got "${sectGroup.name}"`
          );
        }
        contentGroup.content.items.push(sectGroup);
      }
    }

    // Preserve the historical key order: type, content, conditionalVisibility, name, [styleSettings].
    // Rebuilding the object explicitly is the only way to control JSON.stringify output order.
    const orderedGroup = {
      type: contentGroup.type,
      content: contentGroup.content,
      conditionalVisibility: {
        parameterName: 'selectedTab',
        comparison: 'isEqualTo',
        value: tab.selectedTab
      },
      name: contentGroup.name
    };
    // Carry forward any other keys the historical structure may have (e.g. styleSettings, customWidth)
    // without dictating their order — they appear after name as in the original file.
    for (const k of Object.keys(contentGroup)) {
      if (!(k in orderedGroup)) orderedGroup[k] = contentGroup[k];
    }

    items.push(orderedGroup);
  }

  return {
    version: 'Notebook/1.0',
    items,
    fallbackResourceIds: ['azure monitor'],
    $schema: SCHEMA
  };
}

function serialize(obj) {
  return JSON.stringify(obj, null, 2).replace(/\n/g, '\r\n') + '\r\n';
}

function main() {
  const checkOnly = process.argv.includes('--check');
  const built = buildMonolithic();
  const newText = serialize(built);

  if (checkOnly) {
    if (!fs.existsSync(TARGET)) {
      console.error('❌ Root workbook does not exist. Run without --check to generate it.');
      process.exit(1);
    }
    const current = fs.readFileSync(TARGET, 'utf8');
    if (current === newText) {
      console.log('✅ Root workbook is up to date with split sources.');
      process.exit(0);
    }
    console.error('❌ Root workbook is out of sync with split sources.');
    console.error('   Run: node scripts/build-monolithic.js');
    // Show a small hint about where it differs.
    let diffAt = -1;
    const max = Math.min(current.length, newText.length);
    for (let i = 0; i < max; i++) {
      if (current[i] !== newText[i]) { diffAt = i; break; }
    }
    if (diffAt >= 0) {
      console.error(`   First diff at byte ${diffAt}:`);
      console.error(`     current: ${JSON.stringify(current.slice(Math.max(0, diffAt - 30), diffAt + 40))}`);
      console.error(`     built:   ${JSON.stringify(newText.slice(Math.max(0, diffAt - 30), diffAt + 40))}`);
    } else {
      console.error(`   Length differs: current=${current.length}, built=${newText.length}`);
    }
    process.exit(1);
  }

  fs.writeFileSync(TARGET, newText, 'utf8');
  const sizeKB = (Buffer.byteLength(newText, 'utf8') / 1024).toFixed(1);
  console.log(`✅ Built ${path.relative(ROOT, TARGET)} (${sizeKB} KB, ${built.items.length} top-level items)`);
}

main();
