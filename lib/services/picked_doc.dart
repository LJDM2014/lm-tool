import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';

/// 统一的文件选择结果：文件名 + 来源文件 / 可选的即时字节。
///
/// [xFile] 为来源文件（桌面与 Web 拖入均有；内容按需读取）；
/// [bytes] 为已读入内存的内容（Web 端选择文件时即读入）。
class PickedDoc {
  const PickedDoc({
    required this.name,
    this.xFile,
    this.bytes,
    this.path,
    this.size,
  });

  /// 文件名（不含路径）。
  final String name;

  /// 来源文件（内容按需通过平台层读取）。
  final XFile? xFile;

  /// 已读入内存的内容字节（优先于 [xFile] 使用）。
  final Uint8List? bytes;

  /// 本地路径（仅桌面端，可能为 null）。
  final String? path;

  /// 文件大小（字节），未知时为 null。
  final int? size;
}
