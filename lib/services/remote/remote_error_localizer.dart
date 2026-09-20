import 'package:zenfile/l10n/generated/app_localizations.dart';

/// 把远程客户端（FTP / WebDAV / SFTP / SMB/LAN）抛出的英文异常，
/// 统一映射为友好的本地化文字提示。
///
/// 设计取舍：底层 100+ 处 `throw Exception(英文)` 不再逐个改，
/// 而是把所有**用户可见**的展示点改为调用本函数。原始英文异常仍由调用方
/// 保留在日志 / 详情区（便于排查），UI 只展示本地化的 [message]。
///
/// 映射按关键词匹配，优先级从最具体到最泛化（顺序即优先级）。
String localizeRemoteError(dynamic error, L10n l10n) {
  final raw = error?.toString() ?? '';
  final s = raw.toLowerCase();

  // 1) 用户主动取消（最具体，优先）
  if (s.contains('cancelled')) return l10n.remote_err_cancelled;

  // 2) 认证失败：登录 / 密钥 / 权限被拒
  //    SMB : "Authentication failed for 'root'" / STATUS_LOGON_FAILURE(0xC000006D)
  //    FTP : 530 / "login incorrect"
  //    SFTP: "Permission denied (publickey,password)" / "无法解析 SSH 私钥"
  //    WebDAV: 401 / 403
  if (s.contains('logon failure') ||
      s.contains('status_logon') ||
      s.contains('0xc000006d') ||
      s.contains('authentication failed') ||
      s.contains('auth failed') ||
      s.contains('login failed') ||
      s.contains('login incorrect') ||
      s.contains('530 ') ||
      s.contains('permission denied') ||
      s.contains('access denied') ||
      s.contains('无法解析 ssh 私钥') ||
      s.contains('private key')) {
    return l10n.remote_err_auth;
  }

  // 3) 服务器返回明确状态码 → 带上状态码，或归并到认证/未找到
  final codeMatch = RegExp(r'(?:status\s*code[:\s]+)?(\d{3})').firstMatch(raw);
  if (codeMatch != null) {
    final code = codeMatch.group(1)!;
    final n = int.tryParse(code);
    if (n == 401 || n == 403 || n == 530) return l10n.remote_err_auth;
    if (n == 404) return l10n.remote_err_not_found;
    if (n != null && n >= 500 && n < 600) return l10n.remote_err_server(code);
  }

  // 4) 文件 / 文件夹不存在（含 WebDAV 404 not found、本地文件找不到）
  if (s.contains('not found')) return l10n.remote_err_not_found;

  // 5) 未连接 / 会话未建立
  if (s.contains('not connected') ||
      s.contains('session not established') ||
      s.contains('returned empty session id')) {
    return l10n.remote_err_not_connected;
  }

  // 5b) 连接/会话已被回收：切后台、网络切换、服务器空闲断开都会走到这里。
  //     这类错误不是认证或路径问题，重建连接即可恢复 —— 复用现成的
  //     「与服务器的连接已断开，正在尝试重新连接。」文案（[remote_err_reconnect]）。
  //     放在 6) 超时之前：JSch/smbj 的会话失效文案常同时含 "timed out"，
  //     但「连接没了」比「操作超时」更准确地描述用户遇到的情况。
  if (s.contains('session is down') ||
      s.contains('session not found') ||
      s.contains('session has been closed') ||
      s.contains('broken pipe') ||
      s.contains('connection reset') ||
      s.contains('connection closed') ||
      s.contains('connection aborted') ||
      s.contains('channel is closed') ||
      s.contains('channel not opened') ||
      s.contains('socketexception') ||
      s.contains('socket closed') ||
      s.contains('end of file') ||
      s.contains('pipe closed') ||
      s.contains('transport closed') ||
      s.contains('client is closed') ||
      s.contains('is closed')) {
    return l10n.remote_err_reconnect;
  }

  // 6) 超时
  if (s.contains('timed out') || s.contains('timeout')) {
    return l10n.remote_err_timeout;
  }

  // 7) 重连被限流 / 重连失败
  if (s.contains('reconnect throttled') || s.contains('reconnection failed')) {
    return l10n.remote_err_reconnect;
  }

  // 8) 连接类（地址 / 端口 / 网络 / 连接被关闭 / 重定向过多 / PASV 非法）
  if (s.contains('could not connect') ||
      s.contains('connection failed') ||
      s.contains('connect failed') ||
      s.contains('smb connect') ||
      s.contains('control connection closed') ||
      s.contains('too many redirects') ||
      s.contains('invalid pasv')) {
    return l10n.remote_err_connection;
  }

  // 9) 打开文件夹
  if (s.contains('cannot open directory') || s.contains('failed to open directory')) {
    return l10n.remote_err_dir_open;
  }

  // 10) 创建文件夹 / 文件
  if (s.contains('failed to create directory') ||
      s.contains('create directory') ||
      s.contains('folder create') ||
      s.contains('createfile')) {
    return l10n.remote_err_create_dir;
  }

  // 11) 重命名
  if (s.contains('failed to rename') || s.contains('rename')) {
    return l10n.remote_err_rename;
  }

  // 12) 删除
  if (s.contains('delete failed') ||
      s.contains('failed to delete') ||
      s.contains('delete timed out') ||
      s.contains('delete error')) {
    return l10n.remote_err_delete;
  }

  // 13) 下载（含中文 "下载" 系 SFTP 报错）
  if (s.contains('download failed') ||
      s.contains('download returned false') ||
      s.contains('downloadrange') ||
      s.contains('download range') ||
      s.contains('下载')) {
    return l10n.remote_err_download;
  }

  // 14) 上传（含中文 "上传"）
  if (s.contains('upload failed') ||
      s.contains('upload returned false') ||
      s.contains('upload timed out') ||
      s.contains('上传')) {
    return l10n.remote_err_upload;
  }

  // 15) 通用失败（兜底）
  if (s.contains('returned false') ||
      s.contains('failed after') ||
      s.contains('failed') ||
      s.contains('error')) {
    return l10n.remote_err_generic;
  }

  return l10n.remote_err_generic;
}
