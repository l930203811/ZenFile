import 'preferences_service.dart';

/// Google Drive 文件信息。
class GDriveFile {
  final String id;
  final String name;
  final String? mimeType;
  final int? size;
  final String? modifiedTime;
  final bool isFolder;

  const GDriveFile({
    required this.id,
    required this.name,
    this.mimeType,
    this.size,
    this.modifiedTime,
    this.isFolder = false,
  });
}

/// Google Drive 集成服务（基础框架）。
///
/// 完整实现需要：
/// 1. google_sign_in 包进行 OAuth2 认证
/// 2. googleapis 包调用 Drive API v3
/// 3. 实现文件列表、上传、下载、删除等操作
///
/// 当前版本提供基础结构和占位方法，待后续集成完整 OAuth 流程。
class GoogleDriveService {
  /// 检查是否已登录 Google 账号。
  static bool isSignedIn() {
    return PreferencesService.getGoogleDriveAccessToken() != null;
  }

  /// 获取存储的访问令牌。
  static String? getAccessToken() {
    return PreferencesService.getGoogleDriveAccessToken();
  }

  /// 保存访问令牌。
  static Future<void> saveTokens({
    required String accessToken,
    String? refreshToken,
  }) async {
    await PreferencesService.saveGoogleDriveAccessToken(accessToken);
    if (refreshToken != null) {
      await PreferencesService.saveGoogleDriveRefreshToken(refreshToken);
    }
  }

  /// 清除登录状态。
  static Future<void> signOut() async {
    await PreferencesService.saveGoogleDriveAccessToken('');
    await PreferencesService.saveGoogleDriveRefreshToken('');
  }

  /// 列出指定文件夹中的文件。
  /// [folderId] 文件夹 ID，null 表示根目录。
  static Future<List<GDriveFile>> listFiles({String? folderId}) async {
    if (!isSignedIn()) {
      throw Exception('请先登录 Google 账号');
    }
    // TODO: 实现 Google Drive API v3 调用
    // GET https://www.googleapis.com/drive/v3/files?q='${folderId}'+in+parents
    return [];
  }

  /// 上传文件到 Google Drive。
  /// [localPath] 本地文件路径
  /// [folderId] 目标文件夹 ID，null 表示根目录
  static Future<GDriveFile?> uploadFile(
    String localPath, {
    String? folderId,
    Function(int uploaded, int total)? onProgress,
  }) async {
    if (!isSignedIn()) {
      throw Exception('请先登录 Google 账号');
    }
    // TODO: 实现分块上传
    // POST https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable
    return null;
  }

  /// 下载文件从 Google Drive。
  /// [fileId] Google Drive 文件 ID
  /// [localPath] 本地保存路径
  static Future<String?> downloadFile(
    String fileId,
    String localPath, {
    Function(int downloaded, int total)? onProgress,
  }) async {
    if (!isSignedIn()) {
      throw Exception('请先登录 Google 账号');
    }
    // TODO: 实现文件下载
    // GET https://www.googleapis.com/drive/v3/files/${fileId}?alt=media
    return null;
  }

  /// 删除 Google Drive 文件。
  static Future<bool> deleteFile(String fileId) async {
    if (!isSignedIn()) return false;
    // TODO: 实现文件删除
    // DELETE https://www.googleapis.com/drive/v3/files/${fileId}
    return false;
  }

  /// 创建文件夹。
  static Future<GDriveFile?> createFolder(String name, {String? parentFolderId}) async {
    if (!isSignedIn()) return null;
    // TODO: 实现文件夹创建
    return null;
  }

  /// 获取存储空间使用情况。
  static Future<Map<String, int>?> getStorageQuota() async {
    if (!isSignedIn()) return null;
    // TODO: 实现配额查询
    // GET https://www.googleapis.com/drive/v3/about?fields=storageQuota
    return null;
  }
}
