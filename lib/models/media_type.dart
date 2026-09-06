/// 全局媒体类别枚举，被 [MediaCategoryScreen] 与 [MediaCategorySettingsScreen]
/// 等多处共同依赖。为避免文件间循环依赖，单独提取到 lib/models/ 下。
enum MediaType {
  images,
  videos,
  audios,
  documents,
  archives,
  downloads,
  apks,
  screenshots,
}
