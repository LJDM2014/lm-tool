/// 平台 I/O 抽象层：文件选择、拖入转换、输出保存与下载。
///
/// 页面代码只依赖本库导出的平台无关 API；桌面与 Web 的差异
/// 分别由 platform_io_desktop.dart / platform_io_web.dart 实现。
library;

export 'picked_doc.dart';
export 'platform_io_desktop.dart' if (dart.library.js_interop) 'platform_io_web.dart';
