import 'package:flutter/foundation.dart';

/// 跨页面共享的全局设置。
class AppSettings {
  AppSettings._();

  /// 输出目录（null 表示未选择）。
  static final ValueNotifier<String?> outputDir = ValueNotifier<String?>(null);
}
