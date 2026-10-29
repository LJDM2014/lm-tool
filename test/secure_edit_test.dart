import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lm_tool/services/pdf_service.dart';
import 'package:pdf_manipulator/io.dart';
import 'package:pdf_manipulator/pdf_manipulator.dart';

import 'pdf_test_utils.dart';

void main() {
  late Directory tempDir;
  late Pdf engine;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('lmtool_secure_test');
    engine = Pdf();
  });

  tearDown(() async {
    await engine.dispose();
    await tempDir.delete(recursive: true);
  });

  Future<File> makeInput(int pages) async =>
      writePdfBytes(tempDir, 'in.pdf', await makePdf(engine, pages));

  group('加密 / 解密', () {
    test('设置打开密码后需密码访问，解密副本无需密码', () async {
      final outDir = Directory('${tempDir.path}/out');
      await outDir.create();
      final input = await makeInput(2);

      // 加密（打开密码 + 权限密码）。
      final enc = await PdfService.instance.encrypt(
        input,
        outDir,
        ownerPassword: 'owner-secret',
        userPassword: 'user-secret',
      );
      await enc.done;
      final encrypted = enc.outputs.single;
      expect(encrypted.existsSync(), isTrue);

      // 无密码无法读取。
      await expectLater(
        PdfService.instance.pageCount(encrypted),
        throwsA(anything),
      );
      // 有密码可读取（requiresPassword 表示"当前凭据下是否还缺密码"）。
      final info = await PdfService.instance.pdfInfo(
        encrypted,
        password: 'user-secret',
      );
      expect(info.isEncrypted, isTrue);
      expect(info.pageCount, 2);

      // 解密副本无需密码。
      final dec = await PdfService.instance.decrypt(
        encrypted,
        'user-secret',
        outDir,
      );
      await dec.done;
      final decrypted = dec.outputs.single;
      expect(decrypted.existsSync(), isTrue);
      final info2 = await PdfService.instance.pdfInfo(decrypted);
      expect(info2.isEncrypted, isFalse);
      expect(info2.requiresPassword, isFalse);
      expect(info2.pageCount, 2);
    });

    test('仅权限密码时无需打开密码，权限被限制', () async {
      final outDir = Directory('${tempDir.path}/out');
      await outDir.create();
      final input = await makeInput(1);

      final job = await PdfService.instance.encrypt(
        input,
        outDir,
        ownerPassword: 'owner-only',
        permissions: const PdfPermissions(
          print: false,
          printHq: false,
          copy: false,
          modify: false,
          annotate: false,
          fillForms: true,
          accessibility: true,
          assemble: false,
        ),
      );
      await job.done;

      final info = await PdfService.instance.pdfInfo(job.outputs.single);
      expect(info.isEncrypted, isTrue);
      expect(info.requiresPassword, isFalse);
      expect(info.permissions?.copy, isFalse);
    });
  });

  group('可视化页面编辑', () {
    late Directory outDir;

    setUp(() async {
      outDir = Directory('${tempDir.path}/out');
      await outDir.create();
    });

    test('selectPages 按给定顺序保留页面（重排）', () async {
      final input = await makeInput(3);
      final session = await PdfService.instance.openEditor(input);
      try {
        expect(session.pageCount, 3);
        final job = await session.save(outDir, order: [2, 0, 1], rotations: {});
        await job.done;

        final out = job.outputs.single;
        expect(out.existsSync(), isTrue);
        expect(await PdfService.instance.pageCount(out), 3);

        final doc = await engine.open(FileSource(out));
        try {
          final text = await doc.extract(pages: const PdfPages.all());
          final p3 = text.indexOf('Page 3');
          final p1 = text.indexOf('Page 1');
          final p2 = text.indexOf('Page 2');
          expect(p3, greaterThanOrEqualTo(0));
          expect(p1, greaterThan(p3));
          expect(p2, greaterThan(p1));
        } finally {
          await doc.dispose();
        }
      } finally {
        await session.dispose();
      }
    });

    test('删除页面后页数减少', () async {
      final input = await makeInput(3);
      final session = await PdfService.instance.openEditor(input);
      try {
        final job = await session.save(outDir, order: [0, 2], rotations: {});
        await job.done;
        expect(await PdfService.instance.pageCount(job.outputs.single), 2);
      } finally {
        await session.dispose();
      }
    });

    test('旋转页面后渲染位图方向改变', () async {
      final input = await makeInput(1);
      final session = await PdfService.instance.openEditor(input);
      try {
        final job =
            await session.save(outDir, order: [0], rotations: {0: 90});
        await job.done;

        final doc = await engine.open(FileSource(job.outputs.single));
        try {
          final rendered =
              await doc.render(pages: const PdfPages.single(0)).first;
          // A4 纵向页面旋转 90° 后变为横向。
          expect(rendered.width, greaterThan(rendered.height));
        } finally {
          await doc.dispose();
        }
      } finally {
        await session.dispose();
      }
    });

    test('缩略图流产出与页数一致', () async {
      final input = await makeInput(3);
      final session = await PdfService.instance.openEditor(input);
      try {
        final thumbs = await session.thumbnails().toList();
        expect(thumbs, hasLength(3));
        for (final t in thumbs) {
          expect(t.data, isNotEmpty);
        }
      } finally {
        await session.dispose();
      }
    });
  });
}
