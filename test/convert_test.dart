import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lm_tool/services/pdf_service.dart';
import 'package:pdf_manipulator/pdf_manipulator.dart';

import 'pdf_test_utils.dart';

/// 1x1 红色 PNG（base64）。
const _png1x1Base64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

void main() {
  late Directory tempDir;
  late Pdf engine;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('lmtool_convert_test');
    engine = Pdf();
  });

  tearDown(() async {
    await engine.dispose();
    await tempDir.delete(recursive: true);
  });

  Future<File> writePng(String name) async {
    final file = File('${tempDir.path}/$name');
    await file.writeAsBytes(base64Decode(_png1x1Base64));
    return file;
  }

  group('imagesToPdf 图片转 PDF', () {
    test('每张图片一页，页数正确', () async {
      final outDir = Directory('${tempDir.path}/out');
      await outDir.create();
      final a = await writePng('a.png');
      final b = await writePng('b.png');

      final job = await PdfService.instance.imagesToPdf([a, b], outDir);
      await job.done;

      final out = job.outputs.single;
      expect(out.existsSync(), isTrue);
      expect(out.path.endsWith('.pdf'), isTrue);
      expect(await PdfService.instance.pageCount(out), 2);
    });
  });

  group('pdfToImages PDF 转图片', () {
    late File pdf;
    late Directory outDir;

    setUp(() async {
      outDir = Directory('${tempDir.path}/out');
      await outDir.create();
      pdf = await writePdfBytes(tempDir, 'doc.pdf', await makePdf(engine, 3));
    });

    test('全部页导出，逐页产出 PNG', () async {
      final job = await PdfService.instance.pdfToImages(pdf, outDir);
      final outputs = await job.done;

      expect(outputs, hasLength(3));
      for (final f in outputs) {
        expect(f.existsSync(), isTrue);
        expect(f.path.toLowerCase().endsWith('.png'), isTrue);
        expect(f.lengthSync(), greaterThan(0));
      }
      // 文件名带页序号。
      expect(outputs[0].path.contains('页001'), isTrue);
      expect(outputs[2].path.contains('页003'), isTrue);
    });

    test('指定页码只导出所选页', () async {
      final job = await PdfService.instance.pdfToImages(
        pdf,
        outDir,
        pages: [0, 2],
      );
      final outputs = await job.done;

      expect(outputs, hasLength(2));
      expect(outputs[0].path.contains('页001'), isTrue);
      expect(outputs[1].path.contains('页002'), isTrue);
    });

    test('取消后抛 PdfCancelled 且清理已写出文件', () async {
      final job = await PdfService.instance.pdfToImages(pdf, outDir);
      job.cancel();
      await expectLater(job.done, throwsA(isA<PdfCancelled>()));
      expect(outDir.listSync(), isEmpty);
    });
  });

  group('parsePageRanges 页码解析', () {
    test('解析范围与单页，输出升序去重', () {
      expect(parsePageRanges('1-3,5', 10), [0, 1, 2, 4]);
      expect(parsePageRanges('5，2', 10), [1, 4]);
      expect(parsePageRanges('3', 10), [2]);
    });

    test('非法输入返回 null', () {
      expect(parsePageRanges('abc', 10), isNull);
      expect(parsePageRanges('0', 10), isNull);
      expect(parsePageRanges('3-1', 10), isNull);
      expect(parsePageRanges('11', 10), isNull);
      expect(parsePageRanges('', 10), isNull);
    });
  });
}
