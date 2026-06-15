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

let updated = 0;
for (const f of files) {
  if (f.includes('l10n/generated')) continue;
  const content = fs.readFileSync(f, 'utf8');
  if (content.includes("import 'l10n/generated/app_localizations.dart'")) {
    const newContent = content.replace(
      "import 'l10n/generated/app_localizations.dart';",
      "import 'package:zenfile/l10n/generated/app_localizations.dart';"
    );
    if (newContent !== content) {
      fs.writeFileSync(f, newContent, 'utf8');
      updated++;
      console.log(`Fixed ${f.replace(path.join(__dirname, '..'), '')}`);
    }
  }
}
console.log(`\nTotal: ${updated} files`);