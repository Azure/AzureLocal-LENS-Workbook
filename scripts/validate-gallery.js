/**
 * Validates dist/gallery as an upstream Azure Monitor Workbooks package.
 * Run scripts/build-gallery.js first.
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const DIST = path.join(ROOT, 'dist', 'gallery');
const TAB_MAP = require('./template-ids.json');
const UPSTREAM_CATEGORY = 'Azure Local';
const COMMUNITY_PREFIX = `community-Workbooks/${UPSTREAM_CATEGORY}/`;
const ARRAY_LOC_IDENTIFIER = {
  items: 'name',
  parameters: 'id',
  labelSettings: 'columnId',
  links: 'id'
};
const LOC_KEYS = new Set([
  'json', 'description', 'label', 'linkLabel', 'preText', 'postText',
  'title', 'chartTitle', 'defaultItemsText', 'loadButtonText',
  'noDataMessage', 'markDown'
]);
const RESOURCE_ID_REGEX = /\/subscriptions\/[a-z0-9]{8}-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{12}/gi;

const entries = TAB_MAP.tabs.flatMap(tab => [tab, ...(tab.subSections || [])]);
const expectedFolders = entries.map(entry => entry.galleryFolderName).sort();
const expectedLoadedIds = entries
  .filter(entry => entry.slug !== 'Overview')
  .map(entry => `${COMMUNITY_PREFIX}${entry.galleryFolderName}`)
  .sort();
const failures = [];
const warnings = [];

function fail(message) {
  failures.push(message);
}

function arraysEqual(left, right) {
  return left.length === right.length && left.every((value, index) => value === right[index]);
}

function removeNonAlphaNumeric(value) {
  return String(value).replace(/[\W_]/g, '');
}

function arrayIdentifier(key) {
  return Object.keys(ARRAY_LOC_IDENTIFIER).find(identifier => key.endsWith(identifier));
}

function validateLocalizationKeys(obj, file) {
  const outputMap = {};

  function visit(value, key) {
    if (!value || typeof value !== 'object') return;
    for (const field in value) {
      const child = value[field];
      if (child && typeof child === 'object') {
        let childKey;
        if (!Number.isNaN(Number.parseInt(field, 10))) {
          const identifier = arrayIdentifier(key);
          const idField = identifier && ARRAY_LOC_IDENTIFIER[identifier];
          childKey = idField && child[idField] != null
            ? `${key}.${removeNonAlphaNumeric(child[idField])}`
            : `${key}.${field}`;
        } else {
          childKey = `${key}.${field}`;
        }
        visit(child, childKey);
      } else if (LOC_KEYS.has(field) && child) {
        const localizationKey = `${key}.${field}`.substring(1);
        if (Object.prototype.hasOwnProperty.call(outputMap, localizationKey)) {
          fail(`${file}: duplicate localization key ${localizationKey}`);
        } else {
          outputMap[localizationKey] = child;
        }
      }
    }
  }

  visit(obj, '');
}

function collectLoadedTemplateIds(value, output) {
  if (Array.isArray(value)) {
    value.forEach(item => collectLoadedTemplateIds(item, output));
    return;
  }
  if (!value || typeof value !== 'object') return;
  for (const [key, child] of Object.entries(value)) {
    if (key === 'loadFromTemplateId' && typeof child === 'string') output.push(child);
    collectLoadedTemplateIds(child, output);
  }
}

if (!fs.existsSync(DIST)) {
  fail('dist/gallery does not exist; run node scripts/build-gallery.js first');
} else {
  if (new Set(expectedFolders).size !== expectedFolders.length) {
    fail('scripts/template-ids.json contains duplicate galleryFolderName values');
  }

  const actualFolders = fs.readdirSync(DIST, { withFileTypes: true })
    .filter(entry => entry.isDirectory())
    .map(entry => entry.name)
    .sort();
  if (!arraysEqual(actualFolders, expectedFolders)) {
    fail(`gallery folders differ from manifest (expected ${expectedFolders.join(', ')}; found ${actualFolders.join(', ')})`);
  }

  const loadedTemplateIds = [];
  for (const folder of expectedFolders) {
    const dir = path.join(DIST, folder);
    const expectedFileName = `${folder}.workbook`;
    const file = path.join(dir, expectedFileName);
    if (!fs.existsSync(file)) {
      fail(`${folder}: missing ${expectedFileName}`);
      continue;
    }

    const workbookFiles = fs.readdirSync(dir).filter(name => name.endsWith('.workbook'));
    if (workbookFiles.length !== 1 || workbookFiles[0] !== expectedFileName) {
      fail(`${folder}: expected only ${expectedFileName}, found ${workbookFiles.join(', ') || 'none'}`);
    }

    let workbook;
    try {
      workbook = JSON.parse(fs.readFileSync(file, 'utf8'));
    } catch (error) {
      fail(`${folder}: invalid JSON (${error.message})`);
      continue;
    }

    if (workbook.version !== 'Notebook/1.0') {
      fail(`${folder}: version must be Notebook/1.0`);
    }
    if (workbook.fromTemplateId) {
      fail(`${folder}: prohibited top-level fromTemplateId`);
    }

    const serialized = JSON.stringify(workbook);
    const resourceIds = serialized.match(RESOURCE_ID_REGEX) || [];
    resourceIds.forEach(resourceId => fail(`${folder}: hardcoded resource ID ${resourceId}`));
    validateLocalizationKeys(workbook, folder);
    collectLoadedTemplateIds(workbook, loadedTemplateIds);

    const upstreamPath = `./Workbooks/${UPSTREAM_CATEGORY}/${folder}/${expectedFileName}`;
    const packagedKey = `${UPSTREAM_CATEGORY}-${folder}.json`;
    if (upstreamPath.length > 200) fail(`${folder}: upstream path exceeds 200 characters`);
    if (packagedKey.length > 100) fail(`${folder}: packaged key exceeds 100 characters`);

    const formattedLength = JSON.stringify(workbook, null, 2).length;
    if (formattedLength > 500000) {
      fail(`${folder}: formatted JSON exceeds upstream 500,000-character error threshold`);
    } else if (formattedLength > 100000) {
      warnings.push(`${folder}: formatted JSON is ${formattedLength.toLocaleString()} characters (upstream size warning)`);
    }
  }

  loadedTemplateIds.sort();
  if (!arraysEqual(loadedTemplateIds, expectedLoadedIds)) {
    fail(`loadFromTemplateId values differ from manifest (expected ${expectedLoadedIds.join(', ')}; found ${loadedTemplateIds.join(', ')})`);
  }
}

warnings.forEach(warning => console.warn(`WARNING: ${warning}`));
if (failures.length > 0) {
  failures.forEach(failure => console.error(`ERROR: ${failure}`));
  console.error(`Gallery validation failed with ${failures.length} error(s).`);
  process.exit(1);
}

console.log(`Gallery validation passed: ${expectedFolders.length} templates, ${expectedLoadedIds.length} runtime references.`);