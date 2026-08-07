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
 *   - Monolithic: roughly 1 MB (everything loads up front)
 *   - Gallery outer: a small parameter/stub shell; each tab loads
 *     its content on first click.
 *
 * Output: dist/gallery/LENS-Overview/LENS-Overview.workbook  (the outer)
 *         dist/gallery/<Tab>/<Tab>.workbook                  (sub-templates)
 *
 * Community template IDs are derived from the final upstream folder paths:
 * community-Workbooks/Azure Local/<galleryFolderName>.
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

function galleryTemplateId(entry) {
  return `community-Workbooks/Azure Local/${entry.galleryFolderName}`;
}

function buildCapacityOuter(capacityTab) {
  // Capacity for the gallery: include the orchestrator base items
  // (cap-shared-params, cap-instructions-text, cap-section-tabs) and add a
  // sub-template stub for each section (Capacity-Overview/MultiCluster/SingleCluster/HyperV).
  const sub = readJson(path.join(WORKBOOKS_DIR, 'Capacity', 'Capacity.workbook'));
  const orch = JSON.parse(JSON.stringify(sub));
  const capGroup = orch.items[2];
  const baseItems = capGroup.content.items.slice();

  const stubs = [];
  for (const sect of capacityTab.subSections) {
    stubs.push({
      type: 12,
      content: {
        version: 'NotebookGroup/1.0',
        groupType: 'template',
        loadFromTemplateId: galleryTemplateId(sect),
        items: []
      },
      conditionalVisibility: {
        parameterName: 'CapacitySection',
        comparison: 'isEqualTo',
        value: sect.value
      },
      name: `${sect.slug.toLowerCase()}-template-group`
    });
  }

  capGroup.content.items = [...baseItems, ...stubs];
  return orch;
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
  for (const tab of TAB_MAP.tabs) {
    if (tab.slug === 'Overview') continue;
    items.push({
      type: 12,
      content: {
        version: 'NotebookGroup/1.0',
        groupType: 'template',
        loadFromTemplateId: galleryTemplateId(tab),
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
    version: 'Notebook/1.0',
    items,
    fallbackResourceIds: ['azure monitor'],
    $schema: SCHEMA
  };
}

function main() {
  fs.rmSync(DIST, { recursive: true, force: true });
  ensureDir(DIST);

  // Outer (inline Overview + 7 sub-template stubs) — emitted under the Overview
  // tab's gallery folder name (e.g. dist/gallery/LENS-Overview/LENS-Overview.workbook).
  const overviewTab = TAB_MAP.tabs.find(t => t.slug === 'Overview');
  const overviewFolder = (overviewTab && overviewTab.galleryFolderName) || 'Overview';
  const outer = buildOuter();
  const outerFile = path.join(DIST, overviewFolder, `${overviewFolder}.workbook`);
  writeJson(outerFile, outer);
  const outerKB = (fs.statSync(outerFile).size / 1024).toFixed(1);
  console.log(`✅ ${path.relative(ROOT, outerFile)} (${outerKB} KB outer with inline Overview tab)`);

  // Sub-templates (one per non-Overview tab)
  for (const tab of TAB_MAP.tabs) {
    if (tab.slug === 'Overview') continue;
    const tabFolder = tab.galleryFolderName || tab.slug;

    if (Array.isArray(tab.subSections)) {
      // Capacity gallery file = orchestrator + sub-section stubs
      const capOuter = buildCapacityOuter(tab);
      const dst = path.join(DIST, tabFolder, `${tabFolder}.workbook`);
      writeJson(dst, capOuter);
      const kb = (fs.statSync(dst).size / 1024).toFixed(1);
      console.log(`✅ ${path.relative(ROOT, dst)} (${kb} KB outer with ${tab.subSections.length} section stubs)`);

      // Emit each Capacity-* sub-section template
      for (const sect of tab.subSections) {
        const sectFolder = sect.galleryFolderName || sect.slug;
        const src = path.join(WORKBOOKS_DIR, sect.slug, `${sect.slug}.workbook`);
        const subDst = path.join(DIST, sectFolder, `${sectFolder}.workbook`);
        if (!fs.existsSync(src)) {
          console.error(`❌ Missing source: ${src}`);
          process.exit(1);
        }
        ensureDir(path.dirname(subDst));
        fs.copyFileSync(src, subDst);
        const subKB = (fs.statSync(subDst).size / 1024).toFixed(1);
        console.log(`✅ ${path.relative(ROOT, subDst)} (${subKB} KB sub-section)`);
      }
      continue;
    }

    const src = path.join(WORKBOOKS_DIR, tab.slug, `${tab.slug}.workbook`);
    const dst = path.join(DIST, tabFolder, `${tabFolder}.workbook`);
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
}

main();
