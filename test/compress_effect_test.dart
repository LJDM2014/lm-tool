import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lm_tool/services/pdf_service.dart';
import 'package:pdf_manipulator/pdf_manipulator.dart';

// ── 最小 PNG 生成器（随机噪声 RGB 图，模拟照片型 PDF 中的大图）──

int _crc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final b in data) {
    crc ^= b;
    for (var i = 0; i < 8; i++) {
      crc = (crc >>> 1) ^ (0xEDB88320 * (crc & 1));
    }
  }
  return (~crc) & 0xFFFFFFFF;
}

Uint8List _chunk(String type, List<int> data) {
  final b = BytesBuilder();
  final len = ByteData(4)..setUint32(0, data.length);
  b.add(len.buffer.asUint8List());
  b.add(type.codeUnits);
  b.add(data);
  final crc = ByteData(4)
    ..setUint32(0, _crc32([...type.codeUnits, ...data]));
  b.add(crc.buffer.asUint8List());
  return b.takeBytes();
}

Uint8List makeNoisePng(int width, int height, int seed) {
  final ihdrBytes = Uint8List(13);
  ByteData.view(ihdrBytes.buffer)
    ..setUint32(0, width)
    ..setUint32(4, height);
  ihdrBytes[8] = 8; // bit depth
  ihdrBytes[9] = 2; // color type: RGB
  // 10-12: compression / filter / interlace = 0

  final rand = Random(seed);
  final raw = BytesBuilder();
  final row = Uint8List(width * 3 + 1);
  for (var y = 0; y < height; y++) {
    row[0] = 0; // filter: none
    for (var i = 1; i < row.length; i++) {
      row[i] = rand.nextInt(256);
    }
    raw.add(row);
  }
  final idat = ZLibEncoder(level: 1).convert(raw.takeBytes());

  final png = BytesBuilder()
    ..add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    ..add(_chunk('IHDR', ihdrBytes))
    ..add(_chunk('IDAT', idat))
    ..add(_chunk('IEND', const []));
  return png.takeBytes();
}

// ── 测试 ──

void main() {
  late Directory tempDir;
  late Pdf engine;
  late PdfService service;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('lmtool_compress');
    engine = Pdf();
    service = PdfService.instance;
  });

  tearDown(() async {
    await engine.dispose();
    await tempDir.delete(recursive: true);
  });

  test('压缩对已含 JPEG 的 PDF 生效（调优后）', () async {
    // 1. 造一个每页整版大图的 PDF（此时图片是无损 PNG 存储）
    final png = makeNoisePng(1600, 1200, 42);
    final builder = await engine.build();
    for (var i = 0; i < 2; i++) {
      final page = await builder.addA4Page();
      await page.image(
        MemorySource(png),
        const PdfRect(x: 0, y: 0, width: 595, height: 842),
      );
    }
    final sink = MemorySink();
    await builder.save(sink);
    await builder.dispose();
    final original = File('${tempDir.path}/src.pdf')
        ..writeAsBytesSync(sink.takeBytes());

    // 2. 第一遍默认 eBook 压缩：无损图 → JPEG，必然明显减小
    final j1 = await service.compress(original, PdfImagePolicy.ebook, tempDir);
    await j1.done;
    final size1 = j1.outputs.single.lengthSync();
    expect(size1, lessThan(original.lengthSync() ~/ 2));

    // 3. 第二遍默认 eBook 压缩：图片已是 JPEG，默认策略不再重编码
    //    —— 这就是“压缩没有效果”的根因。
    final j2 = await service.compress(
      j1.outputs.single,
      PdfImagePolicy.ebook,
      tempDir,
    );
    await j2.done;
    final size2 = j2.outputs.single.lengthSync();
    expect(size2, greaterThan(size1 * 0.9),
        reason: '默认策略对已存储 JPEG 应几乎无收益');

    // 4. 调优策略：重编码已有 JPEG + 收紧降采样阈值 → 应显著减小
    const tuned = PdfImagePolicy(
      colorPpi: 150,
      grayPpi: 150,
      monoPpi: 300,
      jpegQuality: 70,
      convertCmykToRgb: true,
      recompressJpeg: true,
      minSavings: 0,
      downsampleThreshold: 1.2,
    );
    final j3 = await service.compress(j1.outputs.single, tuned, tempDir);
    await j3.done;
    final size3 = j3.outputs.single.lengthSync();
    expect(size3, lessThan(size1 * 8 ~/ 10),
        reason: '调优策略应把 193ppi/q75 的 JPEG 降到 150ppi 再重编码');
    expect(await service.pageCount(j3.outputs.single), 2);
  });
}
