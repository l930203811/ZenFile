const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const LIB_DIR = path.join(__dirname, '..', 'lib');
const OUTPUT_ZH = path.join(__dirname, '..', 'lib', 'l10n', 'app_zh.arb');
const OUTPUT_EN = path.join(__dirname, '..', 'lib', 'l10n', 'app_en.arb');

const CN_REGEX = /[\u4e00-\u9fff]+/g;

// Build a valid Dart identifier from text
function toDartKey(text) {
  // Remove Chinese and non-alphanumeric chars, keep only letters/numbers/underscores
  let s = text
    .replace(/[\u4e00-\u9fff]+/g, '') // remove Chinese
    .replace(/[^a-zA-Z0-9_]/g, ' ')    // replace non-alnum with space
    .trim()
    .replace(/\s+/g, '_');             // spaces to underscores
  
  // Remove leading digits
  s = s.replace(/^[\d]+/, '');
  
  if (s.length === 0) {
    // Fallback: hash the Chinese text
    const hash = crypto.createHash('md5').update(text).digest('hex').substring(0, 8);
    s = 's' + hash;
  }
  
  // camelCase it
  s = s.split('_').map((w, i) => i === 0 ? w.toLowerCase() : w.charAt(0).toUpperCase() + w.slice(1).toLowerCase()).join('');
  
  // Ensure starts with letter
  if (!/^[a-zA-Z]/.test(s)) s = 's' + s;
  
  return s.substring(0, 50);
}

// Map common Chinese phrases to English equivalents for better keys
const PHRASE_MAP = {
  '正在打开共享文档': 'openingSharedDocument',
  '正在解析安全内容流': 'parsingSecureContent',
  '需要存储权限才能无缝管理组织和显示您的媒体文件': 'storagePermissionNeeded',
  '清理缓存目录失败': 'cleanCacheFailed',
  '自动清理缓存': 'autoCleanCache',
  '内部存储': 'internalStorage',
  '局域网': 'lan',
  '新建文件夹': 'newFolder',
  '新建文件': 'newFile',
  '压缩包': 'archive',
  '设置已备份到': 'settingsBackedUpTo',
  '请选择有效的': 'selectValid',
  '关于': 'about',
  '用心打造': 'craftedWithLove',
  '版权所有': 'copyright',
  '感谢您的支持': 'thanksForSupport',
  '下载': 'download',
  '视频': 'video',
  '音频': 'audio',
  '图片': 'image',
  '文档': 'document',
  '压缩': 'compress',
  '解压': 'extract',
  '移动': 'move',
  '复制': 'copy',
  '删除': 'delete',
  '重命名': 'rename',
  '分享': 'share',
  '打开': 'open',
  '关闭': 'close',
  '取消': 'cancel',
  '确认': 'confirm',
  '成功': 'success',
  '失败': 'failed',
  '错误': 'error',
  '警告': 'warning',
  '提示': 'tip',
  '未知': 'unknown',
  '连接': 'connect',
  '断开': 'disconnect',
};

function getKey(text, fileContent, matchIndex) {
  // Check phrase map first
  if (PHRASE_MAP[text]) return PHRASE_MAP[text];
  
  // Look backward for context
  const before = fileContent.substring(Math.max(0, matchIndex - 300), matchIndex);
  const after = fileContent.substring(matchIndex, matchIndex + 100);
  
  // Try to find a preceding identifier or label
  const patterns = [
    /(\w+)[\s]*:[\s]*['"]([^"']+)['"]/,
    /(\w+)[\s]*=[\s]*['"]([^"']+)['"]/,
    /(\w+)\(['"]([^"']+)['"]/,
    /(?:title|label|hint|msg|placeholder|text|content|description|error|warning|name|button)[\s]*[\(:=]+[\s]*['"]([^"']+)['"]/i,
  ];
  
  for (const p of patterns) {
    const re = new RegExp(p.source, 'gi');
    let m;
    while ((m = re.exec(before)) !== null) {
      const val = m[2] || m[1];
      if (!CN_REGEX.test(val) && val.length >= 2) {
        const key = val.replace(/[^a-zA-Z]/g, '');
        if (key.length >= 2 && key.length <= 30) {
          return key.charAt(0).toLowerCase() + key.slice(1);
        }
      }
    }
  }
  
  // Fallback: derive from text content
  return toDartKey(text);
}

function extractStringsWithContext(content, filePath) {
  const results = [];
  
  // Single and double quoted strings
  const stringPattern = /(['"])((?:(?!\1|\\)[^\\]|(?:\\.)*)*)\1/g;
  let match;
  while ((match = stringPattern.exec(content)) !== null) {
    const raw = match[2];
    if (CN_REGEX.test(raw) && raw.trim().length > 0 && raw.trim().length < 500) {
      const text = raw.trim();
      const key = getKey(text, content, match.index);
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
  
  for (const item of allItems) {
    let key = item.key;
    
    // Validate: must be valid Dart identifier
    if (!/^[a-zA-Z_][a-zA-Z0-9_]*$/.test(key)) {
      key = 's' + crypto.createHash('md5').update(item.text).digest('hex').substring(0, 6);
    }
    
    // Ensure unique
    let finalKey = key;
    let counter = 1;
    while (zhEntries[finalKey] !== undefined) {
      finalKey = `${key}_${counter++}`;
    }
    
    zhEntries[finalKey] = item.text;
    zhEntries[`@${finalKey}`] = { 'description': item.file };
    enEntries[finalKey] = finalKey.replace(/([a-z])([A-Z])/g, '$1 $2').replace(/_/g, ' ');
    enEntries[`@${finalKey}`] = { 'description': item.file };
  }
  
  fs.writeFileSync(OUTPUT_ZH, '\uFEFF' + JSON.stringify(zhEntries, null, 2), 'utf8');
  fs.writeFileSync(OUTPUT_EN, '\uFEFF' + JSON.stringify(enEntries, null, 2), 'utf8');
  
  console.log(`Total strings: ${allItems.length}`);
  console.log(`ZH entries: ${Object.keys(zhEntries).length}`);
  
  // Check for invalid keys
  let bad = 0;
  for (const k of Object.keys(zhEntries)) {
    if (k !== '@@locale' && !k.startsWith('@') && !/^[a-zA-Z_][a-zA-Z0-9_]*$/.test(k)) {
      console.error(`BAD KEY: ${k}`);
      bad++;
    }
  }
  if (bad === 0) console.log('All keys valid!');
  else console.error(`Bad keys: ${bad}`);
}

main();
