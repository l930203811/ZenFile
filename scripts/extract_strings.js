const fs = require('fs');
const path = require('path');

const LIB_DIR = path.join(__dirname, '..', 'lib');
const OUTPUT_FILE = path.join(__dirname, '..', 'lib', 'l10n', 'app_zh.arb');

// Chinese character pattern
const CN_REGEX = /[\u4e00-\u9fff]+/g;

// Simple slugify for key generation
function toKey(text) {
  return text
    .replace(/[^\u4e00-\u9fff\w\s]/g, '')
    .trim()
    .replace(/\s+/g, '_')
    .toLowerCase()
    .substring(0, 40);
}

function findChineseStrings(content, filePath) {
  const strings = [];
  
  // Match: '中文' or "中文" or '''中文''' or """中文"""
  const patterns = [
    /'''([^']*)'''/g,
    /"""([^"]*)"""/g,
    /'([^'\\]*(?:\\.[^'\\]*)*)'/g,
    /"([^"\\]*(?:\\.[^"\\]*)*)"/g,
  ];

  for (const pattern of patterns) {
    let match;
    while ((match = pattern.exec(content)) !== null) {
      const raw = match[1];
      if (CN_REGEX.test(raw) && raw.trim().length > 0) {
        strings.push({ text: raw.trim(), file: filePath });
      }
    }
  }

  return strings;
}

function main() {
  const allStrings = [];
  const seen = new Map();

  function walk(dir) {
    const files = fs.readdirSync(dir);
    for (const file of files) {
      const fullPath = path.join(dir, file);
      const stat = fs.statSync(fullPath);
      if (stat.isDirectory()) {
        walk(fullPath);
      } else if (file.endsWith('.dart')) {
        const content = fs.readFileSync(fullPath, 'utf8');
        const relPath = path.relative(LIB_DIR, fullPath);
        const found = findChineseStrings(content, relPath);
        for (const s of found) {
          if (!seen.has(s.text)) {
            seen.set(s.text, s);
            allStrings.push(s);
          }
        }
      }
    }
  }

  walk(LIB_DIR);

  // Build ARB content
  const entries = {};
  
  // Header
  entries['@@locale'] = 'zh';

  for (const item of allStrings) {
    let key = toKey(item.text);
    // Ensure unique
    let base = key;
    let counter = 1;
    while (entries[key] !== undefined) {
      key = `${base}_${counter++}`;
    }
    entries[key] = item.text;
  }

  // Write JSON
  const json = JSON.stringify(entries, null, 2);
  fs.writeFileSync(OUTPUT_FILE, '\uFEFF' + json, 'utf8');
  console.log(`Wrote ${allStrings.length} strings to ${OUTPUT_FILE}`);
  console.log(`Key count: ${Object.keys(entries).length}`);
}

main();
