// Refined: only flag type=3 KqlItem visualizations (not parameter dropdowns)
const fs = require('fs');
const text = fs.readFileSync('AzureLocal-LENS-Workbook.json', 'utf8');
const j = JSON.parse(text);

const findings = [];
function walk(o, path, parent) {
  if (Array.isArray(o)) o.forEach((v, i) => walk(v, path + '[' + i + ']', parent));
  else if (o && typeof o === 'object') {
    if (parent && parent.type === 3 && o === parent.content && typeof o.query === 'string' && o.queryType === 1 && typeof o.noDataMessage !== 'string') {
      const title = o.title || parent.name || '(unnamed)';
      const snippet = o.query.replace(/\s+/g, ' ').slice(0, 200);
      findings.push({ path, title, name: parent.name, snippet, viz: o.visualization || 'table' });
    }
    for (const k of Object.keys(o)) walk(o[k], path + '.' + k, o);
  }
}
walk(j, '', null);

console.log(`Type=3 KqlItem visualizations missing noDataMessage: ${findings.length}\n`);
findings.forEach((f, i) => {
  console.log(`${i + 1}. name="${f.name}" title="${f.title}" viz=${f.viz}`);
  console.log(`   query: ${f.snippet}`);
  console.log();
});
