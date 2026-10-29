import 'dart:io';
import 'dart:typed_data';

import 'package:lm_tool/services/pdf_service.dart';
import 'package:pdf_manipulator/pdf_manipulator.dart';
import 'package:flutter_test/flutter_test.dart';

import 'pdf_test_utils.dart';

void main() {
  late Directory tempDir;
  late Pdf engine;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('lmtool_test');
    engine = Pdf();
  });

  tearDown(() async {
    await engine.dispose();
    await tempDir.delete(recursive: true);
  });

  Future<File> writePdf(String name, Uint8List bytes) async {
    final file = File('${tempDir.path}/$name');
    await file.writeAsBytes(bytes);
    return file;
  }

  test('pageCount 读取页数', () async {
    final a = await writePdf('a.pdf', await makePdf(engine, 3));
    expect(await PdfService.instance.pageCount(a), 3);
  });

  test('merge 合并多个 PDF', () async {
    final a = await writePdf('a.pdf', await makePdf(engine, 3));
    final b = await writePdf('b.pdf', await makePdf(engine, 2));

    final job = await PdfService.instance.merge([a, b], tempDir);
    await job.done;

    final out = job.outputs.single;
    expect(out.existsSync(), isTrue);
    expect(await PdfService.instance.pageCount(out), 5);
  });

  test('splitEvery 按页数拆分', () async {
    final a = await writePdf('a.pdf', await makePdf(engine, 5));

    final job = await PdfService.instance.splitEvery(a, 2, tempDir);
    await job.done;

    final outputs = job.outputs;
    expect(outputs.length, 3); // 2 + 2 + 1
    final counts = [
      for (final f in outputs) await PdfService.instance.pageCount(f),
    ];
    expect(counts, [2, 2, 1]);
  });

  test('extractPages 提取指定页面', () async {
    final a = await writePdf('a.pdf', await makePdf(engine, 4));

    final job = await PdfService.instance.extractPages(
      a,
      [0, 2],
      tempDir,
    );
    await job.done;

    expect(await PdfService.instance.pageCount(job.outputs.single), 2);
  });

  test('compress 压缩并产出有效 PDF', () async {
    final a = await writePdf('a.pdf', await makePdf(engine, 3));

    final job = await PdfService.instance.compress(
      a,
      PdfImagePolicy.screen,
      tempDir,
    );
    await job.done;

    final out = job.outputs.single;
    expect(out.existsSync(), isTrue);
    expect(out.lengthSync(), greaterThan(0));
    expect(await PdfService.instance.pageCount(out), 3);
  });

  test('cancel 取消任务并清理半成品', () async {
    final a = await writePdf('a.pdf', await makePdf(engine, 30));

    final job = await PdfService.instance.splitEvery(a, 1, tempDir);
    job.cancel();
    await expectLater(job.done, throwsA(isA<PdfCancelled>()));
    for (final f in job.outputs) {
      expect(f.existsSync(), isFalse, reason: '${f.path} 应被清理');
    }
  });

  test('重复运行输出名唯一，失败清理不影响历史结果', () async {
    final a = await writePdf('a.pdf', await makePdf(engine, 2));

    final j1 = await PdfService.instance.compress(
      a,
      PdfImagePolicy.lossless,
      tempDir,
    );
    await j1.done;
    final first = j1.outputs.single;
    expect(first.existsSync(), isTrue);

    final j2 = await PdfService.instance.compress(
      a,
      PdfImagePolicy.lossless,
      tempDir,
    );
    await j2.done;
    final second = j2.outputs.single;
    expect(second.path, isNot(first.path), reason: '输出文件名应唯一');
    expect(first.existsSync(), isTrue, reason: '第二次运行不得覆盖第一次的输出');

    // 第三次运行取消后，只清理自己的输出，不波及前两次结果
    final j3 = await PdfService.instance.compress(
      a,
      PdfImagePolicy.lossless,
      tempDir,
    );
    j3.cancel();
    await expectLater(j3.done, throwsA(isA<PdfCancelled>()));
    expect(first.existsSync(), isTrue);
    expect(second.existsSync(), isTrue);
  });
}
