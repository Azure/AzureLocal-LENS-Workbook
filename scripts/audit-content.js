/**
 * Inventory customer-facing workbook copy and flag length outliers for review.
 *
 * This script is intentionally read-only. Length thresholds are triage signals,
 * not automatic editorial failures.
 *
 * Usage:
 *   node scripts/audit-content.js
 *   node scripts/audit-content.js --json
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const WORKBOOKS_DIR = path.join(ROOT, 'workbooks');
const SHARED_FILES = [
  path.join(ROOT, 'shared', 'header.json'),
  path.join(ROOT, 'shared', 'parameters.json')
];

const TEXT_FIELDS = new Set([
  'title',
  'label',
  'description',
  'noDataMessage',
  'linkLabel',
  'placeholder',
  'ariaLabel',
  'tooltip'
]);

const THRESHOLDS = {
  markdown: { review: 80, high: 140 },
  description: { review: 30, high: 50 },
  noDataMessage: { review: 24, high: 36 },
  title: { review: 10, high: 16 },
  label: { review: 8, high: 12 },
  linkLabel: { review: 8, high: 12 },
  placeholder: { review: 12, high: 18 },
  ariaLabel: { review: 12, high: 18 },
  tooltip: { review: 30, high: 50 }
};

function listSourceFiles() {
  const workbookFiles = fs.readdirSync(WORKBOOKS_DIR, { withFileTypes: true })
    .filter(entry => entry.isDirectory())
    .map(entry => path.join(WORKBOOKS_DIR, entry.name, `${entry.name}.workbook`))
    .filter(file => fs.existsSync(file))
    .sort();
  return [...SHARED_FILES, ...workbookFiles];
}

function plainText(value) {
  return value
    .replace(/https?:\/\/[^\s)]+/g, ' link ')
    .replace(/\[([^\]]+)]\([^)]*\)/g, '$1')
    .replace(/<[^>]+>/g, ' ')
    .replace(/[`*_#>|~-]/g, ' ')
    .replace(/\{[A-Za-z_][A-Za-z0-9_]*(?::\w+)?}/g, ' parameter ')
    .replace(/\s+/g, ' ')
    .trim();
}

function wordCount(value) {
  const text = plainText(value);
  return text ? text.split(/\s+/).length : 0;
}

function lineFor(raw, itemName, value) {
  const needles = [];
  if (itemName) needles.push(`"name": ${JSON.stringify(itemName)}`);
  needles.push(JSON.stringify(value));
  for (const needle of needles) {
    const index = raw.indexOf(needle);
    if (index >= 0) return raw.slice(0, index).split(/\r?\n/).length;
  }
  return null;
}

function classify(field, objectPath, itemType) {
  if (field === 'json' && itemType === 1) return 'markdown';
  if (field === 'linkLabel') return 'linkLabel';
  if (field === 'noDataMessage') return 'noDataMessage';
  if (field === 'description') return 'description';
  if (field === 'title') return 'title';
  if (field === 'label') return objectPath.includes('labelSettings') ? 'columnLabel' : 'label';
  return field;
}

function severityFor(category, words) {
  const threshold = THRESHOLDS[category === 'columnLabel' ? 'label' : category];
  if (!threshold || words <= threshold.review) return null;
  return words > threshold.high ? 'high' : 'review';
}

function extractLinks(value) {
  const links = [];
  const markdownLinkPattern = /\[([^\]]+)]\((https?:\/\/[^\s)]+)\)/g;
  for (const match of value.matchAll(markdownLinkPattern)) {
    links.push({ label: plainText(match[1]), url: match[2] });
  }

  const visibleText = value
    .replace(/```[\s\S]*?```/g, ' ')
    .replace(/`[^`\r\n]+`/g, ' ')
    .replace(markdownLinkPattern, ' ');
  for (const match of visibleText.matchAll(/https?:\/\/[^\s)\]"'<>`]+/g)) {
    links.push({ label: null, url: match[0].replace(/[.,;:]$/, '') });
  }
  return links;
}

function auditFile(file) {
  const raw = fs.readFileSync(file, 'utf8');
  const document = JSON.parse(raw);
  const relativeFile = path.relative(ROOT, file).replace(/\\/g, '/');
  const entries = [];
  const links = [];

  // Per-tab files package shared parameters/navigation in items[0]/items[1].
  // build-monolithic.js drops those copies and consumes only items[2].
  const auditRoot = relativeFile.startsWith('workbooks/')
    ? { items: Array.isArray(document.items) ? document.items.slice(2, 3) : [] }
    : document;

  function addEntry(field, value, objectPath, item) {
    if (typeof value !== 'string' || value.trim() === '') return;
    const category = classify(field, objectPath, item && item.type);
    const words = wordCount(value);
    const hidden = Boolean(item && item.isHiddenWhenLocked) || /hidden/i.test(value.slice(0, 12));
    const entry = {
      file: relativeFile,
      line: lineFor(raw, item && item.name, value),
      item: item && item.name ? item.name : '(unnamed)',
      category,
      words,
      characters: value.length,
      severity: severityFor(category, words),
      audience: hidden ? 'internal' : 'customer',
      text: value
    };
    entries.push(entry);
    for (const link of extractLinks(value)) {
      links.push({ file: relativeFile, line: entry.line, item: entry.item, ...link });
    }
  }

  function walk(value, objectPath = '$', owningItem = null) {
    if (Array.isArray(value)) {
      value.forEach((child, index) => walk(child, `${objectPath}[${index}]`, owningItem));
      return;
    }
    if (!value || typeof value !== 'object') return;

    const item = Number.isInteger(value.type) && value.content ? value : owningItem;
    for (const [key, child] of Object.entries(value)) {
      const childPath = `${objectPath}.${key}`;
      if (key === 'json' && item && item.type === 1) {
        addEntry(key, child, childPath, item);
      } else if (TEXT_FIELDS.has(key)) {
        addEntry(key, child, childPath, item);
      }

      if (key === 'cellValue' && typeof child === 'string' && /^https?:\/\//i.test(child)) {
        links.push({
          file: relativeFile,
          line: lineFor(raw, item && item.name, child),
          item: item && item.name ? item.name : '(unnamed)',
          label: typeof value.linkLabel === 'string' ? value.linkLabel : null,
          url: child
        });
      }
      walk(child, childPath, item);
    }
  }

  walk(auditRoot);
  return { entries, links };
}

function summarize(entries, links, files) {
  const customerEntries = entries.filter(entry => entry.audience === 'customer');
  const outliers = customerEntries.filter(entry => entry.severity);
  const byCategory = {};
  const byFile = {};

  for (const entry of customerEntries) {
    byCategory[entry.category] = (byCategory[entry.category] || 0) + 1;
    if (!byFile[entry.file]) byFile[entry.file] = { entries: 0, words: 0, outliers: 0 };
    byFile[entry.file].entries++;
    byFile[entry.file].words += entry.words;
    if (entry.severity) byFile[entry.file].outliers++;
  }

  const textGroups = new Map();
  for (const entry of customerEntries) {
    const normalized = plainText(entry.text).toLowerCase();
    if (normalized.length < 20) continue;
    if (!textGroups.has(normalized)) textGroups.set(normalized, []);
    textGroups.get(normalized).push({ file: entry.file, item: entry.item, category: entry.category });
  }
  const duplicates = [...textGroups.entries()]
    .filter(([, occurrences]) => occurrences.length > 1)
    .map(([text, occurrences]) => ({ text, count: occurrences.length, occurrences }))
    .sort((left, right) => right.count - left.count);

  const uniqueLinks = [...new Set(links.map(link => link.url))].sort();
  return {
    generatedAt: new Date().toISOString(),
    scope: {
      sourceFiles: files.map(file => path.relative(ROOT, file).replace(/\\/g, '/')),
      generatedMonolithExcluded: 'AzureLocal-LENS-Workbook.json'
    },
    thresholds: THRESHOLDS,
    totals: {
      sourceFiles: files.length,
      customerTextEntries: customerEntries.length,
      customerWords: customerEntries.reduce((sum, entry) => sum + entry.words, 0),
      internalTextEntries: entries.length - customerEntries.length,
      lengthOutliers: outliers.length,
      links: links.length,
      uniqueLinks: uniqueLinks.length,
      duplicatedTexts: duplicates.length
    },
    byCategory,
    byFile,
    outliers: outliers.sort((left, right) => right.words - left.words),
    duplicates,
    links,
    uniqueLinks,
    entries
  };
}

function printSummary(report) {
  console.log('Azure Local LENS workbook content audit baseline');
  console.log('================================================');
  console.log(`Source files:          ${report.totals.sourceFiles}`);
  console.log(`Customer text entries: ${report.totals.customerTextEntries}`);
  console.log(`Customer-facing words: ${report.totals.customerWords}`);
  console.log(`Length outliers:       ${report.totals.lengthOutliers}`);
  console.log(`Unique external links: ${report.totals.uniqueLinks}`);
  console.log(`Repeated text groups:  ${report.totals.duplicatedTexts}`);
  console.log('\nLargest customer-facing text blocks:');
  report.outliers.slice(0, 20).forEach((entry, index) => {
    console.log(`${String(index + 1).padStart(2)}. ${entry.words} words [${entry.category}] ${entry.file}:${entry.line} (${entry.item})`);
  });
  console.log('\nLength flags are editorial triage signals, not test failures.');
}

const files = listSourceFiles();
const results = files.map(auditFile);
const entries = results.flatMap(result => result.entries);
const links = results.flatMap(result => result.links);
const report = summarize(entries, links, files);

if (process.argv.includes('--json')) {
  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
} else {
  printSummary(report);
}