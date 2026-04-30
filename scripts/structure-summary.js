// Quick structural summary of the workbook: top-level items, tab names, and per-tab byte size
const fs = require('fs');
const path = require('path');

const file = path.resolve(__dirname, '..', 'AzureLocal-LENS-Workbook.json');
const text = fs.readFileSync(file, 'utf8');
const j = JSON.parse(text);

function size(obj) {
  return Buffer.byteLength(JSON.stringify(obj), 'utf8');
}

console.log('Total file size:', text.length, 'bytes');
console.log('Top-level items:', j.items.length);
console.log('');

j.items.forEach((it, i) => {
  const t = it.type;
  const name = it.name || '(no-name)';
  const c = it.content || {};
  const sz = size(it);
  const tabs = c.tabs;
  console.log(`[${i}] type=${t} name="${name}" size=${sz}B`);
  if (tabs) {
    console.log(`    -> ${tabs.length} tabs:`);
    tabs.forEach((tab, ti) => {
      const tsz = size(tab);
      console.log(`       tab[${ti}] name="${tab.name}" title="${tab.title || ''}" size=${tsz}B`);
    });
  }
  if (c.items) {
    console.log(`    -> ${c.items.length} nested items`);
  }
});
