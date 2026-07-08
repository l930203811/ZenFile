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

const withoutImport = [];
for (const f of files) {
  if (f.includes('l10n/generated')) continue;
  const c = fs.readFileSync(f, 'utf8');
  if (c.includes('L10n.of')) {
    if (!c.includes("import 'l10n/generated/app_localizations.dart'")) {
      withoutImport.push(f.replace(path.join(__dirname, '..'), ''));
    }
  }
}

console.log('Files using L10n.of but missing import:');
withoutImport.forEach(f => console.log(f));
console.log(`Total: ${withoutImport.length}`);