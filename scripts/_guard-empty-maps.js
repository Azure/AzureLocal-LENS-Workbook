const fs = require('fs');
for (const tab of ['Capacity-Overview', 'Capacity-MultiCluster', 'Capacity-SingleCluster']) {
    const file = `workbooks/${tab}/${tab}.workbook`;
    const source = fs.readFileSync(file, 'utf8');
    const updated = source.replaceAll('dynamic({ClusterRGMap})', "parse_json('{ClusterRGMap}')")
        .replaceAll('dynamic({ClusterNodeMap})', "parse_json('{ClusterNodeMap}')");
    JSON.parse(updated);
    fs.writeFileSync(file, updated);
}