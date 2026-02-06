/**
 * generate-summary.js
 * 
 * Reads NUnit XML test results and outputs a Markdown summary table.
 * Intended for use with GitHub Actions Job Summary ($GITHUB_STEP_SUMMARY).
 * 
 * Usage: node scripts/generate-summary.js >> $GITHUB_STEP_SUMMARY
 */

const fs = require('fs');
const path = require('path');

const xmlPath = path.join(__dirname, '..', 'test-results', 'nunit.xml');

if (!fs.existsSync(xmlPath)) {
    console.log('⚠️ No test results found at test-results/nunit.xml');
    process.exit(0);
}

const xml = fs.readFileSync(xmlPath, 'utf8');

function decodeXml(str) {
    return str
        .replace(/&amp;/g, '&')
        .replace(/&lt;/g, '<')
        .replace(/&gt;/g, '>')
        .replace(/&quot;/g, '"')
        .replace(/&apos;/g, "'");
}

// Overall stats
const runMatch = xml.match(/test-run[^>]*total="(\d+)"[^>]*passed="(\d+)"[^>]*failed="(\d+)"/);
let md = '## 🧪 Workbook Unit Test Results\n\n';

if (runMatch) {
    const [, total, passed, failed] = runMatch;
    const icon = failed === '0' ? '✅' : '❌';
    md += `${icon} **${passed}/${total} tests passed** (${failed} failed)\n\n`;
}

// Build table
md += '| Suite | Test | Result |\n';
md += '|-------|------|--------|\n';

const lines = xml.split('\n');
let currentSuite = '';

for (const line of lines) {
    const suiteMatch = line.match(/test-suite type="TestFixture"[^>]*name="([^"]+)"/);
    if (suiteMatch) {
        currentSuite = decodeXml(suiteMatch[1]);
    }

    const caseMatch = line.match(/test-case[^>]*name="([^"]+)"[^>]*result="([^"]+)"/);
    if (caseMatch) {
        let name = decodeXml(caseMatch[1]);
        const result = caseMatch[2];
        const icon = result === 'Passed' ? '✅' : '❌';
        // Strip the fully-qualified suite prefix from test name
        const casePrefix = currentSuite + '.';
        if (name.startsWith(casePrefix)) {
            name = name.substring(casePrefix.length);
        }
        // Strip namespace prefix from suite name for display
        let suiteName = currentSuite;
        const nsPrefix = 'LENS.Workbook.Tests.';
        if (suiteName.startsWith(nsPrefix)) {
            suiteName = suiteName.substring(nsPrefix.length);
        }
        md += `| ${suiteName} | ${name} | ${icon} ${result} |\n`;
    }
}

// Output to stdout (caller redirects to $GITHUB_STEP_SUMMARY)
process.stdout.write(md);
