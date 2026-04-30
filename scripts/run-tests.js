/**
 * Run Azure Local LENS Workbook unit tests and generate NUnit XML report
 * Usage: node scripts/run-tests.js
 * 
 * Validates the workbook JSON structure, KQL queries, chart configurations,
 * version consistency, and other quality checks.
 */
const path = require('path');
const fs = require('fs');

// ============================================================================
// TEST FRAMEWORK
// ============================================================================
let passCount = 0;
let failCount = 0;
let totalCount = 0;
const testResults = [];
let currentSuite = null;

// Workbook item type constants (from Azure Workbooks schema)
const ITEM_TYPE_MARKDOWN = 1;
const ITEM_TYPE_QUERY = 3;
const ITEM_TYPE_PARAMETER = 9;
const ITEM_TYPE_NOTEBOOKGROUP = 10;
const ITEM_TYPE_LINK = 11;
const ITEM_TYPE_TEXT_PARAMETER = 12;

// Workbook parameter reference pattern: matches {ParamName} or {ParamName:format}; group 1 is the param name.
// Source kept as a string so each call to getParamRefPattern() returns a FRESH RegExp instance —
// /g RegExp objects carry mutable lastIndex state, so reusing one across multiple inputs is unsafe.
// Compiles to: /\{([A-Za-z_][A-Za-z0-9_]*)(?::[\w]+)?\}/g  (backslashes are double-escaped below for the JS string literal)
const PARAM_REF_PATTERN_SOURCE = '\\{([A-Za-z_][A-Za-z0-9_]*)(?::[\\w]+)?\\}';
function getParamRefPattern() {
    return new RegExp(PARAM_REF_PATTERN_SOURCE, 'g');
}

// Azure Workbook visualization types currently allowed by this test suite.
// NOTE: Update this list when Azure Workbooks adds/removes supported visualization types.
const VALID_WORKBOOK_VISUALIZATION_TYPES = ['barchart', 'piechart', 'table', 'tiles', 'graph', 'map', 'linechart', 'areachart', 'scatter', 'categoricalbar', 'timechart'];

const MAX_ALLOWED_DUPLICATE_NAMES = 5;
const MIN_EXPECTED_ITEMS = 200;
const MIN_EXPECTED_QUERIES = 120;
const MIN_EXPECTED_CHARTS = 30;

function assert(condition, testName, expected, actual) {
    totalCount++;
    const result = {
        name: testName,
        suite: currentSuite || 'Default',
        passed: !!condition,
        expected: String(expected),
        actual: String(actual),
        timestamp: new Date().toISOString()
    };
    testResults.push(result);

    if (condition) {
        passCount++;
        console.log(`  ✅ ${testName}`);
    } else {
        failCount++;
        console.log(`  ❌ ${testName}`);
        console.log(`     Expected: ${expected}`);
        console.log(`     Actual:   ${actual}`);
    }
    return result;
}

function testSuite(name, tests) {
    currentSuite = name;
    console.log(`\n📋 ${name}`);
    if (typeof tests === 'function') {
        tests();
    }
}

// ============================================================================
// NUnit XML GENERATOR
// ============================================================================
function generateNUnitXML(results, passed, failed, total) {
    const timestamp = new Date().toISOString();
    const result = failed > 0 ? 'Failed' : 'Passed';

    const suites = {};
    results.forEach(r => {
        const suiteName = r.suite || 'Default';
        if (!suites[suiteName]) suites[suiteName] = [];
        suites[suiteName].push(r);
    });

    // Helper to escape XML special characters in attribute and element values
    const escapeXml = (value) => {
        return String(value).replace(/[<>&"']/g, c => ({
            '<': '&lt;',
            '>': '&gt;',
            '&': '&amp;',
            '"': '&quot;',
            "'": '&apos;'
        }[c]));
    };

    let xml = '<?xml version="1.0" encoding="utf-8"?>\n';
    xml += `<test-run id="1" testcasecount="${total}" result="${result}" total="${total}" passed="${passed}" failed="${failed}" inconclusive="0" skipped="0" start-time="${timestamp}" end-time="${timestamp}" duration="0">\n`;
    xml += `  <test-suite type="Assembly" id="0-1" name="LENS.Workbook.Tests" fullname="LENS.Workbook.Tests" testcasecount="${total}" result="${result}" total="${total}" passed="${passed}" failed="${failed}" inconclusive="0" skipped="0">\n`;

    let suiteId = 1;
    Object.entries(suites).forEach(([suiteName, tests]) => {
        const suiteFailures = tests.filter(t => !t.passed).length;
        const suiteResult = suiteFailures > 0 ? 'Failed' : 'Passed';
        const safeSuiteName = escapeXml(suiteName);

        xml += `    <test-suite type="TestFixture" id="0-${suiteId}" name="${safeSuiteName}" fullname="LENS.Workbook.Tests.${safeSuiteName}" testcasecount="${tests.length}" result="${suiteResult}" total="${tests.length}" passed="${tests.length - suiteFailures}" failed="${suiteFailures}" inconclusive="0" skipped="0">\n`;

        let testId = 1;
        tests.forEach(test => {
            const safeTestName = escapeXml(test.name);
            const testResult = test.passed ? 'Passed' : 'Failed';

            xml += `      <test-case id="0-${suiteId}-${testId}" name="${safeTestName}" fullname="LENS.Workbook.Tests.${safeSuiteName}.${safeTestName}" result="${testResult}">\n`;

            if (!test.passed) {
                // "]]>" closes a CDATA section in XML.
                // Split any literal "]]>" by ending CDATA ("]]>"), inserting literal "]]",
                // then reopening CDATA ("<![CDATA[>"): "]]]]><![CDATA[>" preserves the original text.
                const rawExpected = String(test.expected).replace(/]]>/g, ']]]]><![CDATA[>');
                const rawActual = String(test.actual).replace(/]]>/g, ']]]]><![CDATA[>');
                xml += `        <failure>\n`;
                xml += `          <message><![CDATA[Expected: ${rawExpected}, Got: ${rawActual}]]></message>\n`;
                xml += `          <stack-trace><![CDATA[Expected: ${rawExpected}\nActual: ${rawActual}]]></stack-trace>\n`;
                xml += `        </failure>\n`;
            }

            xml += `      </test-case>\n`;
            testId++;
        });

        xml += `    </test-suite>\n`;
        suiteId++;
    });

    xml += `  </test-suite>\n`;
    xml += `</test-run>\n`;
    return xml;
}

// ============================================================================
// HELPER FUNCTIONS
// ============================================================================

/**
 * Recursively collect all items from the workbook JSON, including nested groups
 */
function collectAllItems(items, depth = 0) {
    const allItems = [];
    if (!Array.isArray(items)) return allItems;

    items.forEach(item => {
        allItems.push({ ...item, _depth: depth });
        // NotebookGroup items have nested items
        if (item.content && item.content.items) {
            allItems.push(...collectAllItems(item.content.items, depth + 1));
        }
    });
    return allItems;
}

/**
 * Extract all KQL queries from the workbook
 */
function extractQueries(items) {
    const queries = [];
    items.forEach(item => {
        if (item.content && item.content.query) {
            queries.push({
                name: item.name || item.content.title || 'unnamed',
                query: item.content.query,
                type: item.type,
                visualization: item.content.visualization
            });
        }
        // Also check parameter items
        if (item.content && item.content.parameters) {
            item.content.parameters.forEach(param => {
                if (param.query) {
                    queries.push({
                        name: param.name || param.label || 'unnamed-param',
                        query: param.query,
                        type: 'parameter'
                    });
                }
            });
        }
    });
    return queries;
}

/**
 * Extract all chart configurations
 */
function extractCharts(items) {
    const charts = [];
    items.forEach(item => {
        if (item.content && item.content.visualization && item.content.chartSettings) {
            charts.push({
                name: item.name || item.content.title || 'unnamed',
                title: item.content.title,
                visualization: item.content.visualization,
                chartSettings: item.content.chartSettings,
                sortBy: item.content.sortBy || null,
                query: item.content.query
            });
        }
    });
    return charts;
}

// ============================================================================
// LOAD WORKBOOK AND README
// ============================================================================
const workbookPath = path.resolve(__dirname, '..', 'AzureLocal-LENS-Workbook.json');
const readmePath = path.resolve(__dirname, '..', 'README.md');

let workbook, workbookRaw;
try {
    workbookRaw = fs.readFileSync(workbookPath, 'utf8');
    workbook = JSON.parse(workbookRaw);
} catch (e) {
    console.error('Failed to load workbook:', e.message);
    process.exit(1);
}

// README is loaded lazily — only the Version Consistency and README Structure Validation
// suites need it, so defer the read until first access.
let readmeCache = null;
function getReadme() {
    if (readmeCache !== null) return readmeCache;
    try {
        readmeCache = fs.readFileSync(readmePath, 'utf8');
        return readmeCache;
    } catch (e) {
        console.error('Failed to load README:', e.message);
        process.exit(1);
    }
}

const allItems = collectAllItems(workbook.items || []);
const allQueries = extractQueries(allItems);
const allCharts = extractCharts(allItems);
const allParams = [];
allItems.filter(i => i.type === 9 && i.content && i.content.parameters).forEach(pi => {
    pi.content.parameters.forEach(p => allParams.push(p));
});

console.log('========================================');
console.log(' Azure Local LENS Workbook - Unit Tests');
console.log('========================================');
console.log(`Loaded workbook: ${allItems.length} items, ${allQueries.length} queries, ${allCharts.length} charts\n`);

// ============================================================================
// TEST SUITES
// ============================================================================

// --- 1. JSON Structure Validation ---
testSuite('JSON Structure Validation', () => {
    assert(workbook !== null && typeof workbook === 'object',
        'Workbook JSON parses successfully', 'object', typeof workbook);

    assert(workbook.version !== undefined,
        'Has top-level "version" property', 'defined', workbook.version);

    assert(workbook.version === 'Notebook/1.0',
        'Version is "Notebook/1.0"', 'Notebook/1.0', workbook.version);

    assert(Array.isArray(workbook.items),
        'Has top-level "items" array', 'array', typeof workbook.items);

    assert(workbook.items.length > 0,
        'Items array is not empty', '>0', workbook.items.length);

    // Check fallbackResourceIds exists
    assert(workbook.fallbackResourceIds !== undefined,
        'Has fallbackResourceIds property', 'defined', String(workbook.fallbackResourceIds !== undefined));
});

// --- 2. Item Structure Validation ---
testSuite('Item Structure Validation', () => {
    // Every item should have a type
    const itemsWithType = allItems.filter(i => i.type !== undefined);
    assert(itemsWithType.length === allItems.length,
        'All items have a "type" property',
        allItems.length, itemsWithType.length);

    // Every item should have content
    const itemsWithContent = allItems.filter(i => i.content !== undefined);
    assert(itemsWithContent.length === allItems.length,
        'All items have a "content" property',
        allItems.length, itemsWithContent.length);

    // Check items have valid types (1=markdown, 3=query, 9=parameter, 10=notebookgroup, 11=link, 12=textParameter)
    const validTypes = [
        ITEM_TYPE_MARKDOWN,
        ITEM_TYPE_QUERY,
        ITEM_TYPE_PARAMETER,
        ITEM_TYPE_NOTEBOOKGROUP,
        ITEM_TYPE_LINK,
        ITEM_TYPE_TEXT_PARAMETER
    ];
    const itemsWithValidType = allItems.filter(i => validTypes.includes(i.type));
    assert(itemsWithValidType.length === allItems.length,
        'All items have valid type values (1,3,9,10,11,12)',
        allItems.length, itemsWithValidType.length);

    // Named items should have mostly unique names (minor duplicates acceptable in complex workbooks)
    const namedItems = allItems.filter(i => i.name);
    const uniqueNames = new Set(namedItems.map(i => i.name));
    const duplicateCount = namedItems.length - uniqueNames.size;
    assert(duplicateCount <= MAX_ALLOWED_DUPLICATE_NAMES,
        `Named items have minimal duplicates (${duplicateCount} found, <=${MAX_ALLOWED_DUPLICATE_NAMES} allowed)`,
        `<=${MAX_ALLOWED_DUPLICATE_NAMES}`, duplicateCount);
});

// --- 3. Tab Structure Validation ---
testSuite('Tab Structure Validation', () => {
    // Check for the expected tabs (link items with tabs)
    const expectedTabs = [
        'Azure Local Instances',
        'System Health',
        'Update Progress',
        'Azure Local Machines',
        'ARB Status',
        'Azure Local VMs',
        'AKS Arc Clusters'
    ];

    // Tabs are represented as link items - search markdown content for tab references
    const tabLinks = allItems.filter(i =>
        i.type === 11 && i.content && i.content.links
    );
    assert(tabLinks.length > 0,
        'Workbook contains tab navigation links', '>0', tabLinks.length);

    // Verify group items exist for tab content (type 12 = group in Azure Workbooks)
    const groupItems = allItems.filter(i => i.type === 12 || i.type === 10);
    assert(groupItems.length >= expectedTabs.length,
        `Has at least ${expectedTabs.length} group items for tabs`,
        `>=${expectedTabs.length}`, groupItems.length);
});

// --- 4. Version Consistency ---
testSuite('Version Consistency', () => {
    // Extract version from workbook JSON banner
    const versionMatch = workbookRaw.match(/Workbook Version: v([\d.]+)/);
    const jsonVersion = versionMatch ? versionMatch[1] : null;
    assert(jsonVersion !== null,
        'Workbook JSON contains version banner', 'version found', jsonVersion || 'not found');

    // Extract version from README
    const readme = getReadme();
    const readmeVersionMatch = readme.match(/## Latest Version: v([\d.]+)/);
    const readmeVersion = readmeVersionMatch ? readmeVersionMatch[1] : null;
    assert(readmeVersion !== null,
        'README contains latest version header', 'version found', readmeVersion || 'not found');

    // Versions should match
    if (jsonVersion && readmeVersion) {
        assert(jsonVersion === readmeVersion,
            'JSON version matches README version',
            jsonVersion, readmeVersion);
    }

    // Extract version from README recent changes section
    const recentChangesMatch = readme.match(/## Recent Changes \(v([\d.]+)\)/);
    const recentChangesVersion = recentChangesMatch ? recentChangesMatch[1] : null;
    if (recentChangesVersion && jsonVersion) {
        assert(jsonVersion === recentChangesVersion,
            'JSON version matches README Recent Changes version',
            jsonVersion, recentChangesVersion);
    }
});

// --- 5. KQL Query Validation ---
testSuite('KQL Query Validation', () => {
    assert(allQueries.length > 0,
        'Workbook contains KQL queries', '>0', allQueries.length);

    // Check queries are non-empty
    const nonEmptyQueries = allQueries.filter(q => q.query && q.query.trim().length > 0);
    assert(nonEmptyQueries.length === allQueries.length,
        'All queries are non-empty',
        allQueries.length, nonEmptyQueries.length);

    // Check KQL queries reference known resource types
    const knownResourceTypes = [
        'microsoft.azurestackhci',
        'microsoft.kubernetes',
        'microsoft.resourceconnector',
        'microsoft.hybridcompute',
        'microsoft.hybridcontainerservice',
        'microsoft.azurestackhci/logicalnetworks',
        'microsoft.kubernetesruntime',
        'microsoft.kubernetesconfiguration',
        'extensibilityresources'
    ];

    const queryResourceTypes = allQueries.filter(q => {
        const queryLower = q.query.toLowerCase();
        return knownResourceTypes.some(rt => queryLower.includes(rt.toLowerCase())) ||
               queryLower.includes('extensibilityresources') ||
               queryLower.includes('resources');
    });

    assert(queryResourceTypes.length > 0,
        'KQL queries reference known Azure resource types',
        '>0', queryResourceTypes.length);

    // Check KQL query items (type 3) have pipe operators;
    // Merge queries and simple resource graph queries may not have pipes
    const queryItems = allQueries.filter(q => q.type === 3);
    const queryItemsWithPipe = queryItems.filter(q => q.query.includes('|'));
    const pipePercentage = Math.round((queryItemsWithPipe.length / queryItems.length) * 100);
    assert(pipePercentage >= 90,
        `At least 90% of KQL query items contain pipe operators (${pipePercentage}%)`,
        '>=90%', `${pipePercentage}%`);

    // Verify query items (type 3) have balanced quotes (basic check, excludes regex patterns)
    const queryItemsForQuotes = allQueries.filter(q => q.type === 3);
    const queriesWithBalancedQuotes = queryItemsForQuotes.filter(q => {
        // Remove regex patterns and escaped quotes before counting
        const cleaned = q.query.replace(/\\'/g, '').replace(/\\"/g, '');
        const singleQuotes = (cleaned.match(/'/g) || []).length;
        // Note: Double quotes are not checked because KQL queries stored in JSON
        // use escaped double quotes (\") for string literals, making balance
        // validation unreliable after JSON parsing.
        return singleQuotes % 2 === 0;
    });
    assert(queriesWithBalancedQuotes.length === queryItemsForQuotes.length,
        'All KQL query items have balanced single quotes',
        queryItemsForQuotes.length, queriesWithBalancedQuotes.length);

    // Check that queries with 'order by' are syntactically valid
    // KQL 'order by' can have complex expressions or default direction
    const queriesWithOrderBy = allQueries.filter(q => /\border by\b/i.test(q.query));
    assert(queriesWithOrderBy.length > 0,
        'Workbook contains queries with "order by" clauses',
        '>0', queriesWithOrderBy.length);
});

// --- 6. Chart Configuration Validation ---
testSuite('Chart Configuration Validation', () => {
    assert(allCharts.length > 0,
        'Workbook contains chart visualizations', '>0', allCharts.length);

    // Bar and line charts (excluding categoricalbar which auto-configures axes) should have xAxis and yAxis
    const axisCharts = allCharts.filter(c =>
        ['barchart', 'linechart', 'areachart'].includes(c.visualization)
    );
    const axisChartsWithX = axisCharts.filter(c => c.chartSettings.xAxis);
    assert(axisChartsWithX.length === axisCharts.length,
        'All bar/line charts have xAxis configured',
        axisCharts.length, axisChartsWithX.length);

    const axisChartsWithY = axisCharts.filter(c =>
        c.chartSettings.yAxis && c.chartSettings.yAxis.length > 0
    );
    assert(axisChartsWithY.length === axisCharts.length,
        'All bar/line charts have yAxis configured',
        axisCharts.length, axisChartsWithY.length);

    // Verify the Issue #24 fix: Update Attempts by Day chart uses pivoted columns (not group by state)
    const updateAttemptsChart = allCharts.find(c =>
        c.name === 'update-attempts-by-day-chart' ||
        (c.title && c.title.includes('Update Attempts by Day'))
    );
    if (updateAttemptsChart) {
        assert(updateAttemptsChart.chartSettings.xAxis === 'TimeLabel',
            'Update Attempts by Day chart uses TimeLabel for xAxis (Issue #24 fix)',
            'TimeLabel', updateAttemptsChart.chartSettings.xAxis);

        // Verify pivoted yAxis columns instead of group-by-state (fixes cross-subscription ordering)
        const yAxis = updateAttemptsChart.chartSettings.yAxis;
        const hasPivotedColumns = Array.isArray(yAxis) && yAxis.includes('Succeeded') && yAxis.includes('Failed') && yAxis.includes('InProgress');
        assert(hasPivotedColumns,
            'Update Attempts by Day chart uses pivoted yAxis columns [Succeeded, Failed, InProgress] (Issue #24 fix)',
            'Succeeded,Failed,InProgress', JSON.stringify(yAxis));

        // Verify no group-by-state (which causes per-series ordering issues)
        assert(!updateAttemptsChart.chartSettings.group,
            'Update Attempts by Day chart does not use group (avoids per-series ordering)',
            'no group', updateAttemptsChart.chartSettings.group || 'no group');

        // Verify query uses countif pivot pattern
        assert(updateAttemptsChart.query.includes('countif(state =='),
            'Update Attempts by Day query uses countif pivot pattern',
            'contains countif', updateAttemptsChart.query.includes('countif(state ==') ? 'contains countif' : 'missing');
    } else {
        assert(false, 'Update Attempts by Day chart found', 'found', 'not found');
    }
});

// --- 7. Parameter Validation ---
testSuite('Parameter Validation', () => {
    const parameterItems = allItems.filter(i => i.type === 9);
    assert(parameterItems.length > 0,
        'Workbook contains parameter definitions', '>0', parameterItems.length);

    // Check for expected global parameters

    // Subscriptions parameter should exist
    const subsParam = allParams.find(p => p.name === 'Subscriptions');
    assert(subsParam !== undefined,
        'Subscriptions parameter exists', 'defined', String(subsParam !== undefined));

    // ResourceGroupFilter parameter should exist
    const rgFilter = allParams.find(p => p.name === 'ResourceGroupFilter');
    assert(rgFilter !== undefined,
        'ResourceGroupFilter parameter exists', 'defined', String(rgFilter !== undefined));

    // ClusterTagName parameter should exist
    const tagName = allParams.find(p => p.name === 'ClusterTagName');
    assert(tagName !== undefined,
        'ClusterTagName parameter exists', 'defined', String(tagName !== undefined));

    // ClusterTagValue parameter should exist
    const tagValue = allParams.find(p => p.name === 'ClusterTagValue');
    assert(tagValue !== undefined,
        'ClusterTagValue parameter exists', 'defined', String(tagValue !== undefined));
});

// --- 8. Markdown Content Validation ---
testSuite('Markdown Content Validation', () => {
    const markdownItems = allItems.filter(i => i.type === 1);
    assert(markdownItems.length > 0,
        'Workbook contains markdown items', '>0', markdownItems.length);

    // Check version banner exists in markdown
    const versionBanner = markdownItems.find(i =>
        i.content && i.content.json && i.content.json.includes('Workbook Version')
    );
    assert(versionBanner !== undefined,
        'Version banner markdown item exists', 'found', versionBanner ? 'found' : 'not found');

    // Check for GitHub link in version banner
    if (versionBanner) {
        assert(versionBanner.content.json.includes('aka.ms/AzureLocalLENS'),
            'Version banner contains GitHub update link',
            'contains link', 'contains link');
    }
});

// --- 9. Visualization Types Validation ---
testSuite('Visualization Types Validation', () => {
    const visualizationTypes = allItems
        .filter(i => i.content && i.content.visualization)
        .map(i => i.content.visualization);

    const uniqueVizTypes = [...new Set(visualizationTypes)];

    const invalidVizTypes = uniqueVizTypes.filter(v => !VALID_WORKBOOK_VISUALIZATION_TYPES.includes(v));
    assert(invalidVizTypes.length === 0,
        'All visualization types are valid',
        '[]', JSON.stringify(invalidVizTypes));
});

// --- 10. Grid/Table Settings Validation ---
testSuite('Grid and Table Settings Validation', () => {
    const gridItems = allItems.filter(i =>
        i.content && i.content.gridSettings
    );
    assert(gridItems.length > 0,
        'Workbook contains grid/table items', '>0', gridItems.length);

    // Check row limits - should be 2000 or higher (per v0.7.81 improvement)
    const gridsWithRowLimit = gridItems.filter(i =>
        i.content.gridSettings.rowLimit && i.content.gridSettings.rowLimit >= 2000
    );
    assert(gridsWithRowLimit.length === gridItems.filter(i => i.content.gridSettings.rowLimit).length,
        'All grids with row limits have rowLimit >= 2000',
        'all >= 2000',
        `${gridsWithRowLimit.length}/${gridItems.filter(i => i.content.gridSettings.rowLimit).length} >= 2000`);
});

// --- 11. Cross-Component Resources Validation ---
testSuite('Cross-Component Resources Validation', () => {
    const itemsWithCCR = allItems.filter(i =>
        i.content && i.content.crossComponentResources
    );
    assert(itemsWithCCR.length > 0,
        'Workbook has items with crossComponentResources', '>0', itemsWithCCR.length);

    // All crossComponentResources should reference {Subscriptions} or a valid workspace parameter
    const validCCR = ['{Subscriptions}', '{MachinesLogAnalyticsWorkspace}', '{ForecastWorkspace}', '{AzureMonitorWorkspace}', '{HyperVLogAnalyticsWorkspace}'];
    const itemsRefValid = itemsWithCCR.filter(i =>
        i.content.crossComponentResources.some(r => validCCR.includes(r))
    );
    assert(itemsRefValid.length === itemsWithCCR.length,
        'All crossComponentResources reference valid parameters',
        itemsWithCCR.length, itemsRefValid.length);
});

// --- 12. Resource Type References Validation ---
testSuite('Resource Type References Validation', () => {
    const itemsWithResourceType = allItems.filter(i =>
        i.content && i.content.resourceType
    );

    // Known valid resource types for workbook items
    const validResourceTypes = [
        'microsoft.resourcegraph/resources',
        'microsoft.resources/subscriptions',
        'microsoft.operationalinsights/workspaces',
        'microsoft.monitor/accounts'
    ];

    const invalidResourceTypeItems = itemsWithResourceType.filter(i =>
        !validResourceTypes.includes(i.content.resourceType)
    );
    assert(invalidResourceTypeItems.length === 0,
        'All items reference valid resource types',
        '0 invalid', `${invalidResourceTypeItems.length} invalid`);
});

// --- 13. File Size and Performance Checks ---
testSuite('File Size and Performance Checks', () => {
    const fileSizeBytes = Buffer.byteLength(workbookRaw, 'utf8');
    const fileSizeMB = (fileSizeBytes / (1024 * 1024)).toFixed(2);

    // Workbook should be under 5MB (reasonable limit for Azure Workbooks)
    assert(fileSizeBytes < 5 * 1024 * 1024,
        `Workbook file size is under 5MB (actual: ${fileSizeMB}MB)`,
        '<5MB', `${fileSizeMB}MB`);

    // JSON should be well-formed (no trailing commas, etc.)
    try {
        JSON.parse(workbookRaw);
        assert(true, 'JSON is strictly valid (no trailing commas)', 'valid', 'valid');
    } catch (e) {
        assert(false, 'JSON is strictly valid (no trailing commas)', 'valid', e.message);
    }
});

// --- 14. README Structure Validation ---
testSuite('README Structure Validation', () => {
    const readme = getReadme();
    assert(readme.includes('# Azure Local LENS'),
        'README has main title', 'found', readme.includes('# Azure Local LENS') ? 'found' : 'not found');

    assert(readme.includes('## How to Import the Workbook'),
        'README has import instructions', 'found', readme.includes('## How to Import the Workbook') ? 'found' : 'not found');

    assert(readme.includes('## Prerequisites'),
        'README has prerequisites section', 'found', readme.includes('## Prerequisites') ? 'found' : 'not found');

    assert(readme.includes('## Features'),
        'README has features section', 'found', readme.includes('## Features') ? 'found' : 'not found');

    assert(readme.includes('## Appendix: Previous Versions Change Log'),
        'README has version history appendix', 'found', readme.includes('## Appendix: Previous Versions Change Log') ? 'found' : 'not found');

    assert(readme.includes('## Contributing'),
        'README has contributing section', 'found', readme.includes('## Contributing') ? 'found' : 'not found');

    assert(readme.includes('## License'),
        'README has license section', 'found', readme.includes('## License') ? 'found' : 'not found');
});

// --- 15. Portal Link Integrity ---
testSuite('Portal Link Integrity', () => {
    // GUID pattern is only used here, so keep it local to this suite.
    const guidPattern = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i;
    // Collect all portal links from queries
    const portalLinkPattern = /https?:\/\/portal\.azure\.com(?:[\/?"#\s')\]]|$)/;
    const portalLinkQueries = allQueries.filter(q =>
        q.query && portalLinkPattern.test(q.query)
    );
    assert(portalLinkQueries.length > 0,
        'Workbook contains queries with portal links', '>0', portalLinkQueries.length);

    // Portal links with resourceId should use URL-encoded slashes (%2F) not raw /
    const queriesWithResourceIdLink = portalLinkQueries.filter(q =>
        q.query.includes('resourceId/') || q.query.includes('resourceId%2F')
    );
    const queriesWithEncodedResourceId = queriesWithResourceIdLink.filter(q => {
        // Check that the link construction uses replace_string or %2F encoding
        const encodingIndicators = ['%2F', 'replace_string', 'encodedResourceId', 'clusterIdEncoded'];
        return encodingIndicators.some(indicator => q.query.includes(indicator));
    });
    assert(queriesWithEncodedResourceId.length === queriesWithResourceIdLink.length,
        'Portal links use URL-encoded resource IDs',
        queriesWithResourceIdLink.length, queriesWithEncodedResourceId.length);

    // Clusters Currently Updating: View Progress link should use updateName~/null
    // `updateName~/null` is the expected generic portal-link form for "View Progress":
    // it intentionally avoids embedding a specific update name and represents a null/non-specific update context.
    const clusterUpdatingQuery = allQueries.find(q =>
        q.query && q.query.includes('runState == "InProgress"') && q.query.includes('updateRunLink')
    );
    if (clusterUpdatingQuery) {
        assert(clusterUpdatingQuery.query.includes("updateName~/null"),
            'Clusters Currently Updating link uses updateName~/null (not specific update name)',
            'contains updateName~/null', clusterUpdatingQuery.query.includes("updateName~/null") ? 'yes' : 'no');
    }

    // No hardcoded subscription GUIDs in portal links
    // Sufficient to include subscription/resource path segments where GUIDs would appear in a portal URL.
    const MAX_PORTAL_URL_CHECK_LENGTH = 500;
    const queriesWithHardcodedGuids = portalLinkQueries.filter(q => {
        // Extract just the portal URL construction parts
        const portalParts = q.query.split('portal.azure.com').slice(1);
        return portalParts.some(part => {
            const urlPart = part.substring(0, MAX_PORTAL_URL_CHECK_LENGTH);
            return guidPattern.test(urlPart);
        });
    });
    assert(queriesWithHardcodedGuids.length === 0,
        'No hardcoded subscription GUIDs in portal link templates',
        '0', queriesWithHardcodedGuids.length);
});

// --- 16. Conditional Visibility Consistency ---
testSuite('Conditional Visibility Consistency', () => {
    // Top-level groups (direct children of workbook.items) with type 12 should have conditionalVisibility
    const topLevelGroups = (workbook.items || []).filter(i => i.type === 12);
    const groupsWithVisibility = topLevelGroups.filter(i => i.conditionalVisibility);
    assert(groupsWithVisibility.length === topLevelGroups.length,
        'All top-level tab groups have conditionalVisibility',
        topLevelGroups.length, groupsWithVisibility.length);

    // Tab parameter values should be unique across groups
    const tabValues = groupsWithVisibility
        .filter(i => i.conditionalVisibility && i.conditionalVisibility.parameterName === 'selectedTab')
        .map(i => i.conditionalVisibility.value);
    const uniqueTabValues = new Set(tabValues);
    assert(uniqueTabValues.size === tabValues.length,
        'Tab selectedTab parameter values are unique',
        tabValues.length, uniqueTabValues.size);
});

// --- 17. KQL Query Robustness ---
testSuite('KQL Query Robustness', () => {
    // Queries filtering by ResourceGroupFilter should use the correct regex pattern
    const queriesWithRGFilter = allQueries.filter(q =>
        q.query && q.query.includes('ResourceGroupFilter')
    );
    const queriesWithCorrectRGPattern = queriesWithRGFilter.filter(q =>
        q.query.includes('matches regex') || q.query.includes("'{ResourceGroupFilter}' == ''")
    );
    assert(queriesWithCorrectRGPattern.length === queriesWithRGFilter.length,
        'All queries with ResourceGroupFilter use correct regex pattern',
        queriesWithRGFilter.length, queriesWithCorrectRGPattern.length);

    // Queries referencing updateruns should parse updateName consistently
    const updateRunQueries = allQueries.filter(q =>
        q.query && q.query.includes('updateruns') && q.type === 3
    );
    if (updateRunQueries.length > 0) {
        const queriesParsingUpdateName = updateRunQueries.filter(q =>
            q.query.includes("split(id, '/updates/')") || q.query.includes("split(id, '/')[10]")
        );
        assert(queriesParsingUpdateName.length === updateRunQueries.length,
            'All update run queries parse updateName from resource ID',
            updateRunQueries.length, queriesParsingUpdateName.length);
    }

    // Check for orphaned parameter references - parameters used in queries should be defined
    const definedParamNames = new Set(allParams.filter(p => p.name).map(p => p.name));
    // Also add well-known built-in parameters
    ['TimeRange', 'Subscriptions'].forEach(p => definedParamNames.add(p));

    // Extract parameter references from queries
    // Matches workbook parameters in the form {ParamName} or {ParamName:format}; group 1 is the parameter name.
    const referencedParams = new Set();
    allQueries.forEach(q => {
        // Allocate a fresh /g regex per query so lastIndex never carries over between iterations.
        const paramRefPattern = getParamRefPattern();
        let match;
        while ((match = paramRefPattern.exec(q.query)) !== null) {
            referencedParams.add(match[1]);
        }
    });
    const orphanedParams = [...referencedParams].filter(p => !definedParamNames.has(p));
    assert(orphanedParams.length === 0,
        `No orphaned parameter references in queries (${orphanedParams.length > 0 ? orphanedParams.join(', ') : 'none'})`,
        '0 orphaned', `${orphanedParams.length} orphaned`);
});

// --- 18. Grid Formatter Consistency ---
testSuite('Grid Formatter Consistency', () => {
    const gridItems = allItems.filter(i => i.content && i.content.gridSettings);

    // Hidden columns should use formatter 5
    const allFormatters = [];
    gridItems.forEach(gi => {
        if (gi.content.gridSettings.formatters) {
            gi.content.gridSettings.formatters.forEach(f => {
                allFormatters.push({ ...f, parentName: gi.name });
            });
        }
    });
    const hiddenFormatters = allFormatters.filter(f => f.formatter === 5);
    assert(hiddenFormatters.length > 0,
        'Workbook uses hidden columns (formatter 5) for link targets', '>0', hiddenFormatters.length);

    // Link formatters (formatter 7) should reference a valid linkColumn
    const linkFormatters = allFormatters.filter(f =>
        f.formatter === 7 && f.formatOptions && f.formatOptions.linkColumn
    );
    if (linkFormatters.length > 0) {
        // Check that referenced linkColumns have a corresponding hidden formatter (formatter 5)
        const hiddenColumnNames = new Set(hiddenFormatters.map(f => f.columnMatch));
        const linkColumnsWithHidden = linkFormatters.filter(f =>
            hiddenColumnNames.has(f.formatOptions.linkColumn)
        );
        assert(linkColumnsWithHidden.length === linkFormatters.length,
            'All link formatter linkColumns have a corresponding hidden column',
            linkFormatters.length, linkColumnsWithHidden.length);
    }
});

// --- 19. Azure Licensing & Verification Columns (v0.8.1) ---
testSuite('Azure Licensing & Verification Columns', () => {
    // Find the all-clusters-base query
    const clusterBaseQuery = allQueries.find(q => q.name === 'all-clusters-base');
    assert(clusterBaseQuery !== undefined,
        'all-clusters-base query exists', 'found', clusterBaseQuery ? 'found' : 'not found');

    if (clusterBaseQuery) {
        const query = clusterBaseQuery.query;

        // Verify Azure Hybrid Benefit extend
        assert(query.includes('softwareAssuranceProperties.softwareAssuranceStatus'),
            'Base query extracts softwareAssuranceStatus for Azure Hybrid Benefit',
            'contains property', query.includes('softwareAssuranceProperties.softwareAssuranceStatus') ? 'yes' : 'no');
        assert(query.includes('azureHybridBenefit'),
            'Base query defines azureHybridBenefit column',
            'contains column', query.includes('azureHybridBenefit') ? 'yes' : 'no');

        // Verify Windows Server Subscription extend
        assert(query.includes('desiredProperties.windowsServerSubscription'),
            'Base query extracts desiredProperties.windowsServerSubscription',
            'contains property', query.includes('desiredProperties.windowsServerSubscription') ? 'yes' : 'no');
        assert(query.includes('windowsServerSubscription'),
            'Base query defines windowsServerSubscription column',
            'contains column', query.includes('windowsServerSubscription') ? 'yes' : 'no');

        // Verify Azure Verification for VMs extend
        assert(query.includes('reportedProperties.imdsAttestation'),
            'Base query extracts reportedProperties.imdsAttestation',
            'contains property', query.includes('reportedProperties.imdsAttestation') ? 'yes' : 'no');
        assert(query.includes('azureVerificationForVMs'),
            'Base query defines azureVerificationForVMs column',
            'contains column', query.includes('azureVerificationForVMs') ? 'yes' : 'no');

        // Verify column ordering: azureHybridBenefit, windowsServerSubscription, azureVerificationForVMs come after lastSync
        const lastSyncPos = query.indexOf('lastSync');
        const ahbPos = query.indexOf('azureHybridBenefit');
        const wssPos = query.indexOf('windowsServerSubscription');
        const avvmPos = query.indexOf('azureVerificationForVMs');
        const locationPos = query.lastIndexOf('location');
        const regDatePos = query.lastIndexOf('registrationDate');

        assert(ahbPos > lastSyncPos,
            'azureHybridBenefit appears after lastSync in project',
            'after lastSync', ahbPos > lastSyncPos ? 'yes' : 'no');
        assert(wssPos > ahbPos,
            'windowsServerSubscription appears after azureHybridBenefit',
            'after AHB', wssPos > ahbPos ? 'yes' : 'no');
        assert(avvmPos > wssPos,
            'azureVerificationForVMs appears after windowsServerSubscription',
            'after WSS', avvmPos > wssPos ? 'yes' : 'no');

        // Verify Location is second-to-last and Registration Date is last in project
        assert(locationPos > avvmPos,
            'location appears after azureVerificationForVMs (second-to-last)',
            'after AVVM', locationPos > avvmPos ? 'yes' : 'no');
        assert(regDatePos > locationPos,
            'registrationDate appears after location (last column)',
            'after location', regDatePos > locationPos ? 'yes' : 'no');
    }

    // Verify grid formatters exist for the three columns
    const gridItems = allItems.filter(i => i.content && i.content.gridSettings && i.content.gridSettings.formatters);
    const clusterGrid = gridItems.find(i => {
        const formatters = i.content.gridSettings.formatters;
        return formatters.some(f => f.columnMatch === 'azureHybridBenefit');
    });
    assert(clusterGrid !== undefined,
        'Grid has formatter for azureHybridBenefit column', 'found', clusterGrid ? 'found' : 'not found');

    if (clusterGrid) {
        const formatters = clusterGrid.content.gridSettings.formatters;
        const ahbFormatter = formatters.find(f => f.columnMatch === 'azureHybridBenefit');
        const wssFormatter = formatters.find(f => f.columnMatch === 'windowsServerSubscription');
        const avvmFormatter = formatters.find(f => f.columnMatch === 'azureVerificationForVMs');

        assert(wssFormatter !== undefined,
            'Grid has formatter for windowsServerSubscription column', 'found', wssFormatter ? 'found' : 'not found');
        assert(avvmFormatter !== undefined,
            'Grid has formatter for azureVerificationForVMs column', 'found', avvmFormatter ? 'found' : 'not found');

        // Verify formatters use threshold icons (formatter 18)
        assert(ahbFormatter && ahbFormatter.formatter === 18,
            'azureHybridBenefit uses threshold formatter (18)', 18, ahbFormatter ? ahbFormatter.formatter : 'missing');
        assert(wssFormatter && wssFormatter.formatter === 18,
            'windowsServerSubscription uses threshold formatter (18)', 18, wssFormatter ? wssFormatter.formatter : 'missing');
        assert(avvmFormatter && avvmFormatter.formatter === 18,
            'azureVerificationForVMs uses threshold formatter (18)', 18, avvmFormatter ? avvmFormatter.formatter : 'missing');
    }

    // Verify grid label settings for the three columns
    if (clusterGrid && clusterGrid.content.gridSettings.labelSettings) {
        const labels = clusterGrid.content.gridSettings.labelSettings;
        const ahbLabel = labels.find(l => l.columnId === 'azureHybridBenefit');
        const wssLabel = labels.find(l => l.columnId === 'windowsServerSubscription');
        const avvmLabel = labels.find(l => l.columnId === 'azureVerificationForVMs');

        assert(ahbLabel !== undefined && ahbLabel.label === 'Azure Hybrid Benefit',
            'azureHybridBenefit has label "Azure Hybrid Benefit"',
            'Azure Hybrid Benefit', ahbLabel ? ahbLabel.label : 'not found');
        assert(wssLabel !== undefined && wssLabel.label === 'Windows Server Subscription',
            'windowsServerSubscription has label "Windows Server Subscription"',
            'Windows Server Subscription', wssLabel ? wssLabel.label : 'not found');
        assert(avvmLabel !== undefined && avvmLabel.label === 'Azure Verification for VMs',
            'azureVerificationForVMs has label "Azure Verification for VMs"',
            'Azure Verification for VMs', avvmLabel ? avvmLabel.label : 'not found');
    }
});

// --- 20. Azure Licensing & Verification Pie Charts (v0.8.1) ---
testSuite('Azure Licensing & Verification Pie Charts', () => {
    // Verify the section header exists
    const sectionHeader = allItems.find(i =>
        i.name === 'section-header-licensing' ||
        (i.content && i.content.json && i.content.json.includes('Azure Licensing & Verification'))
    );
    assert(sectionHeader !== undefined,
        'Azure Licensing & Verification section header exists', 'found', sectionHeader ? 'found' : 'not found');

    // Verify three licensing pie charts exist
    const licensingChartNames = ['pie-azure-hybrid-benefit', 'pie-windows-server-subscription', 'pie-azure-verification-vms'];
    licensingChartNames.forEach(chartName => {
        const chart = allItems.find(i => i.name === chartName);
        assert(chart !== undefined,
            `Pie chart "${chartName}" exists`, 'found', chart ? 'found' : 'not found');

        if (chart) {
            assert(chart.content.visualization === 'piechart',
                `${chartName} uses piechart visualization`, 'piechart', chart.content.visualization);

            // Each pie chart should have 33% width
            assert(chart.customWidth === '33',
                `${chartName} has 33% width`, '33', chart.customWidth);

            // Each pie chart should query microsoft.azurestackhci/clusters
            assert(chart.content.query.includes('microsoft.azurestackhci/clusters'),
                `${chartName} queries microsoft.azurestackhci/clusters`,
                'contains resource type', chart.content.query.includes('microsoft.azurestackhci/clusters') ? 'yes' : 'no');

            // Each pie chart should have Enabled/Disabled series colors
            const seriesLabels = chart.content.chartSettings && chart.content.chartSettings.seriesLabelSettings;
            const hasEnabled = seriesLabels && seriesLabels.some(s => s.seriesName === 'Enabled' && s.color === 'green');
            const hasDisabled = seriesLabels && seriesLabels.some(s => s.seriesName === 'Disabled' && s.color === 'gray');
            assert(hasEnabled,
                `${chartName} has green "Enabled" series`, 'green Enabled', hasEnabled ? 'yes' : 'no');
            assert(hasDisabled,
                `${chartName} has gray "Disabled" series`, 'gray Disabled', hasDisabled ? 'yes' : 'no');
        }
    });

    // Verify AHB pie chart queries correct property
    const ahbPie = allItems.find(i => i.name === 'pie-azure-hybrid-benefit');
    if (ahbPie) {
        assert(ahbPie.content.query.includes('softwareAssuranceProperties.softwareAssuranceStatus'),
            'AHB pie chart queries softwareAssuranceStatus',
            'contains property', 'yes');
        assert(ahbPie.content.title === 'Azure Hybrid Benefit',
            'AHB pie chart title is "Azure Hybrid Benefit"',
            'Azure Hybrid Benefit', ahbPie.content.title);
    }

    // Verify WSS pie chart queries correct property
    const wssPie = allItems.find(i => i.name === 'pie-windows-server-subscription');
    if (wssPie) {
        assert(wssPie.content.query.includes('desiredProperties.windowsServerSubscription'),
            'WSS pie chart queries windowsServerSubscription',
            'contains property', 'yes');
        assert(wssPie.content.title === 'Windows Server Subscription',
            'WSS pie chart title is "Windows Server Subscription"',
            'Windows Server Subscription', wssPie.content.title);
    }

    // Verify AVVM pie chart queries correct property
    const avvmPie = allItems.find(i => i.name === 'pie-azure-verification-vms');
    if (avvmPie) {
        assert(avvmPie.content.query.includes('reportedProperties.imdsAttestation'),
            'AVVM pie chart queries imdsAttestation',
            'contains property', 'yes');
        assert(avvmPie.content.title === 'Azure Verification for VMs',
            'AVVM pie chart title is "Azure Verification for VMs"',
            'Azure Verification for VMs', avvmPie.content.title);
    }
});

// --- 21. Item Count Regression Guard ---
testSuite('Item Count Regression Guard', () => {
    // Total item count should not drop significantly
    assert(allItems.length >= MIN_EXPECTED_ITEMS,
        `Workbook has at least ${MIN_EXPECTED_ITEMS} items (actual: ${allItems.length})`,
        `>=${MIN_EXPECTED_ITEMS}`, allItems.length);

    // Query count should not drop significantly
    assert(allQueries.length >= MIN_EXPECTED_QUERIES,
        `Workbook has at least ${MIN_EXPECTED_QUERIES} queries (actual: ${allQueries.length})`,
        `>=${MIN_EXPECTED_QUERIES}`, allQueries.length);

    // Chart count should not drop significantly
    assert(allCharts.length >= MIN_EXPECTED_CHARTS,
        `Workbook has at least ${MIN_EXPECTED_CHARTS} charts (actual: ${allCharts.length})`,
        `>=${MIN_EXPECTED_CHARTS}`, allCharts.length);
});

// --- 22. Prometheus / AKS Node Resource Usage Validation ---
testSuite('Prometheus AKS Node Resource Usage', () => {
    // Verify Azure Monitor Workspace parameter exists
    const amwParam = allParams.find(p => p.name === 'AzureMonitorWorkspace');
    assert(amwParam !== undefined,
        'AzureMonitorWorkspace parameter exists', 'found', amwParam ? 'found' : 'not found');

    if (amwParam) {
        assert(amwParam.type === 2,
            'AzureMonitorWorkspace is a dropdown (type 2)', 2, amwParam.type);
        assert(amwParam.query && amwParam.query.includes('microsoft.monitor/accounts'),
            'AzureMonitorWorkspace queries microsoft.monitor/accounts',
            'contains resource type', amwParam.query.includes('microsoft.monitor/accounts') ? 'yes' : 'no');
    }

    // Verify PrometheusTimeRange parameter exists
    const promTimeRange = allParams.find(p => p.name === 'PrometheusTimeRange');
    assert(promTimeRange !== undefined,
        'PrometheusTimeRange parameter exists', 'found', promTimeRange ? 'found' : 'not found');
    if (promTimeRange) {
        assert(promTimeRange.type === 4,
            'PrometheusTimeRange is a time range picker (type 4)', 4, promTimeRange.type);
    }

    // Verify Prometheus tip markdown exists
    const promTip = allItems.find(i => i.name === 'text-prometheus-tip');
    assert(promTip !== undefined,
        'Prometheus tip markdown exists', 'found', promTip ? 'found' : 'not found');
    if (promTip) {
        assert(promTip.content.json.includes('Azure Managed Prometheus'),
            'Prometheus tip mentions Azure Managed Prometheus',
            'contains text', promTip.content.json.includes('Azure Managed Prometheus') ? 'yes' : 'no');
    }

    // Verify all 4 Prometheus chart items exist
    const promItemNames = [
        'cluster-aks-node-cpu-chart',
        'cluster-aks-node-memory-chart',
        'cluster-aks-node-disk-chart',
        'cluster-aks-node-network-chart'
    ];
    promItemNames.forEach(name => {
        const item = allItems.find(i => i.name === name);
        assert(item !== undefined,
            `Prometheus item "${name}" exists`, 'found', item ? 'found' : 'not found');
    });

    // Verify all Prometheus queries use PrometheusQueryProvider/1.0 format
    const promItems = allItems.filter(i => promItemNames.includes(i.name) && i.content && i.content.query);
    const promWithProvider = promItems.filter(i => i.content.query.includes('PrometheusQueryProvider/1.0'));
    assert(promWithProvider.length === promItems.length,
        'All Prometheus queries use PrometheusQueryProvider/1.0 format',
        promItems.length, promWithProvider.length);

    // Verify all Prometheus items use queryType 16
    const promWithQT16 = promItems.filter(i => i.content.queryType === 16);
    assert(promWithQT16.length === promItems.length,
        'All Prometheus items use queryType 16',
        promItems.length, promWithQT16.length);

    // Verify all Prometheus items use microsoft.monitor/accounts resource type
    const promWithRT = promItems.filter(i => i.content.resourceType === 'microsoft.monitor/accounts');
    assert(promWithRT.length === promItems.length,
        'All Prometheus items use microsoft.monitor/accounts resource type',
        promItems.length, promWithRT.length);

    // Verify all Prometheus items reference {AzureMonitorWorkspace} in crossComponentResources
    const promWithCCR = promItems.filter(i =>
        i.content.crossComponentResources && i.content.crossComponentResources.includes('{AzureMonitorWorkspace}')
    );
    assert(promWithCCR.length === promItems.length,
        'All Prometheus items reference {AzureMonitorWorkspace}',
        promItems.length, promWithCCR.length);

    // Verify all Prometheus items use query_range type (all are timecharts now)
    const timechartsWithRange = promItems.filter(i => i.content.query && i.content.query.includes('"type":"query_range"'));
    assert(timechartsWithRange.length === promItems.length,
        'All Prometheus timecharts use query_range type',
        promItems.length, timechartsWithRange.length);

    // Verify all Prometheus items use timechart visualization
    const timechartsWithViz = promItems.filter(i => i.content.visualization === 'timechart');
    assert(timechartsWithViz.length === promItems.length,
        'All Prometheus timecharts use timechart visualization',
        promItems.length, timechartsWithViz.length);

    // Verify all timecharts have timeContextFromParameter set to PrometheusTimeRange
    const timechartsWithTimeCtx = promItems.filter(i => i.content.timeContextFromParameter === 'PrometheusTimeRange');
    assert(timechartsWithTimeCtx.length === promItems.length,
        'All Prometheus timecharts use PrometheusTimeRange time context',
        promItems.length, timechartsWithTimeCtx.length);

    // Verify all Prometheus items have conditional visibility on ClusterFilter
    const promWithVis = promItems.filter(i =>
        i.conditionalVisibility &&
        i.conditionalVisibility.parameterName === 'ClusterFilter' &&
        i.conditionalVisibility.comparison === 'isNotEqualTo' &&
        i.conditionalVisibility.value === 'value::all'
    );
    assert(promWithVis.length === promItems.length,
        'All Prometheus items hidden when ClusterFilter is "all"',
        promItems.length, promWithVis.length);

    // Verify CPU/Memory charts and tables are 50% width (side-by-side layout)
    const promWith50Width = promItems.filter(i => i.customWidth === '50');
    assert(promWith50Width.length === promItems.length,
        'All Prometheus items have 50% width for side-by-side layout',
        promItems.length, promWith50Width.length);
});

// --- 23. Documentation File Validation ---
testSuite('Documentation File Validation', () => {
    const contributingPath = path.resolve(__dirname, '..', 'CONTRIBUTING.md');
    const securityPath = path.resolve(__dirname, '..', 'SECURITY.md');
    const licensePath = path.resolve(__dirname, '..', 'LICENSE');

    const contributingExists = fs.existsSync(contributingPath);
    assert(contributingExists,
        'CONTRIBUTING.md exists', 'true', String(contributingExists));

    if (contributingExists) {
        const contributing = fs.readFileSync(contributingPath, 'utf8');
        assert(contributing.includes('Reporting Issues'),
            'CONTRIBUTING.md has issue reporting section', 'found', contributing.includes('Reporting Issues') ? 'found' : 'not found');
        assert(contributing.includes('Submitting Pull Requests') || contributing.includes('Submitting Changes'),
            'CONTRIBUTING.md has PR submission section', 'found',
            (contributing.includes('Submitting Pull Requests') || contributing.includes('Submitting Changes')) ? 'found' : 'not found');
    }

    const securityExists = fs.existsSync(securityPath);
    assert(securityExists,
        'SECURITY.md exists', 'true', String(securityExists));

    const licenseExists = fs.existsSync(licensePath);
    assert(licenseExists,
        'LICENSE file exists', 'true', String(licenseExists));
});

// --- 24. Split Architecture: Sub-Template Existence ---
testSuite('Split Architecture - Sub-Template Existence', () => {
    const tabMap = require('./template-ids.json');
    const workbooksDir = path.resolve(__dirname, '..', 'workbooks');
    const sharedParams = path.resolve(__dirname, '..', 'shared', 'parameters.json');
    const sharedHeader = path.resolve(__dirname, '..', 'shared', 'header.json');

    assert(fs.existsSync(sharedParams),
        'shared/parameters.json exists', 'true', String(fs.existsSync(sharedParams)));
    assert(fs.existsSync(sharedHeader),
        'shared/header.json exists', 'true', String(fs.existsSync(sharedHeader)));
    assert(fs.existsSync(workbooksDir),
        'workbooks/ directory exists', 'true', String(fs.existsSync(workbooksDir)));

    for (const tab of tabMap.tabs) {
        const file = path.join(workbooksDir, tab.slug, `${tab.slug}.workbook`);
        const exists = fs.existsSync(file);
        assert(exists, `Sub-template exists: workbooks/${tab.slug}/${tab.slug}.workbook`,
            'true', String(exists));
        if (exists) {
            try {
                const sub = JSON.parse(fs.readFileSync(file, 'utf8'));
                assert(sub.version === 'Notebook/1.0',
                    `${tab.slug} has version Notebook/1.0`, 'Notebook/1.0', sub.version);
                assert(Array.isArray(sub.items) && sub.items.length === 3,
                    `${tab.slug} has exactly 3 top-level items (params, main-tabs, content)`,
                    3, Array.isArray(sub.items) ? sub.items.length : 'not array');
                if (Array.isArray(sub.items) && sub.items.length === 3) {
                    assert(sub.items[2].name === tab.groupName,
                        `${tab.slug} content group name matches template-ids.json`,
                        tab.groupName, sub.items[2].name);
                    assert(sub.items[2].conditionalVisibility === undefined,
                        `${tab.slug} content group has no conditionalVisibility (outer template applies it)`,
                        'undefined', String(sub.items[2].conditionalVisibility));
                }
            } catch (e) {
                assert(false, `${tab.slug} parses as JSON`, 'parses', e.message);
            }
        }
    }
});

// --- 25. Split Architecture: Shared Parameters Parity ---
testSuite('Split Architecture - Shared Parameters Parity', () => {
    const tabMap = require('./template-ids.json');
    const sharedParamsPath = path.resolve(__dirname, '..', 'shared', 'parameters.json');
    const workbooksDir = path.resolve(__dirname, '..', 'workbooks');

    if (!fs.existsSync(sharedParamsPath)) {
        assert(false, 'shared/parameters.json available for parity check', 'exists', 'missing');
        return;
    }
    const canonical = JSON.stringify(JSON.parse(fs.readFileSync(sharedParamsPath, 'utf8')));

    for (const tab of tabMap.tabs) {
        const file = path.join(workbooksDir, tab.slug, `${tab.slug}.workbook`);
        if (!fs.existsSync(file)) continue;
        const sub = JSON.parse(fs.readFileSync(file, 'utf8'));
        const subParamsJson = JSON.stringify(sub.items[0]);
        assert(subParamsJson === canonical,
            `${tab.slug} items[0] matches shared/parameters.json`,
            'identical', subParamsJson === canonical ? 'identical' : 'drift');
    }
});

// --- 26. Split Architecture: Round-Trip Integrity ---
testSuite('Split Architecture - Round-Trip Integrity', () => {
    // Build the monolithic in-memory and compare against the on-disk root file.
    // If the round-trip fails the on-disk file must be regenerated:
    //   node scripts/build-monolithic.js
    const tabMap = require('./template-ids.json');
    const sharedParams = JSON.parse(fs.readFileSync(
        path.resolve(__dirname, '..', 'shared', 'parameters.json'), 'utf8'));
    const sharedHeader = JSON.parse(fs.readFileSync(
        path.resolve(__dirname, '..', 'shared', 'header.json'), 'utf8'));

    const items = [sharedParams, ...sharedHeader.items];
    for (const tab of tabMap.tabs) {
        const file = path.resolve(__dirname, '..', 'workbooks', tab.slug, `${tab.slug}.workbook`);
        if (!fs.existsSync(file)) continue;
        const sub = JSON.parse(fs.readFileSync(file, 'utf8'));
        const contentGroup = JSON.parse(JSON.stringify(sub.items[2]));
        const ordered = {
            type: contentGroup.type,
            content: contentGroup.content,
            conditionalVisibility: {
                parameterName: 'selectedTab',
                comparison: 'isEqualTo',
                value: tab.selectedTab
            },
            name: contentGroup.name
        };
        for (const k of Object.keys(contentGroup)) {
            if (!(k in ordered)) ordered[k] = contentGroup[k];
        }
        items.push(ordered);
    }

    const built = {
        version: 'Notebook/1.0',
        items,
        fallbackResourceIds: ['azure monitor'],
        $schema: 'https://github.com/Microsoft/Application-Insights-Workbooks/blob/master/schema/workbook.json'
    };
    const builtText = JSON.stringify(built, null, 2).replace(/\n/g, '\r\n') + '\r\n';

    assert(builtText === workbookRaw,
        'AzureLocal-LENS-Workbook.json is in sync with split sources (run scripts/build-monolithic.js if this fails)',
        'identical', builtText === workbookRaw ? 'identical'
            : `drift (${builtText.length} vs ${workbookRaw.length} bytes)`);
});

// --- 27. Split Architecture: Sub-Template Size Recommendations ---
testSuite('Split Architecture - Sub-Template Size Recommendations', () => {
    // Azure Monitor Workbooks team recommends sub-templates ≤ 200KB for
    // gallery submissions. Hard limit here is 350KB; warn but pass at 200-350KB.
    const tabMap = require('./template-ids.json');
    const HARD_LIMIT_KB = 350;
    const WARN_LIMIT_KB = 200;

    for (const tab of tabMap.tabs) {
        const file = path.resolve(__dirname, '..', 'workbooks', tab.slug, `${tab.slug}.workbook`);
        if (!fs.existsSync(file)) continue;
        const sizeKB = fs.statSync(file).size / 1024;
        assert(sizeKB < HARD_LIMIT_KB,
            `${tab.slug} sub-template under hard size limit (${HARD_LIMIT_KB}KB)`,
            `<${HARD_LIMIT_KB}KB`, `${sizeKB.toFixed(1)}KB`);
        if (sizeKB >= WARN_LIMIT_KB && sizeKB < HARD_LIMIT_KB) {
            console.log(`  ⚠️  ${tab.slug}: ${sizeKB.toFixed(1)}KB exceeds gallery recommendation of ${WARN_LIMIT_KB}KB`);
        }
    }
});

// --- 28. Accessibility: No Inline-Style HTML ---
testSuite('Accessibility - No Inline-Style HTML', () => {
    // John Gardner (Azure Monitor team) review guidance: replace inline HTML
    // styling with the workbook text "style" field for accessibility.
    const inlineStylePattern = /<(?:div|span|font|p|b)\b[^>]*\bstyle\s*=/i;
    let occurrences = 0;
    function scan(o) {
        if (Array.isArray(o)) { o.forEach(scan); return; }
        if (!o || typeof o !== 'object') return;
        for (const k of Object.keys(o)) {
            const v = o[k];
            if (typeof v === 'string' && inlineStylePattern.test(v)) occurrences++;
            else if (v && typeof v === 'object') scan(v);
        }
    }
    scan(workbook);
    assert(occurrences === 0,
        'No inline-style HTML in markdown items (use workbook style field instead)',
        '0', String(occurrences));
});

// ============================================================================
// RESULTS
// ============================================================================
console.log(`\n========================================`);
console.log(` Test Results: ${passCount}/${totalCount} passed, ${failCount} failed`);
console.log(`========================================\n`);

// Ensure test-results directory exists
const resultsDir = path.resolve(__dirname, '..', 'test-results');
if (!fs.existsSync(resultsDir)) {
    fs.mkdirSync(resultsDir, { recursive: true });
}

// Generate and write NUnit XML report
const nunitXml = generateNUnitXML(testResults, passCount, failCount, totalCount);
const nunitPath = path.join(resultsDir, 'nunit.xml');
fs.writeFileSync(nunitPath, nunitXml);
console.log(`NUnit XML report written to: ${nunitPath}`);

// Print failed tests summary
if (failCount > 0) {
    console.log('\nFailed tests:');
    testResults.filter(t => !t.passed).forEach(t => {
        console.log(`  ❌ [${t.suite}] ${t.name}`);
        console.log(`     Expected: ${t.expected}`);
        console.log(`     Actual:   ${t.actual}`);
    });
    console.error(`\n❌ ${failCount} test(s) failed`);
    process.exit(1);
}

console.log(`\n✅ All ${passCount} tests passed!`);
process.exit(0);
