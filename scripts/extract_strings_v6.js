const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const LIB_DIR = path.join(__dirname, '..', 'lib');
const OUTPUT_ZH = path.join(__dirname, '..', 'lib', 'l10n', 'app_zh.arb');
const OUTPUT_EN = path.join(__dirname, '..', 'lib', 'l10n', 'app_en.arb');

const CN_REGEX = /[\u4e00-\u9fff]+/g;

// Convert Dart ${expr} to ARB {varName}
function dartToArb(text) {
  let result = text;
  let varIndex = 0;
  const varMap = {};
  
  // Handle ${expr.property} or ${expr.method()} patterns
  result = result.replace(/\$\{([^}]+)\}/g, (match, expr) => {
    // Extract a clean variable name
    let varName = expr
      .replace(/\.map\(.*?\)/g, '')      // remove .map(...)
      .replace(/\.where\(.*?\)/g, '')    // remove .where(...)
      .replace(/\.toList\(\)/g, '')      // remove .toList()
      .replace(/\.toSet\(\)/g, '')       // remove .toSet()
      .replace(/\[\d+\]/g, '')           // remove [index]
      .split('.')[0]                      // take first part
      .replace(/[^a-zA-Z0-9_]/g, '');    // clean
    
    if (!varName || /^\d/.test(varName)) {
      varName = 'v' + (varIndex++);
    }
    
    // Deduplicate
    let finalName = varName;
    let counter = 1;
    while (Object.values(varMap).includes(finalName)) {
      finalName = varName + counter++;
    }
    varMap[match] = finalName;
    return `{${finalName}}`;
  });
  
  // Handle $varName (simple variable)
  result = result.replace(/\$([a-zA-Z_][a-zA-Z0-9_]*)/g, (match, varName) => {
    let finalName = varName;
    let counter = 1;
    while (Object.values(varMap).includes(finalName)) {
      finalName = varName + counter++;
    }
    varMap[match] = finalName;
    return `{${finalName}}`;
  });
  
  return [result, Object.values(varMap)];
}

// Check if a string looks like user-visible text
function isUserVisibleText(text) {
  if (/\$\{[\w.]+\([^)]*\)\}/.test(text)) return false;
  if (/^\$\{[^}]+\}[^}]*\$/.test(text)) return false;
  // Skip multi-line / complex ternary expressions (code, not text)
  if (text.includes(' ? ') || text.includes(' ?:') || text.includes('?\n') || text.includes('\n?') || text.includes('$?')) return false;
  // Skip strings that still have ${...} not converted (edge case)
  if (text.includes('${')) return false;
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
      
      const [arbText, varNames] = dartToArb(text);
      const key = toDartKey(text);
      results.push({ text: arbText, originalText: text, varNames, key, file: filePath });
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
          if (!seen.has(item.originalText)) {
            seen.set(item.originalText, item);
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
    let key = toDartKey(item.originalText);
    if (!/^[a-z]/.test(key)) key = 's' + key;
    
    let finalKey = key.toLowerCase();
    let counter = 1;
    while (usedKeys.has(finalKey)) {
      finalKey = `${key.toLowerCase()}${counter++}`;
    }
    
    usedKeys.add(finalKey);
    zhEntries[finalKey] = item.text;
    
    // Add @ metadata for variables
    if (item.varNames.length > 0) {
      zhEntries[`@${finalKey}`] = {
        'description': item.file,
        'type': 'text',
      };
      enEntries[`@${finalKey}`] = {
        'type': 'text',
      };
    } else {
      zhEntries[`@${finalKey}`] = { 'description': item.file };
      enEntries[`@${finalKey}`] = { 'description': item.file };
    }
    
    // English placeholder
    enEntries[finalKey] = finalKey.replace(/([a-z])([A-Z])/g, '$1 $2').replace(/_/g, ' ').toLowerCase();
  }
  
  fs.writeFileSync(OUTPUT_ZH, '\uFEFF' + JSON.stringify(zhEntries, null, 2), 'utf8');
  fs.writeFileSync(OUTPUT_EN, '\uFEFF' + JSON.stringify(enEntries, null, 2), 'utf8');
  
  console.log(`Total strings: ${allItems.length}`);
  
  let bad = 0;
  for (const k of Object.keys(zhEntries)) {
    if (k !== '@@locale' && !k.startsWith('@') && !/^[a-z_][a-z0-9_]*$/.test(k)) {
      console.error(`INVALID KEY: "${k}"`);
      bad++;
    }
  }
  if (bad === 0) console.log('All keys valid!');
  else console.error(`Invalid keys: ${bad}`);
  
  // Check ${...} still in values
  for (const [k, v] of Object.entries(zhEntries)) {
    if (k !== '@@locale' && !k.startsWith('@') && typeof v === 'string' && v.includes('${')) {
      console.error(`DOLLAR VAR REMAINING in "${k}": ${v}`);
    }
  }
  console.log('ARB generation check complete');
}

main();