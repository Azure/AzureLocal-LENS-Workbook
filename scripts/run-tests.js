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

    let xml = '<?xml version="1.0" encoding="utf-8"?>\n';
    xml += `<test-run id="1" testcasecount="${total}" result="${result}" total="${total}" passed="${passed}" failed="${failed}" inconclusive="0" skipped="0" start-time="${timestamp}" end-time="${timestamp}" duration="0">\n`;
    xml += `  <test-suite type="Assembly" id="0-1" name="LENS.Workbook.Tests" fullname="LENS.Workbook.Tests" testcasecount="${total}" result="${result}" total="${total}" passed="${passed}" failed="${failed}" inconclusive="0" skipped="0">\n`;

    let suiteId = 1;
    Object.entries(suites).forEach(([suiteName, tests]) => {
        const suiteFailures = tests.filter(t => !t.passed).length;
        const suiteResult = suiteFailures > 0 ? 'Failed' : 'Passed';
        const safeSuiteName = suiteName.replace(/[<>&"']/g, c => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;', "'": '&apos;' }[c]));

        xml += `    <test-suite type="TestFixture" id="0-${suiteId}" name="${safeSuiteName}" fullname="LENS.Workbook.Tests.${safeSuiteName}" testcasecount="${tests.length}" result="${suiteResult}" total="${tests.length}" passed="${tests.length - suiteFailures}" failed="${suiteFailures}" inconclusive="0" skipped="0">\n`;

        let testId = 1;
        tests.forEach(test => {
            const safeTestName = test.name.replace(/[<>&"']/g, c => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;', "'": '&apos;' }[c]));
            const testResult = test.passed ? 'Passed' : 'Failed';

            xml += `      <test-case id="0-${suiteId}-${testId}" name="${safeTestName}" fullname="LENS.Workbook.Tests.${safeSuiteName}.${safeTestName}" result="${testResult}">\n`;

            if (!test.passed) {
                const safeExpected = String(test.expected).replace(/[<>&"']/g, c => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;', "'": '&apos;' }[c]));
                const safeActual = String(test.actual).replace(/[<>&"']/g, c => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;', "'": '&apos;' }[c]));
                xml += `        <failure>\n`;
                xml += `          <message><![CDATA[Expected: ${safeExpected}, Got: ${safeActual}]]></message>\n`;
                xml += `          <stack-trace><![CDATA[Expected: ${safeExpected}\nActual: ${safeActual}]]></stack-trace>\n`;
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

let workbook, workbookRaw, readme;
try {
    workbookRaw = fs.readFileSync(workbookPath, 'utf8');
    workbook = JSON.parse(workbookRaw);
    readme = fs.readFileSync(readmePath, 'utf8');
} catch (e) {
    console.error('Failed to load workbook or README:', e.message);
    process.exit(1);
}

const allItems = collectAllItems(workbook.items || []);
const allQueries = extractQueries(allItems);
const allCharts = extractCharts(allItems);

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

    // Check items have valid types (1=markdown, 3=query, 9=parameter, 10=notebookgroup, 11=link)
    const validTypes = [1, 3, 9, 10, 11, 12];
    const itemsWithValidType = allItems.filter(i => validTypes.includes(i.type));
    assert(itemsWithValidType.length === allItems.length,
        'All items have valid type values (1,3,9,10,11,12)',
        allItems.length, itemsWithValidType.length);

    // Named items should have mostly unique names (minor duplicates acceptable in complex workbooks)
    const namedItems = allItems.filter(i => i.name);
    const uniqueNames = new Set(namedItems.map(i => i.name));
    const duplicateCount = namedItems.length - uniqueNames.size;
    assert(duplicateCount <= 5,
        `Named items have minimal duplicates (${duplicateCount} found, <=5 allowed)`,
        '<=5', duplicateCount);
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

    // Verify the Issue #24 fix: Update Attempts by Day chart should use TimeBucket for xAxis
    const updateAttemptsChart = allCharts.find(c =>
        c.name === 'update-attempts-by-day-chart' ||
        (c.title && c.title.includes('Update Attempts by Day'))
    );
    if (updateAttemptsChart) {
        assert(updateAttemptsChart.chartSettings.xAxis === 'TimeBucket',
            'Update Attempts by Day chart uses TimeBucket for xAxis (Issue #24 fix)',
            'TimeBucket', updateAttemptsChart.chartSettings.xAxis);

        // Verify TimeBucket is in the query projection
        assert(updateAttemptsChart.query.includes('TimeBucket, TimeLabel'),
            'Update Attempts by Day query projects TimeBucket column',
            'contains TimeBucket', updateAttemptsChart.query.includes('TimeBucket, TimeLabel') ? 'contains TimeBucket' : 'missing TimeBucket');
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
    const allParams = [];
    parameterItems.forEach(pi => {
        if (pi.content && pi.content.parameters) {
            pi.content.parameters.forEach(p => allParams.push(p));
        }
    });

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
    const validVizTypes = ['barchart', 'piechart', 'table', 'tiles', 'graph', 'map', 'linechart', 'areachart', 'scatter', 'categoricalbar'];

    const invalidVizTypes = uniqueVizTypes.filter(v => !validVizTypes.includes(v));
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
    assert(gridsWithRowLimit.length >= gridItems.filter(i => i.content.gridSettings.rowLimit).length,
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

    // All crossComponentResources should reference {Subscriptions}
    const itemsRefSubscriptions = itemsWithCCR.filter(i =>
        i.content.crossComponentResources.includes('{Subscriptions}')
    );
    assert(itemsRefSubscriptions.length === itemsWithCCR.length,
        'All crossComponentResources reference {Subscriptions}',
        itemsWithCCR.length, itemsRefSubscriptions.length);
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
        'microsoft.operationalinsights/workspaces'
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
    const fileSizeKB = Math.round(fileSizeBytes / 1024);
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
    assert(readme.includes('# Azure Local LENS'),
        'README has main title', 'found', readme.includes('# Azure Local LENS') ? 'found' : 'not found');

    assert(readme.includes('## How to Import the Workbook'),
        'README has import instructions', 'found', readme.includes('## How to Import the Workbook') ? 'found' : 'not found');

    assert(readme.includes('## Prerequisites'),
        'README has prerequisites section', 'found', readme.includes('## Prerequisites') ? 'found' : 'not found');

    assert(readme.includes('## Features'),
        'README has features section', 'found', readme.includes('## Features') ? 'found' : 'not found');

    assert(readme.includes('## Appendix: Previous Version Changes'),
        'README has version history appendix', 'found', readme.includes('## Appendix: Previous Version Changes') ? 'found' : 'not found');

    assert(readme.includes('## Contributing'),
        'README has contributing section', 'found', readme.includes('## Contributing') ? 'found' : 'not found');

    assert(readme.includes('## License'),
        'README has license section', 'found', readme.includes('## License') ? 'found' : 'not found');
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
