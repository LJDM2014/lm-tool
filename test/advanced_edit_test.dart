import 'dart:io';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lm_tool/services/pdf_service.dart';
import 'package:pdf_manipulator/io.dart';
import 'package:pdf_manipulator/pdf_manipulator.dart';

import 'pdf_test_utils.dart';

void main() {
  late Directory tempDir;
  late Pdf engine;
  late Directory outDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('lmtool_adv_test');
    engine = Pdf();
    outDir = Directory('${tempDir.path}/out');
    await outDir.create();
  });

  tearDown(() async {
    await engine.dispose();
    // Windows 上引擎 worker 释放文件句柄可能略有延迟，删除前稍作重试。
    for (var i = 0; i < 5; i++) {
      try {
        await tempDir.delete(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    await tempDir.delete(recursive: true);
  });

  group('元数据编辑', () {
    test('保存后标题与作者可读回', () async {
      final input =
          await writePdfBytes(tempDir, 'in.pdf', await makePdf(engine, 1));
      final session = await PdfService.instance.openEditor(input);
      try {
        final job = await session.save(
          outDir,
          order: [0],
          rotations: {},
          title: '测试标题',
          author: '张三',
          subject: '测试主题',
          keywords: 'a, b',
        );
        await job.done;

        final doc = await engine.open(FileSource(job.outputs.single));
        try {
          expect(doc.title, '测试标题');
          expect(doc.author, '张三');
          expect(doc.subject, '测试主题');
          expect(doc.keywords, 'a, b');
        } finally {
          await doc.dispose();
        }
      } finally {
        await session.dispose();
      }
    });
  });

  group('文字水印', () {
    test('居中与平铺水印写入页面内容', () async {
      final input =
          await writePdfBytes(tempDir, 'in.pdf', await makePdf(engine, 2));
      final session = await PdfService.instance.openEditor(input);
      try {
        final job = await session.save(
          outDir,
          order: [0, 1],
          rotations: {},
          watermarkText: '机密文件',
          watermarkPosition: const PdfWatermarkPosition.tiled(
            columns: 3,
            rows: 3,
          ),
          watermarkStyle: const PdfWatermarkStyle(opacity: 0.5),
        );
        await job.done;

        final doc = await engine.open(FileSource(job.outputs.single));
        try {
          expect(doc.pageCount, 2);
        } finally {
          await doc.dispose();
        }

        // 水印为前景图层（非文本流），用渲染位图对比验证：
        // 加水印后的页面位图应与原始页面不同。
        Future<Uint8List> renderFirstPage(File file) async {
          final d = await engine.open(FileSource(file));
          try {
            final page = await d
                .render(
                  pages: const PdfPages.single(0),
                  size: const PdfRenderSize(maxWidth: 400, maxHeight: 1600),
                )
                .first;
            return page.data;
          } finally {
            await d.dispose();
          }
        }

        final before = await renderFirstPage(input);
        final after = await renderFirstPage(job.outputs.single);
        expect(listEquals(after, before), isFalse);
      } finally {
        await session.dispose();
      }
    });
  });

  group('内容擦除', () {
    test('擦除区域内的文字被移除', () async {
      final input =
          await writePdfBytes(tempDir, 'in.pdf', await makePdf(engine, 1));
      final session = await PdfService.instance.openEditor(input);
      try {
        // 擦除几乎整页（归一化，左上原点）。
        final job = await session.save(
          outDir,
          order: [0],
          rotations: {},
          erases: {
            0: [const Rect.fromLTRB(0.02, 0.02, 0.98, 0.98)],
          },
        );
        await job.done;

        final doc = await engine.open(FileSource(job.outputs.single));
        try {
          final text = await doc.extract(pages: const PdfPages.all());
          expect(text, isNot(contains('Page 1')));
        } finally {
          await doc.dispose();
        }
      } finally {
        await session.dispose();
      }
    });
  });

  group('插入其他 PDF 页面', () {
    test('追加后总页数增加，且可交错重排', () async {
      final main =
          await writePdfBytes(tempDir, 'main.pdf', await makePdf(engine, 2));
      final external = await writePdfBytes(
        tempDir,
        'ext.pdf',
        await makeTextPdf(engine, ['Ext A', 'Ext B']),
      );

      final session = await PdfService.instance.openEditor(main);
      try {
        // 预览外部页（获取缩略图与页数）。
        final preview = await session.loadInsertPreview(external);
        expect(preview.pageCount, 2);

        // 交错顺序：主1、外1、主2、外2（外页索引 = 2, 3）。
        final job = await session.save(
          outDir,
          order: [0, 2, 1, 3],
          rotations: {},
          mergeSource: external,
        );
        await job.done;

        final out = job.outputs.single;
        expect(await PdfService.instance.pageCount(out), 4);

        final doc = await engine.open(FileSource(out));
        try {
          final text = await doc.extract(pages: const PdfPages.all());
          final main1 = text.indexOf('Page 1');
          final extA = text.indexOf('Ext A');
          final main2 = text.indexOf('Page 2');
          final extB = text.indexOf('Ext B');
          // 交错顺序：主1 < 外1 < 主2 < 外2。
          expect(main1, greaterThanOrEqualTo(0));
          expect(extA, greaterThan(main1));
          expect(main2, greaterThan(extA));
          expect(extB, greaterThan(main2));
        } finally {
          await doc.dispose();
        }
      } finally {
        await session.dispose();
      }
    });

    test('仅插入外部 PDF 的部分页面', () async {
      final main =
          await writePdfBytes(tempDir, 'main.pdf', await makePdf(engine, 1));
      final external = await writePdfBytes(
        tempDir,
        'ext.pdf',
        await makeTextPdf(engine, ['Ext 1', 'Ext 2', 'Ext 3']),
      );

      final session = await PdfService.instance.openEditor(main);
      try {
        // 追加 2 页后文档共 3 页（主1=0，外2=1，外3=2）。
        // 交错顺序：外2、主1、外3。
        final job = await session.save(
          outDir,
          order: [1, 0, 2],
          rotations: {},
          mergeSource: external,
          mergePages: [1, 2], // 0 起始：外部第 2、3 页
        );
        await job.done;

        expect(await PdfService.instance.pageCount(job.outputs.single), 3);
        final doc = await engine.open(FileSource(job.outputs.single));
        try {
          final text = await doc.extract(pages: const PdfPages.all());
          final ext2 = text.indexOf('Ext 2');
          final main1 = text.indexOf('Page 1');
          final ext3 = text.indexOf('Ext 3');
          expect(ext2, greaterThanOrEqualTo(0));
          expect(main1, greaterThan(ext2));
          expect(ext3, greaterThan(main1));
          expect(text, isNot(contains('Ext 1')));
        } finally {
          await doc.dispose();
        }
      } finally {
        await session.dispose();
      }
    });
  });
}
