import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:pdf_manipulator/pdf_manipulator.dart';

import 'pdf_core.dart';

/// 桌面文件门面：File 进、文件出（写入指定目录），内部全部委托
/// [PdfCore] 字节核心。仅桌面平台与测试使用；Web 构建不会导入本库。
class PdfService {
  PdfService._();

  static final instance = PdfService._();

  /// 读取 PDF 页数。
  Future<int> pageCount(File file, {String? password}) async =>
      PdfCore.instance.pageCount(await _input(file), password: password);

  /// 读取 PDF 概要信息（页数与加密状态）。
  Future<PdfDocInfo> pdfInfo(File file, {String? password}) async =>
      PdfCore.instance.pdfInfo(await _input(file), password: password);

  /// 合并多个 PDF 到 [outDir]，返回任务（输出文件名自动带时间戳）。
  Future<PdfFileJob> merge(List<File> inputs, Directory outDir) async {
    final job = await PdfCore.instance
        .merge([for (final f in inputs) await _input(f)]);
    return _wrap(job, outDir);
  }

  /// 按每份 [every] 页拆分 [input]，输出到 [outDir]。
  Future<PdfFileJob> splitEvery(
    File input,
    int every,
    Directory outDir,
  ) async {
    final job = await PdfCore.instance.splitEvery(await _input(input), every);
    return _wrap(job, outDir);
  }

  /// 提取 [pages]（0 起始页码）为单独文件，输出到 [outDir]。
  Future<PdfFileJob> extractPages(
    File input,
    List<int> pages,
    Directory outDir, {
    String? nameSuffix,
  }) async {
    final job = await PdfCore.instance.extractPages(
      await _input(input),
      pages,
      nameSuffix: nameSuffix,
    );
    return _wrap(job, outDir);
  }

  /// 按 [policy] 压缩 [input]，输出到 [outDir]。
  Future<PdfFileJob> compress(
    File input,
    PdfImagePolicy policy,
    Directory outDir,
  ) async {
    final job =
        await PdfCore.instance.compress(await _input(input), policy);
    return _wrap(job, outDir);
  }

  /// 把多张图片（JPG/PNG）合并为一个 PDF，每张图片一页，输出到 [outDir]。
  Future<PdfFileJob> imagesToPdf(
    List<File> images,
    Directory outDir,
  ) async {
    final job = await PdfCore.instance
        .imagesToPdf([for (final f in images) await _input(f)]);
    return _wrap(job, outDir);
  }

  /// 把 [input] 逐页渲染为 PNG 图片，输出到 [outDir]。
  ///
  /// [maxWidth] 限制输出位图最大宽度（像素）；[pages] 为 0 起始页码，
  /// null 表示全部页。返回可取消的 [PdfFileRenderJob]，可通过
  /// [PdfFileRenderJob.exportedCount] 轮询已完成的页数。
  Future<PdfFileRenderJob> pdfToImages(
    File input,
    Directory outDir, {
    int maxWidth = 1600,
    List<int>? pages,
  }) async {
    final job = await PdfCore.instance.pdfToImages(
      await _input(input),
      maxWidth: maxWidth,
      pages: pages,
    );
    return PdfFileRenderJob._(job, outDir);
  }

  /// 加密 [input] 并输出到 [outDir]。
  ///
  /// [ownerPassword] 为权限密码（拥有全部权限）；[userPassword] 为打开密码，
  /// 留空则无需密码即可打开（仅受 [permissions] 限制）。
  Future<PdfFileJob> encrypt(
    File input,
    Directory outDir, {
    required String ownerPassword,
    String? userPassword,
    PdfEncryptionAlgorithm algorithm = PdfEncryptionAlgorithm.aes256,
    PdfPermissions permissions = const PdfPermissions.all(),
  }) async {
    final job = await PdfCore.instance.encrypt(
      await _input(input),
      ownerPassword: ownerPassword,
      userPassword: userPassword,
      algorithm: algorithm,
      permissions: permissions,
    );
    return _wrap(job, outDir);
  }

  /// 移除 [input] 的加密（需提供打开密码 [password]），输出到 [outDir]。
  Future<PdfFileJob> decrypt(
    File input,
    String password,
    Directory outDir,
  ) async {
    final job =
        await PdfCore.instance.decrypt(await _input(input), password);
    return _wrap(job, outDir);
  }

  /// 打开可视化页面编辑会话（加密文件需传入 [password]）。
  Future<PdfFileEditSession> openEditor(File input, {String? password}) async {
    final session =
        await PdfCore.instance.openEditor(await _input(input), password: password);
    return PdfFileEditSession._(session);
  }

  static Future<PdfInput> _input(File f) async =>
      PdfInput(_name(f), await f.readAsBytes());

  static String _name(File f) => f.uri.pathSegments.last;

  static Future<PdfFileJob> _wrap(PdfJob<void> job, Directory outDir) async {
    final files = [
      for (final o in job.outputs) File('${outDir.path}/${o.name}'),
    ];
    return PdfFileJob._(job, files);
  }
}

/// 文件门面的可取消任务：核心任务完成后把输出字节落盘为文件。
/// 取消或失败时不产生任何文件（或清理已写出的文件）。
class PdfFileJob {
  PdfFileJob._(this._core, this._files);

  final PdfJob<void> _core;
  final List<File> _files;

  /// 本任务成功完成后会产生的输出文件（路径在任务创建时即已知）。
  List<File> get outputs => List.unmodifiable(_files);

  /// 请求取消（幂等；任务已结束时为空操作）。
  void cancel() => _core.cancel();

  /// 等待核心任务完成并把输出写入文件。取消时抛出 [PdfCancelled]，
  /// 失败时抛出引擎异常；两种情况下已写出的文件会被清理。
  Future<void> get done async {
    await _core.done;
    final written = <File>[];
    try {
      for (var i = 0; i < _files.length; i++) {
        await _files[i].writeAsBytes(_core.outputs[i].bytes);
        written.add(_files[i]);
      }
    } on Object {
      for (final f in written) {
        try {
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
      rethrow;
    }
  }
}

/// 文件门面的逐页渲染任务（PDF → 图片文件）。
class PdfFileRenderJob {
  PdfFileRenderJob._(this._core, this._dir);

  final PdfRenderJob _core;
  final Directory _dir;

  /// 已完成（且未清理）的页数。
  int get exportedCount => _core.exportedCount;

  /// 请求取消（幂等；当前页完成后停止）。
  void cancel() => _core.cancel();

  /// 等待全部页导出完成并落盘，返回输出文件列表。
  /// 取消时抛出 [PdfCancelled] 并清理已写出的文件，失败时同样清理。
  Future<List<File>> get done async {
    final outputs = await _core.done;
    final files = <File>[];
    try {
      for (final o in outputs) {
        final file = File('${_dir.path}/${o.name}');
        await file.writeAsBytes(o.bytes);
        files.add(file);
      }
    } on Object {
      for (final f in files) {
        try {
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
      rethrow;
    }
    return List.unmodifiable(files);
  }
}

/// 文件门面的可视化页面编辑会话。
class PdfFileEditSession {
  PdfFileEditSession._(this._core);

  final PdfEditSession _core;

  int get pageCount => _core.pageCount;

  /// 读取外部 PDF 的页数与逐页缩略图（用于"插入其他 PDF"预览）。
  Future<({int pageCount, List<Uint8List> thumbs})> loadInsertPreview(
    File source, {
    String? password,
  }) async =>
      _core.loadInsertPreview(
        PdfInput(_baseName(source), await source.readAsBytes()),
        password: password,
      );

  /// 低分辨率逐页缩略图流（原始页序）。
  Stream<RenderedPage> thumbnails({int maxWidth = 260}) =>
      _core.thumbnails(maxWidth: maxWidth);

  /// 应用编辑并保存到 [outDir]，参数含义与 [PdfEditSession.save] 一致。
  Future<PdfFileJob> save(
    Directory outDir, {
    required List<int> order,
    required Map<int, int> rotations,
    File? mergeSource,
    List<int>? mergePages,
    Map<int, List<Rect>>? erases,
    String? watermarkText,
    PdfWatermarkPosition? watermarkPosition,
    PdfWatermarkStyle? watermarkStyle,
    String? title,
    String? author,
    String? subject,
    String? keywords,
  }) async {
    final job = await _core.save(
      order: order,
      rotations: rotations,
      mergeSource: mergeSource == null
          ? null
          : PdfInput(_baseName(mergeSource), await mergeSource.readAsBytes()),
      mergePages: mergePages,
      erases: erases,
      watermarkText: watermarkText,
      watermarkPosition: watermarkPosition,
      watermarkStyle: watermarkStyle,
      title: title,
      author: author,
      subject: subject,
      keywords: keywords,
    );
    return PdfService._wrap(job, outDir);
  }

  /// 释放会话资源（幂等；保存后调用亦安全）。
  Future<void> dispose() => _core.dispose();

  static String _baseName(File f) => f.uri.pathSegments.last;
}
