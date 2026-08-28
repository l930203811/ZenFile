const fs = require('fs');
const path = require('path');

const dir = path.join(__dirname, '..', 'lib');
const files = [];

function walk(d) {
  fs.readdirSync(d).forEach(f => {
    const p = path.join(d, f);
    const s = fs.statSync(p);
    s.isDirectory() ? walk(p) : files.push(p);
  });
}
walk(dir);

let added = 0;
for (const f of files) {
  if (f.includes('l10n/generated')) continue;
  const content = fs.readFileSync(f, 'utf8');
  if (content.includes('L10n.of') && !content.includes("import 'l10n/generated/app_localizations.dart'")) {
    const lines = content.split('\n');
    // Find insertion point: after the last consecutive import line
    let insertAt = 0;
    while (insertAt < lines.length && /^\s*import /.test(lines[insertAt])) {
      insertAt++;
    }
    // Insert the l10n import at the top
    lines.splice(insertAt, 0, "import 'l10n/generated/app_localizations.dart';");
    fs.writeFileSync(f, lines.join('\n'), 'utf8');
    added++;
    console.log(`+ ${f.replace(path.join(__dirname, '..'), '')}`);
  }
}
console.log(`\nTotal: ${added} files`);