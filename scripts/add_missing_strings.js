const fs = require('fs');
const j = JSON.parse(fs.readFileSync('lib/l10n/app_zh.arb', 'utf8').replace(/^\uFEFF/, ''));

const missing = [
  '无法打开链接 {url}',
  '无法打开链接：{urlString}',
  '核心亮点',
  '保险箱安全',
  '服务器中心',
  '联系与分享',
  'ZenFile - 精美文件管理器',
  '请作者喝杯咖啡 ☕',
  '打赏作者',
  '更新日志',
  '新增浏览页远程文件缩略图预览',
  '修复远程文件无法打开播放的问题',
  '优化远程文件缓存目录统一管理',
  '单指滑动切换页面改为双指滑动（避免误触返回手势）',
  '字体选项标题全面汉化',
  '移除"阻止左侧返回手势打开抽屉"功能',
  '修复：备用图标切换不生效',
  '文本编辑器菜单全面汉化',
  '双面板文件浏览器',
  '内置媒体播放器',
  '应用图标切换（多种风格可选）',
  '下版本更新计划',
  '已知问题',
  '远程服务器边缓存边播放视频',
  '自定义图标上传后桌面图标不会更改（下版本完善）',
  '保存失败，请重试',
  '保存失败: {e}',
];

function hashCode(s) {
  let h = 0;
  for (let i = 0; i < s.length; i++) {
    h = Math.imul(31, h) + s.charCodeAt(i) | 0;
  }
  return h >>> 0;
}

let added = 0;
const existingValues = Object.values(j);
for (const s of missing) {
  if (!existingValues.includes(s)) {
    const key = 'msg' + Math.abs(hashCode(s)).toString(16).padStart(8, '0').substring(0, 8);
    j[key] = s;
    added++;
    console.log('Added:', key, '=', s.substring(0, 40));
  }
}

console.log('\nAdded', added, 'new strings. Total keys:', Object.keys(j).filter(k => !k.startsWith('@')).length);
fs.writeFileSync('lib/l10n/app_zh.arb', JSON.stringify(j, null, 2), 'utf8');
console.log('ARB file updated');