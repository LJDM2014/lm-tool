import 'dart:io';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:open_filex/open_filex.dart';

import 'app_settings.dart';
import 'pdf_core.dart';
import 'picked_doc.dart';

/// 当前平台是否有本地文件系统（桌面为 true，Web 为 false）。
bool get hasFileSystem => true;

/// 选择文件（[multi] 为 true 时可多选），按 [extensions] 过滤。
Future<List<PickedDoc>> pickDocs({
  required List<String> extensions,
  bool multi = false,
}) async {
  if (multi) {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: extensions,
    );
    return [
      for (final pf in files)
        PickedDoc(
          name: pf.name,
          xFile: pf.xFile,
          path: pf.path,
          size: pf.lengthSync(),
        ),
    ];
  }
  final pf = await FilePicker.pickFile(
    type: FileType.custom,
    allowedExtensions: extensions,
  );
  if (pf == null) return const [];
  return [
    PickedDoc(name: pf.name, xFile: pf.xFile, path: pf.path, size: pf.lengthSync()),
  ];
}

/// 把拖入窗口的文件转换为 [PickedDoc]（按扩展名过滤，保序）。
/// 桌面端文件在磁盘上，大小直接读取。
Future<List<PickedDoc>> docsFromDrop(
  List<XFile> files,
  List<String> extensions,
) async {
  final allowed = extensions.map((e) => e.toLowerCase()).toSet();
  return [
    for (final f in files)
      if (allowed.contains(f.name.toLowerCase().split('.').last))
        PickedDoc(name: f.name, xFile: f, path: f.path, size: _safeLength(f.path)),
  ];
}

int? _safeLength(String? path) {
  if (path == null) return null;
  try {
    return File(path).lengthSync();
  } catch (_) {
    return null;
  }
}

/// 读取文档内容字节（桌面端从来源文件读取）。
Future<Uint8List> docBytes(PickedDoc doc) async {
  final bytes = doc.bytes;
  if (bytes != null) return bytes;
  final xFile = doc.xFile;
  if (xFile != null) return xFile.readAsBytes();
  final path = doc.path;
  if (path == null) {
    throw StateError('文档缺少内容来源：${doc.name}');
  }
  return File(path).readAsBytes();
}

/// 把文档转换为引擎输入（读取字节）。
Future<PdfInput> pdfInputOf(PickedDoc doc) async =>
    PdfInput(doc.name, await docBytes(doc));

/// 把任务输出写入当前输出目录（输出文件名由任务生成，带时间戳）。
/// 未选择输出目录时抛出异常，由调用方提示。
Future<void> saveOutputs(List<PdfOutput> outputs) async {
  final dirPath = AppSettings.outputDir.value;
  if (dirPath == null) {
    throw StateError('请先选择输出目录');
  }
  for (final o in outputs) {
    await File('$dirPath/${o.name}').writeAsBytes(o.bytes);
  }
}

/// 选择输出目录（仅桌面有目录概念）。
Future<String?> pickOutputDirectory() async =>
    FilePicker.getDirectoryPath(dialogTitle: '选择输出目录');

/// 打开输出所在文件夹；未选择输出目录或打开失败时返回 false。
Future<bool> openOutputFolder() async {
  final dirPath = AppSettings.outputDir.value;
  if (dirPath == null) return false;
  final result = await OpenFilex.open(dirPath);
  return result.type == ResultType.done;
}

/// Web 专用：触发浏览器下载（桌面端为空操作）。
void downloadOutput(PdfOutput output) {}
