const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const LIB_DIR = path.join(__dirname, '..', 'lib');
const OUTPUT_ZH = path.join(__dirname, '..', 'lib', 'l10n', 'app_zh.arb');
const OUTPUT_EN = path.join(__dirname, '..', 'lib', 'l10n', 'app_en.arb');

const CN_REGEX = /[\u4e00-\u9fff]+/g;

// Check if a string is actual user-visible text (not Dart code)
function isUserVisibleText(text) {
  // Skip strings that look like code expressions
  // Pattern: ${xxx(...)} or ${xxx.yyy(...)} - function/method calls inside ${}
  if (/\$\{[\w.]+\([^)]*\)\}/.test(text)) return false;
  // Skip strings that are just ${...} with operators
  if (/^\$\{[^}]+\}[^}]*\$/.test(text)) return false;
  // Skip strings that are clearly code: contains "..." within ${}
  if (/\$\{[^}]*"[^}]*\$/.test(text)) return false;
  // Skip very short strings that are likely code
  if (text.length < 3) return false;
  return true;
}

function toDartKey(text) {
  let s = text
    .replace(/[\u4e00-\u9fff]+/g, '')
    .replace(/[^a-zA-Z0-9\s]/g, ' ')
    .trim()
    .replace(/\s+/g, '_');
  
  s = s.replace(/^[\d_]+/, '');
  if (s.length === 0) {
    const hash = crypto.createHash('md5').update(text).digest('hex').substring(0, 8);
    s = 'msg' + hash;
  }
  
  const parts = s.split('_').filter(p => p.length > 0);
  return parts.map((p, i) => i === 0 ? p.toLowerCase() : p.charAt(0).toUpperCase() + p.slice(1).toLowerCase()).join('');
}

function extractStringsWithContext(content, filePath) {
  const results = [];
  
  const stringPattern = /(['"])((?:(?!\1|\\)[^\\]|(?:\\.)*)*)\1/g;
  let match;
  while ((match = stringPattern.exec(content)) !== null) {
    const raw = match[2];
    if (CN_REGEX.test(raw) && raw.trim().length > 0 && raw.trim().length < 500) {
      const text = raw.trim();
      if (!isUserVisibleText(text)) continue;
      const key = toDartKey(text);
      results.push({ text, key, file: filePath });
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
  
  const zhEntries = { '@@locale': 'zh' };
  const enEntries = { '@@locale': 'en' };
  const usedKeys = new Set();
  
  for (const item of allItems) {
    let key = toDartKey(item.text);
    if (!/^[a-z]/.test(key)) key = 's' + key;
    
    let finalKey = key.toLowerCase();
    let counter = 1;
    while (usedKeys.has(finalKey)) {
      finalKey = `${key.toLowerCase()}${counter++}`;
    }
    
    usedKeys.add(finalKey);
    zhEntries[finalKey] = item.text;
    zhEntries[`@${finalKey}`] = { 'description': item.file };
    enEntries[finalKey] = finalKey.replace(/([a-z])([A-Z])/g, '$1 $2').replace(/_/g, ' ').toLowerCase();
    enEntries[`@${finalKey}`] = { 'description': item.file };
  }
  
  fs.writeFileSync(OUTPUT_ZH, '\uFEFF' + JSON.stringify(zhEntries, null, 2), 'utf8');
  fs.writeFileSync(OUTPUT_EN, '\uFEFF' + JSON.stringify(enEntries, null, 2), 'utf8');
  
  console.log(`Total user-visible strings: ${allItems.length}`);
  console.log(`All ${Object.keys(zhEntries).length} entries written`);
  
  let bad = 0;
  for (const k of Object.keys(zhEntries)) {
    if (k !== '@@locale' && !k.startsWith('@') && !/^[a-z_][a-z0-9_]*$/.test(k)) {
      console.error(`INVALID KEY: "${k}"`);
      bad++;
    }
  }
  console.log(bad === 0 ? 'All keys valid!' : `Invalid keys: ${bad}`);
}

main();
