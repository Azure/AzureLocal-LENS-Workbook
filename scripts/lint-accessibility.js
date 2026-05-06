/**
 * scripts/lint-accessibility.js — Flags inline HTML used for visual styling
 * inside markdown text items. John Gardner's gallery review guidance:
 * use the workbook text `style` field (info|warning|success|error|upsell)
 * instead of <span style=...>, <font color=...>, <div style=...> etc.
 *
 * Walks every per-tab sub-template (or the monolithic root file) and
 * reports any markdown that contains disallowed inline styling.
 *
 * Exits non-zero on findings (suitable for CI).
 *
 * Usage:
 *   node scripts/lint-accessibility.js              # walks workbooks/**\/*.workbook
 *   node scripts/lint-accessibility.js --root       # also lints the monolithic root file
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const WORKBOOKS_DIR = path.join(ROOT, 'workbooks');
const ROOT_FILE = path.join(ROOT, 'AzureLocal-LENS-Workbook.json');

// Patterns that indicate a presentational style applied via raw HTML in markdown.
// Each pattern's key is a short label used in error output.
const PATTERNS = {
  'span-style':  /<span\s[^>]*\bstyle\s*=/i,
  'div-style':   /<div\s[^>]*\bstyle\s*=/i,
  'font-color':  /<font\s[^>]*\bcolor\s*=/i,
  'font-tag':    /<font[\s>]/i,
  'p-style':     /<p\s[^>]*\bstyle\s*=/i,
  'b-style':     /<b\s[^>]*\bstyle\s*=/i,
  'bg-attr':     /\bbgcolor\s*=/i,
  'color-attr':  /(?:^|[^a-z])color\s*=\s*["']/i,
  'inline-style-any': /\bstyle\s*=\s*["'][^"']*(?:color|background|font-size|font-weight|font-family)\b/i
};

// Walk an item tree and collect markdown bodies with their item names.
function collectMarkdown(items, depth = 0, out = []) {
  if (!Array.isArray(items)) return out;
  for (const it of items) {
    if (it && it.type === 1 && it.content && typeof it.content.json === 'string') {
      out.push({ name: it.name || '(unnamed)', text: it.content.json });
    }
    if (it && it.content && Array.isArray(it.content.items)) {
      collectMarkdown(it.content.items, depth + 1, out);
    }
  }
  return out;
}

function lintFile(file) {
  const wb = JSON.parse(fs.readFileSync(file, 'utf8'));
  const md = collectMarkdown(wb.items || []);
  const findings = [];
  for (const { name, text } of md) {
    for (const [label, pattern] of Object.entries(PATTERNS)) {
      const m = text.match(pattern);
      if (m) {
        const idx = m.index;
        const ctx = text.slice(Math.max(0, idx - 30), Math.min(text.length, idx + 80))
          .replace(/\s+/g, ' ').trim();
        findings.push({ name, label, snippet: ctx });
      }
    }
  }
  return findings;
}

function listSubTemplates() {
  if (!fs.existsSync(WORKBOOKS_DIR)) return [];
  const out = [];
  for (const slug of fs.readdirSync(WORKBOOKS_DIR)) {
    const f = path.join(WORKBOOKS_DIR, slug, `${slug}.workbook`);
    if (fs.existsSync(f)) out.push(f);
  }
  return out;
}

const files = listSubTemplates();
if (process.argv.includes('--root')) files.push(ROOT_FILE);

if (files.length === 0) {
  console.error('No workbook files found.');
  process.exit(1);
}

let totalFindings = 0;
for (const file of files) {
  const findings = lintFile(file);
  const rel = path.relative(ROOT, file);
  if (findings.length === 0) {
    console.log(`✅ ${rel}`);
    continue;
  }
  console.log(`❌ ${rel}  (${findings.length} issue${findings.length === 1 ? '' : 's'})`);
  for (const f of findings) {
    console.log(`   [${f.label}] in "${f.name}": ${f.snippet}`);
  }
  totalFindings += findings.length;
}

if (totalFindings > 0) {
  console.error(`\n❌ ${totalFindings} accessibility issue(s).`);
  console.error('   Replace inline HTML styling with the workbook text "style" field');
  console.error('   (info | warning | success | error | upsell). See:');
  console.error('   https://learn.microsoft.com/azure/azure-monitor/visualize/workbooks-create-workbook#text-styles');
  process.exit(1);
}
console.log(`\n✅ All ${files.length} file(s) free of inline-style HTML.`);
