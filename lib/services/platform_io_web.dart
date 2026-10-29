import 'dart:js_interop';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:web/web.dart' as web;

import 'pdf_core.dart';
import 'picked_doc.dart';

/// 当前平台是否有本地文件系统（桌面为 true，Web 为 false）。
bool get hasFileSystem => false;

/// 选择文件（[multi] 为 true 时可多选），按 [extensions] 过滤。
/// Web 端选择即把内容读入内存。
Future<List<PickedDoc>> pickDocs({
  required List<String> extensions,
  bool multi = false,
}) async {
  if (multi) {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: extensions,
    );
    final result = <PickedDoc>[];
    for (final pf in files) {
      final bytes = await pf.readAsBytes();
      result.add(
        PickedDoc(name: pf.name, xFile: pf.xFile, bytes: bytes, size: bytes.length),
      );
    }
    return result;
  }
  final pf = await FilePicker.pickFile(
    type: FileType.custom,
    allowedExtensions: extensions,
  );
  if (pf == null) return const [];
  final bytes = await pf.readAsBytes();
  return [
    PickedDoc(name: pf.name, xFile: pf.xFile, bytes: bytes, size: bytes.length),
  ];
}

/// 把拖入窗口的文件转换为 [PickedDoc]（按扩展名过滤，保序）。
/// Web 端通过读取拖入文件内容获得字节与大小。
Future<List<PickedDoc>> docsFromDrop(
  List<XFile> files,
  List<String> extensions,
) async {
  final allowed = extensions.map((e) => e.toLowerCase()).toSet();
  final result = <PickedDoc>[];
  for (final f in files) {
    if (!allowed.contains(f.name.toLowerCase().split('.').last)) continue;
    final bytes = await f.readAsBytes();
    result.add(
      PickedDoc(name: f.name, xFile: f, bytes: bytes, size: bytes.length),
    );
  }
  return result;
}

/// 读取文档内容字节（Web 端选择/拖入时即已读入）。
Future<Uint8List> docBytes(PickedDoc doc) async {
  final bytes = doc.bytes;
  if (bytes != null) return bytes;
  final xFile = doc.xFile;
  if (xFile != null) return xFile.readAsBytes();
  throw StateError('文档缺少内容字节：${doc.name}');
}

/// 把文档转换为引擎输入。
Future<PdfInput> pdfInputOf(PickedDoc doc) async =>
    PdfInput(doc.name, await docBytes(doc));

/// Web 端没有输出目录：输出保留在内存中，由用户在结果里点击下载。
Future<void> saveOutputs(List<PdfOutput> outputs) async {}

/// Web 端没有"打开输出文件夹"概念。
Future<bool> openOutputFolder() async => false;

/// Web 端没有输出目录概念。
Future<String?> pickOutputDirectory() async => null;

/// 触发浏览器把 [output] 下载为本地文件。
void downloadOutput(PdfOutput output) {
  final blob = web.Blob([output.bytes.toJS].toJS);
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement();
  anchor.href = url;
  anchor.download = output.name;
  web.document.body!.appendChild(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
}
