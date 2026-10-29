import 'dart:io';
import 'dart:typed_data';

import 'package:pdf_manipulator/pdf_manipulator.dart';

/// 用引擎自建一个 n 页的 PDF，返回字节。
Future<Uint8List> makePdf(Pdf pdf, int pages) async {
  final builder = await pdf.build();
  for (var i = 0; i < pages; i++) {
    final page = await builder.addA4Page();
    await page.paragraph('Page ${i + 1}');
  }
  final sink = MemorySink();
  await builder.save(sink);
  await builder.dispose();
  return sink.takeBytes();
}

/// 用引擎自建一个 PDF，每页写一行指定文本，返回字节。
Future<Uint8List> makeTextPdf(Pdf pdf, List<String> pageTexts) async {
  final builder = await pdf.build();
  for (final text in pageTexts) {
    final page = await builder.addA4Page();
    await page.paragraph(text);
  }
  final sink = MemorySink();
  await builder.save(sink);
  await builder.dispose();
  return sink.takeBytes();
}

/// 把字节写入 [dir] 下的 PDF 文件。
Future<File> writePdfBytes(Directory dir, String name, Uint8List bytes) async {
  final file = File('${dir.path}/$name');
  await file.writeAsBytes(bytes);
  return file;
}
