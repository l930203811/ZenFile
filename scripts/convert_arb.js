const fs = require('fs');
const path = require('path');

const INPUT_ZH = path.join(__dirname, '..', 'lib', 'l10n', 'app_zh.arb');
const OUTPUT_ZH = path.join(__dirname, '..', 'lib', 'l10n', 'app_zh.arb');
const OUTPUT_EN = path.join(__dirname, '..', 'lib', 'l10n', 'app_en.arb');

function escapeRegExp(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

// Convert $-style template vars to {brace} style, return [convertedText, varNames]
function convertTemplate(text) {
  const varNames = [];
  let converted = text;

  // ${obj.prop} → {objProp} (camelCase merge)
  converted = converted.replace(/\$\{([^}]+)\}/g, (match, expr) => {
    const parts = expr.split('.').map((p, i) => i === 0 ? p : p.charAt(0).toUpperCase() + p.slice(1));
    const name = parts.join('');
    varNames.push(name);
    return `{${name}}`;
  });

  // $varName → {varName}
  converted = converted.replace(/\$([a-zA-Z_][a-zA-Z0-9_]*)/g, (match, name) => {
    varNames.push(name);
    return `{${name}}`;
  });

  return [converted, [...new Set(varNames)]];
}

// Translate Chinese → English (simple rule-based for common patterns)
const ZH_TO_EN = {
  '正在': '...', '打开': 'open', '共享': 'shared', '文档': 'document', '解析': 'parsing',
  '安全': 'secure', '内容': 'content', '流': 'stream', '需要': 'need', '存储': 'storage',
  '权限': 'permission', '才能': 'to', '无缝': 'seamlessly', '管理': 'manage', '组织': 'organize',
  '显示': 'display', '您的': 'your', '媒体': 'media', '文件': 'file', '清理': 'clean',
  '目录': 'directory', '失败': 'failed', '自动': 'auto', '删除': 'delete', '个': '',
  '释放': 'freed', '内部': 'internal', '存储': 'storage', '局域网': 'LAN', 'SMB': 'SMB',
  '文档': 'documents', '成功': 'success', '移动': 'move', '项目': 'item', '传输': 'transfer',
  '操作': 'operation', '已取消': 'cancelled', '连接': 'connect', '远程': 'remote', '服务器': 'server',
  '创建': 'create', '文件夹': 'folder', '出错': 'error', '压缩': 'compress', '超出': 'exceeds',
  '限制': 'limit', '未知': 'unknown', '艺术家': 'artist', '本地': 'local', '下载': 'download',
  '无法': 'cannot', '自身': 'itself', '相同': 'same', '位置': 'location', '复制': 'copy',
  '图片': 'images', '视频': 'videos', '音频': 'audio', '包': '', '安装': 'install', '截图': 'screenshots',
  '应用': 'apps', '网络': 'network', '最近': 'recent', 'FTP': 'FTP', 'Web': 'Web',
  '设备': 'device', '相册': 'gallery', '扫描': 'scan', '所有': 'all', '中未找到': 'not found in',
  '可安装': 'installable', 'APK': 'APK', '启动': 'launch', '分包': 'split', '解压': 'extract',
  '关闭': 'close', '创建成功': 'created successfully', '失败': 'failed', '是否': 'should',
  '所在': 'location', '未找到': 'not found', '支持': 'support', '格式': 'format',
  '分享': 'share', '读取': 'read', '共用': '', '虚拟': 'virtual', '桥': 'bridge',
  '新建': 'new', '备份': 'backup', '恢复': 'restore', '打开链接': 'open link',
  '用心打造': 'crafted with care', '版权所有': 'Copyright', '保留所有权利': 'All rights reserved',
  '持续': 'continue', '动力': 'support', '支付宝': 'Alipay', '微信支付': 'WeChat Pay',
  '长按': 'long press', '图片可保存到相册': 'image can be saved to gallery', '感谢': 'thanks',
  '查看': 'view', '源代码': 'source code', '联系': 'contact', '邮箱': 'email',
  '已复制到剪贴板': 'copied to clipboard', 'QQ群号': 'QQ group',
  '推荐': 'recommend', '一款': 'an', '精美': 'beautiful', '离线': 'offline', '管理器': 'manager',
  '媒体中心': 'media center', '极速体验': 'fast experience', '无状态': 'stateless',
  '缓存与异步扫描': 'cache & async scan', '加密': 'encrypted', '安全': 'secure', '工作区': 'workspace',
  '支持': 'supports', '和': 'and', '精美界面': 'beautiful UI', 'AMOLED': 'AMOLED',
  '纯黑': 'pure black', '绚丽主题': 'vibrant themes', '在仓库中加星': 'star on GitHub',
  '加入': 'join', '频道': 'channel', '与好友分享应用': 'share with friends',
  '新增': 'new', '完整': 'full', '缩略图预览与查看': 'thumbnail preview & view',
  '压缩包格式颜色区分': 'archive format colors', '各有专属颜色': 'each has unique color',
  '远程文件先下载再播放功能': 'remote file download-then-play',
  '修复': 'fixed', '分类页解压后无法跳转到浏览页的问题': 'category extract not jumping to browse',
  '查看缓存目录和解压后打开所在位置导致页面卡死的问题': '"view cache dir" and "open location" causing freeze',
  'ZenFile': 'ZenFile', 'v103': 'v1.0.3',
};

// Very rough MT for demo - replace with actual translations
function simpleTranslate(zh) {
  // For demo purposes, create meaningful English keys
  // Replace with actual human translation in production
  return `[EN] ${zh}`;
}

function processArb(entries) {
  const newEntries = {};
  const meta = {};
  
  for (const [key, value] of Object.entries(entries)) {
    if (key === '@@locale') {
      newEntries[key] = value;
      continue;
    }
    if (key.startsWith('@')) {
      meta[key] = value;
      continue;
    }
    
    const [converted, varNames] = convertTemplate(value);
    newEntries[key] = converted;
    
    // Add @ meta entry for description
    if (varNames.length > 0) {
      newEntries[`@${key}`] = {
        'description': `Variables: ${varNames.join(', ')}`,
      };
    } else {
      newEntries[`@${key}`] = {
        'description': key.replace(/_/g, ' '),
      };
    }
  }
  
  return newEntries;
}

function main() {
  const raw = fs.readFileSync(INPUT_ZH, 'utf8');
  // Remove BOM
  const content = raw.replace(/^\uFEFF/, '');
  const entries = JSON.parse(content);
  
  const processed = processArb(entries);
  
  // Write ZH
  fs.writeFileSync(OUTPUT_ZH, '\uFEFF' + JSON.stringify(processed, null, 2), 'utf8');
  console.log(`Wrote ZH ARB: ${Object.keys(processed).length} entries`);
  
  // Generate EN ARB
  const enEntries = { '@@locale': 'en' };
  for (const [key, value] of Object.entries(entries)) {
    if (key === '@@locale') continue;
    if (key.startsWith('@')) continue;
    // Use simple placeholder - user should replace with real English
    enEntries[key] = key.replace(/_/g, ' ').replace(/([a-z])([A-Z])/g, '$1 $2');
    enEntries[`@${key}`] = processed[`@${key}`] || {};
  }
  
  fs.writeFileSync(OUTPUT_EN, '\uFEFF' + JSON.stringify(enEntries, null, 2), 'utf8');
  console.log(`Wrote EN ARB: ${Object.keys(enEntries).length} entries`);
  console.log('\n⚠️  English translations are placeholders - please replace with real translations!');
}

main();
