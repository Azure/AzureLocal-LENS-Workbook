/**
 * scripts/build-gallery.js — Generates the Azure Monitor gallery submission
 * artifacts: an outer workbook that loads each tab as a sub-template via
 * groupType="template" + loadFromTemplateId, plus the per-tab sub-templates
 * already living under workbooks/.
 *
 * This is the "outer + lazy-loaded sub-templates" form recommended for
 * gallery contributions (per microsoft/Application-Insights-Workbooks
 * CONTRIBUTING.md). It produces a much smaller initial-load payload than
 * the monolithic AzureLocal-LENS-Workbook.json:
 *   - Monolithic: ~862 KB (everything loads up front)
 *   - Gallery outer: ~30 KB (params + 7 sub-template stubs); each tab loads
 *     its content on first click.
 *
 * Output: dist/gallery/Overview/Overview.workbook  (the outer)
 *         dist/gallery/<Tab>/<Tab>.workbook        (one per sub-template)
 *
 * Until the upstream gallery review approves the template IDs, set the
 * "galleryTemplateId" fields in scripts/template-ids.json. While they
 * remain empty this script emits the outer with placeholder loadFromTemplateId
 * values that will not resolve at runtime — useful for review of the shape
 * but not deployable.
 *
 * Usage: node scripts/build-gallery.js
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const SHARED_DIR = path.join(ROOT, 'shared');
const WORKBOOKS_DIR = path.join(ROOT, 'workbooks');
const DIST = path.join(ROOT, 'dist', 'gallery');
const TAB_MAP = require('./template-ids.json');

const SCHEMA = 'https://github.com/Microsoft/Application-Insights-Workbooks/blob/master/schema/workbook.json';

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function ensureDir(d) {
  fs.mkdirSync(d, { recursive: true });
}

function writeJson(file, obj) {
  ensureDir(path.dirname(file));
  const out = JSON.stringify(obj, null, 2).replace(/\n/g, '\r\n') + '\r\n';
  fs.writeFileSync(file, out, 'utf8');
}

function buildOuter() {
  const params = readJson(path.join(SHARED_DIR, 'parameters.json'));
  const header = readJson(path.join(SHARED_DIR, 'header.json'));

  // Inline the Overview tab content into the outer (the first/landing tab),
  // matching the Storage Insights Overview.workbook pattern. Other tabs are
  // sub-template stubs.
  const overviewTab = TAB_MAP.tabs.find(t => t.slug === 'Overview');
  if (!overviewTab) throw new Error('Overview tab not in template-ids.json');
  const overviewSub = readJson(path.join(WORKBOOKS_DIR, 'Overview', 'Overview.workbook'));
  const overviewContent = JSON.parse(JSON.stringify(overviewSub.items[2]));
  const overviewOrdered = {
    type: overviewContent.type,
    content: overviewContent.content,
    conditionalVisibility: {
      parameterName: 'selectedTab',
      comparison: 'isEqualTo',
      value: overviewTab.selectedTab
    },
    name: overviewContent.name
  };
  for (const k of Object.keys(overviewContent)) {
    if (!(k in overviewOrdered)) overviewOrdered[k] = overviewContent[k];
  }

  const items = [params, ...header.items, overviewOrdered];

  // Stub group for each non-Overview tab.
  let placeholderCount = 0;
  for (const tab of TAB_MAP.tabs) {
    if (tab.slug === 'Overview') continue;
    const templateId = tab.galleryTemplateId
      || `Community-Workbooks/Azure Local/${tab.slug}`;
    if (!tab.galleryTemplateId) placeholderCount++;
    items.push({
      type: 12,
      content: {
        version: 'NotebookGroup/1.0',
        groupType: 'template',
        loadFromTemplateId: templateId,
        items: []
      },
      conditionalVisibility: {
        parameterName: 'selectedTab',
        comparison: 'isEqualTo',
        value: tab.selectedTab
      },
      name: `${tab.slug.toLowerCase()}-template-group`
    });
  }

  return {
    workbook: {
      version: 'Notebook/1.0',
      items,
      fallbackResourceIds: ['azure monitor'],
      $schema: SCHEMA
    },
    placeholderCount
  };
}

function main() {
  // Outer (inline Overview + 7 sub-template stubs)
  const { workbook: outer, placeholderCount } = buildOuter();
  const outerFile = path.join(DIST, 'Overview', 'Overview.workbook');
  writeJson(outerFile, outer);
  const outerKB = (fs.statSync(outerFile).size / 1024).toFixed(1);
  console.log(`✅ ${path.relative(ROOT, outerFile)} (${outerKB} KB outer with inline Overview tab)`);

  // Sub-templates (one per non-Overview tab, copied from workbooks/)
  for (const tab of TAB_MAP.tabs) {
    if (tab.slug === 'Overview') continue;
    const src = path.join(WORKBOOKS_DIR, tab.slug, `${tab.slug}.workbook`);
    const dst = path.join(DIST, tab.slug, `${tab.slug}.workbook`);
    if (!fs.existsSync(src)) {
      console.error(`❌ Missing source: ${src}`);
      process.exit(1);
    }
    ensureDir(path.dirname(dst));
    fs.copyFileSync(src, dst);
    const kb = (fs.statSync(dst).size / 1024).toFixed(1);
    console.log(`✅ ${path.relative(ROOT, dst)} (${kb} KB sub-template)`);
  }

  console.log(`\nGallery artifacts written to ${path.relative(ROOT, DIST)}/`);

  if (placeholderCount > 0) {
    console.log(`\n⚠️  ${placeholderCount} sub-template(s) use placeholder galleryTemplateId.`);
    console.log('   Once the Azure Monitor team approves the upstream PR and assigns');
    console.log('   real template IDs, populate them in scripts/template-ids.json and re-run.');
  }
}

main();
