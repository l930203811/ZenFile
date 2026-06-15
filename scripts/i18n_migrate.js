/**
 * i18n migration script
 * Scans all Dart files, replaces hardcoded Chinese strings with L10n.of(context).xxx
 * 
 * Usage: node scripts/i18n_migrate.js [--dry-run] [--verbose]
 */

const fs = require('fs');
const path = require('path');

const LIB_DIR = path.join(__dirname, '..', 'lib');
const ZH_ARB = path.join(__dirname, '..', 'lib', 'l10n', 'app_zh.arb');
const DRY_RUN = process.argv.includes('--dry-run');
const VERBOSE = process.argv.includes('--verbose');

// Load ARB file
const arbContent = JSON.parse(fs.readFileSync(ZH_ARB, 'utf8').replace(/^\uFEFF/, ''));

// Build: chineseText → l10nKey
const stringMap = new Map();
const metaMap = new Map();
for (const [k, v] of Object.entries(arbContent)) {
  if (k === '@@locale') continue;
  if (k.startsWith('@')) {
    metaMap.set(k.substring(1), v);
    continue;
  }
  if (typeof v === 'string') {
    stringMap.set(v, k);
  }
}

console.log(`Loaded ${stringMap.size} translation entries`);

// Chinese char detector
const CN_REGEX = /[\u4e00-\u9fff]+/;

// Load generated localizations to get method signatures
const l10nFile = path.join(__dirname, '..', 'lib', 'l10n', 'generated', 'app_localizations.dart');
let l10nMethods = [];
if (fs.existsSync(l10nFile)) {
  const l10nContent = fs.readFileSync(l10nFile, 'utf8');
  // Extract method signatures like: String get newFolder => ...
  const methodMatches = l10nContent.matchAll(/String get (\w+)/g);
  for (const m of methodMatches) l10nMethods.push(m[1]);
  const methodMatches2 = l10nContent.matchAll(/String (\w+)\([^)]*\)/g);
  for (const m of methodMatches2) l10nMethods.push(m[1]);
  console.log(`L10n has ${l10nMethods.length} methods`);
}

// Files to skip (generated or not meant to be migrated)
const SKIP_FILES = new Set([
  'l10n/generated/app_localizations.dart',
  'l10n/generated/app_localizations_en.dart',
  'l10n/generated/app_localizations_zh.dart',
]);

// Process each Dart file
let totalReplacements = 0;
let filesModified = 0;
const report = [];

function processFile(filePath) {
  const relPath = path.relative(LIB_DIR, filePath);
  if (SKIP_FILES.has(relPath)) return;
  
  let content = fs.readFileSync(filePath, 'utf8');
  const originalContent = content;
  let fileReplacements = 0;
  let changes = [];
  
  // For each known Chinese string
  for (const [zhText, l10nKey] of stringMap.entries()) {
    // Build the replacement: L10n.of(context).xxx
    // We need to determine if it's a getter or a function call
    const isFunc = l10nKey.startsWith('e') || l10nKey.startsWith('s'); // e, e1, e2, s123...
    const call = `L10n.of(context).${l10nKey}`;
    
    // Skip if this file doesn't import L10n (we'll add the import later)
    // Actually, let's just do the replacement and add the import
    // But first, skip if the replacement is already there
    if (content.includes(call)) continue;
    
    // Replace exact string occurrences
    // Pattern: '中文' or "中文" 
    // We need to be careful to only replace the Chinese string, not other text
    
    // Build regex for the Chinese text (escaped for regex)
    const escaped = zhText.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    
    // Match in single or double quotes
    const patterns = [
      new RegExp(`'${escaped}'`, 'g'),
      new RegExp(`"${escaped}"`, 'g'),
    ];
    
    for (const p of patterns) {
      if (p.test(content)) {
        const before = content.substring(0, p.lastIndex);
        const after = content.substring(p.lastIndex);
        const lineNum = (before.match(/\n/g) || []).length + 1;
        
        content = content.replace(p, `'${call}'`);
        fileReplacements++;
        changes.push({ line: lineNum, key: l10nKey, text: zhText.substring(0, 30) });
        break; // Don't replace multiple times for same string
      }
    }
  }
  
  if (fileReplacements > 0) {
    if (!DRY_RUN) {
      fs.writeFileSync(filePath, content, 'utf8');
    }
    filesModified++;
    totalReplacements += fileReplacements;
    report.push({ file: relPath, count: fileReplacements, changes });
    
    if (VERBOSE) {
      console.log(`\n${relPath} (${fileReplacements} replacements):`);
      for (const c of changes) {
        console.log(`  Line ${c.line}: ${c.key} <- "${c.text}"`);
      }
    }
  }
}

function walk(dir) {
  const files = fs.readdirSync(dir);
  for (const file of files) {
    const fullPath = path.join(dir, file);
    const stat = fs.statSync(fullPath);
    if (stat.isDirectory()) {
      walk(fullPath);
    } else if (file.endsWith('.dart')) {
      processFile(fullPath);
    }
  }
}

walk(LIB_DIR);

console.log(`\n${DRY_RUN ? '[DRY RUN] ' : ''}Modified ${filesModified} files, ${totalReplacements} replacements`);
if (report.length > 0 && !VERBOSE) {
  console.log('\nFiles modified:');
  for (const r of report) {
    console.log(`  ${r.file}: ${r.count} replacements`);
  }
}