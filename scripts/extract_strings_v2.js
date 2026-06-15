const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const LIB_DIR = path.join(__dirname, '..', 'lib');
const OUTPUT_ZH = path.join(__dirname, '..', 'lib', 'l10n', 'app_zh.arb');
const OUTPUT_EN = path.join(__dirname, '..', 'lib', 'l10n', 'app_en.arb');

const CN_REGEX = /[\u4e00-\u9fff]+/g;

// Try to derive a camelCase key from surrounding context
function deriveKey(text, fileContent, matchIndex) {
  // Look backward from the match for context clues
  const before = fileContent.substring(Math.max(0, matchIndex - 200), matchIndex);
  
  // Patterns that suggest a key:
  // 'title: "中文"'
  // 'label: "中文"'
  // Text("中文")
  // "中文" → var name
  const patterns = [
    /(?:title|label|msg|desc|placeholder|hint|text|content|name|button|error|success|warning|tip|info|confirm|prompt)[\s]*:[\s]*["']([^"']+)/i,
    /Text\(["']([^"']+)/,
    /(\w+)\s*:\s*["']([^"']+)/,
    /(\w+)\(["'])([^"']+)\2/,
  ];
  
  for (const p of patterns) {
    const m = before.match(new RegExp(p.source, 'i'));
    if (m && m[1] && !CN_REGEX.test(m[1])) {
      const name = m[1].replace(/[^a-zA-Z]/g, '');
      if (name.length >= 2) {
        return name.charAt(0).toLowerCase() + name.slice(1);
      }
    }
  }
  
  // Fallback: hash-based but readable key
  const hash = crypto.createHash('md5').update(text).digest('hex').substring(0, 8);
  const clean = text.replace(/[^\u4e00-\u9fff\w]/g, '').substring(0, 6);
  return 'msg' + clean + hash.substring(0, 2);
}

function extractStringsWithContext(content, filePath) {
  const results = [];
  
  // Find all Chinese string literals
  // Match '...' or "..."
  const stringLiteralPattern = /(['"])((?:(?!\1|\\)[^\\]|(?:\\.)*)*)\1/g;
  
  let match;
  while ((match = stringLiteralPattern.exec(content)) !== null) {
    const quote = match[1];
    const raw = match[2];
    
    if (CN_REGEX.test(raw) && raw.trim().length > 0) {
      const text = raw.trim();
      const key = deriveKey(text, content, match.index);
      results.push({ text, key, file: filePath });
    }
  }
  
  // Also handle triple-quoted strings
  const triplePatterns = [ /'''([^']*)'''/g, /"""([^"]*)"""/g ];
  for (const tp of triplePatterns) {
    while ((match = tp.exec(content)) !== null) {
      const raw = match[1];
      if (CN_REGEX.test(raw) && raw.trim().length > 0) {
        const text = raw.trim();
        const key = deriveKey(text, content, match.index);
        results.push({ text, key, file: filePath });
      }
    }
  }
  
  return results;
}

function main() {
  const allItems = [];
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
        const found = extractStringsWithContext(content, relPath);
        for (const item of found) {
          if (!seen.has(item.text)) {
            seen.set(item.text, item);
            allItems.push(item);
          }
        }
      }
    }
  }
  
  walk(LIB_DIR);
  
  // Build ARB entries with unique keys
  const zhEntries = { '@@locale': 'zh' };
  const enEntries = { '@@locale': 'en' };
  
  for (const item of allItems) {
    let key = item.key;
    // Ensure unique - append counter if duplicate
    let base = key;
    let counter = 2;
    while (zhEntries[key] !== undefined) {
      key = `${base}${counter++}`;
    }
    
    zhEntries[key] = item.text;
    zhEntries[`@${key}`] = { 'description': `${item.file}` };
    enEntries[key] = key.replace(/([a-z])([A-Z])/g, '$1 $2').replace(/_/g, ' ').toLowerCase();
    enEntries[`@${key}`] = { 'description': `${item.file}` };
  }
  
  fs.writeFileSync(OUTPUT_ZH, '\uFEFF' + JSON.stringify(zhEntries, null, 2), 'utf8');
  fs.writeFileSync(OUTPUT_EN, '\uFEFF' + JSON.stringify(enEntries, null, 2), 'utf8');
  
  console.log(`Total strings: ${allItems.length}`);
  console.log(`ZH entries: ${Object.keys(zhEntries).length}`);
  console.log(`EN entries: ${Object.keys(enEntries).length}`);
  console.log('Done!');
}

main();
