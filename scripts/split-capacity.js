/**
 * scripts/split-capacity.js — One-shot extractor that splits the Capacity
 * sub-template (workbooks/Capacity/Capacity.workbook, currently ~317 KB) into
 * four section sub-templates so each one fits comfortably under the 200 KB
 * gallery recommendation:
 *
 *   workbooks/Capacity-Overview/Capacity-Overview.workbook
 *   workbooks/Capacity-MultiNode/Capacity-MultiNode.workbook
 *   workbooks/Capacity-SingleNode/Capacity-SingleNode.workbook
 *   workbooks/Capacity-HyperV/Capacity-HyperV.workbook
 *
 * The Capacity orchestrator (workbooks/Capacity/Capacity.workbook) is rewritten
 * to contain only its base items (shared params driver, instructions text,
 * section-tab nav). Section content groups are merged back in at build time
 * by scripts/build-monolithic.js.
 *
 * Each Capacity-* sub-template layout:
 *   items[0] = canonical shared parameters (from shared/parameters.json)
 *   items[1] = cap-shared-params (CapacitySection driver — equivalent to
 *              the main-tabs nav for the section level)
 *   items[2] = the cap-*-section group, conditionalVisibility intact
 *
 * Idempotent: detects orchestrator-already-trimmed and short-circuits.
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const WORKBOOKS_DIR = path.join(ROOT, 'workbooks');
const SHARED_DIR = path.join(ROOT, 'shared');
const SCHEMA = 'https://github.com/Microsoft/Application-Insights-Workbooks/blob/master/schema/workbook.json';

const SECTIONS = [
  { slug: 'Capacity-Overview',   groupName: 'cap-overview-section', value: 'overview' },
  { slug: 'Capacity-MultiNode',  groupName: 'cap-multi-section',    value: 'multi'    },
  { slug: 'Capacity-SingleNode', groupName: 'cap-single-section',   value: 'single'   },
  { slug: 'Capacity-HyperV',     groupName: 'cap-hyperv-section',   value: 'hyperv'   }
];

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function serialize(obj) {
  return JSON.stringify(obj, null, 2).replace(/\n/g, '\r\n') + '\r\n';
}

function writeWorkbook(file, obj) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, serialize(obj), 'utf8');
}

function main() {
  const sharedParams = readJson(path.join(SHARED_DIR, 'parameters.json'));
  const capacityFile = path.join(WORKBOOKS_DIR, 'Capacity', 'Capacity.workbook');
  const capacity = readJson(capacityFile);

  const capGroup = capacity.items[2];
  const capItems = capGroup.content.items;

  const capSharedParams = capItems.find(i => i.name === 'cap-shared-params');
  const capInstructions = capItems.find(i => i.name === 'cap-instructions-text');
  const capSectionTabs  = capItems.find(i => i.name === 'cap-section-tabs');

  if (!capSharedParams || !capInstructions || !capSectionTabs) {
    throw new Error('Capacity orchestrator base items missing');
  }

  for (const section of SECTIONS) {
    const sectionGroup = capItems.find(i => i.name === section.groupName);
    if (!sectionGroup) {
      console.log(`  ⚠ ${section.groupName} not in orchestrator — assuming already extracted`);
      continue;
    }
    if (!sectionGroup.conditionalVisibility ||
        sectionGroup.conditionalVisibility.parameterName !== 'CapacitySection' ||
        sectionGroup.conditionalVisibility.value !== section.value) {
      throw new Error(`${section.groupName}: missing or wrong conditionalVisibility`);
    }

    // Sub-template: canonical shared params, cap-shared-params (CapacitySection driver), section group
    const sub = {
      version: 'Notebook/1.0',
      items: [
        sharedParams,
        capSharedParams,
        sectionGroup
      ],
      fallbackResourceIds: ['azure monitor'],
      $schema: SCHEMA
    };
    const subFile = path.join(WORKBOOKS_DIR, section.slug, `${section.slug}.workbook`);
    writeWorkbook(subFile, sub);
    const sizeKB = (fs.statSync(subFile).size / 1024).toFixed(1);
    console.log(`  ✅ ${section.slug} (${sizeKB} KB)`);
  }

  // Trim orchestrator to base items only
  capGroup.content.items = [capSharedParams, capInstructions, capSectionTabs];
  writeWorkbook(capacityFile, capacity);
  const orchKB = (fs.statSync(capacityFile).size / 1024).toFixed(1);
  console.log(`  ✅ Capacity orchestrator trimmed to base items (${orchKB} KB)`);
}

main();
