import 'dart:io';

import 'package:pdf_manipulator/io.dart';
import 'package:pdf_manipulator/pdf_manipulator.dart';

/// 一次可取消的 PDF 任务。
///
/// 通过 [cancel] 请求取消；[done] 返回最终结果。取消或失败时，
/// 会关闭输出文件句柄并删除半成品文件。
class PdfJob<T> {
  PdfJob._(this.task, this._outputs, this._sinks);

  final PdfTask<T> task;
  final List<File> _outputs;
  final List<FileSink> _sinks;

  /// 本任务成功完成后会产生的输出文件。
  List<File> get outputs => List.unmodifiable(_outputs);

  /// 请求取消（幂等；任务已结束时为空操作）。
  void cancel() => task.cancel();

  /// 等待任务结束。取消时抛出 [PdfCancelled]，失败时抛出引擎异常；
  /// 两种情况下都会清理本次任务的半成品输出（每次任务输出文件名唯一，
  /// 因此清理不会波及历史结果）。任务成功后即使关闭句柄出错，
  /// 也返回成功、不删除已写完的文件。
  Future<T> get done async {
    try {
      final result = await task;
      try {
        await _closeSinks();
      } catch (_) {
        // 引擎已完成写入；flush/close 失败（常见于杀软占用句柄）
        // 不应把成功的任务变成失败并误删输出。
      }
      return result;
    } on Object {
      await _closeSinks();
      for (final f in _outputs) {
        try {
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
      rethrow;
    }
  }

  Future<void> _closeSinks() async {
    for (final s in _sinks) {
      try {
        await s.close();
      } catch (_) {}
    }
  }
}

/// PDF 操作服务：合并、拆分、提取、压缩。基于 pdf_manipulator（Rust 引擎），
/// 所有操作均在后台线程执行，返回的 [PdfJob] 支持取消。
class PdfService {
  PdfService._();

  static final instance = PdfService._();

  Pdf? _engine;
  Pdf get _pdf => _engine ??= Pdf();

  /// 读取 PDF 页数。
  Future<int> pageCount(File file) async {
    final doc = await _pdf.open(FileSource(file));
    try {
      return doc.pageCount;
    } finally {
      await doc.dispose();
    }
  }

  /// 合并多个 PDF 到 [outDir]，返回任务（输出文件名自动带时间戳）。
  Future<PdfJob<void>> merge(List<File> inputs, Directory outDir) async {
    final output = File('${outDir.path}/merged-${_timestamp()}.pdf');
    final sink = await FileSink.create(output);
    final task = _pdf.merge([for (final f in inputs) FileSource(f)], sink);
    return PdfJob._(task, [output], [sink]);
  }

  /// 按每份 [every] 页拆分 [input]，输出到 [outDir]。
  Future<PdfJob<void>> splitEvery(
    File input,
    int every,
    Directory outDir,
  ) async {
    final total = await pageCount(input);
    final count = (total / every).ceil();
    final base = _stem(input);
    final ts = _timestamp();
    final outputs = <File>[];
    final sinks = <FileSink>[];
    for (var i = 0; i < count; i++) {
      final part = (i + 1).toString().padLeft(2, '0');
      final file = File('${outDir.path}/$base-$ts-part$part.pdf');
      outputs.add(file);
      sinks.add(await FileSink.create(file));
    }
    final task = _pdf.split(
      FileSource(input),
      (index) => sinks[index],
      every: every,
    );
    return PdfJob._(task, outputs, sinks);
  }

  /// 提取 [pages]（0 起始页码）为单独文件，输出到 [outDir]。
  Future<PdfJob<void>> extractPages(
    File input,
    List<int> pages,
    Directory outDir, {
    String? nameSuffix,
  }) async {
    final suffix = nameSuffix ?? 'extract';
    final output =
        File('${outDir.path}/${_stem(input)}-$suffix-${_timestamp()}.pdf');
    final sink = await FileSink.create(output);
    final task = _pdf.extractPages(FileSource(input), sink, pages: pages);
    return PdfJob._(task, [output], [sink]);
  }

  /// 按 [policy] 压缩 [input]，输出到 [outDir]。
  Future<PdfJob<void>> compress(
    File input,
    PdfImagePolicy policy,
    Directory outDir,
  ) async {
    final output =
        File('${outDir.path}/${_stem(input)}-compressed-${_timestamp()}.pdf');
    final sink = await FileSink.create(output);
    final task = _pdf.compress(FileSource(input), sink, images: policy);
    return PdfJob._(task, [output], [sink]);
  }

  /// 输出文件名用的时间戳（精确到毫秒），保证多次运行互不覆盖。
  static String _timestamp() {
    final t = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}'
        '-${two(t.hour)}${two(t.minute)}${two(t.second)}'
        '-${t.millisecond.toString().padLeft(3, '0')}';
  }

  static String _stem(File f) {
    final name = f.uri.pathSegments.last;
    final dot = name.lastIndexOf('.');
    return dot <= 0 ? name : name.substring(0, dot);
  }
}
