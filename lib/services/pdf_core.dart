import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:pdf_manipulator/pdf_manipulator.dart';

/// 一份 PDF 输入：文件名与内容字节（Web 与桌面统一）。
class PdfInput {
  const PdfInput(this.name, this.bytes);

  /// 文件名（不含路径），用于生成输出文件名。
  final String name;

  /// 内容字节。
  final Uint8List bytes;
}

/// 一份任务输出：文件名 + 结果字节。
///
/// 字节在任务成功完成（[PdfJob.done]）后可用；失败或取消的任务
/// 不会产出字节。
class PdfOutput {
  /// 用已就绪的字节构造（测试或内存渲染路径使用）。
  PdfOutput.done(this.name, Uint8List bytes)
      : _bytes = bytes,
        _sink = null;

  PdfOutput._sink(this.name) : _sink = MemorySink(), _bytes = null;

  final String name;
  final MemorySink? _sink;
  Uint8List? _bytes;

  /// 结果字节（任务成功完成后可用）。
  Uint8List get bytes {
    final b = _bytes;
    if (b == null) {
      throw StateError('输出字节仅在任务成功完成后可用：$name');
    }
    return b;
  }

  /// 结果字节数（任务成功完成后可用）。
  int get size => bytes.length;

  void _materialize() {
    _bytes ??= _sink?.takeBytes();
  }
}

/// 一次可取消的 PDF 任务（字节进出）。
///
/// 通过 [cancel] 请求取消；[done] 返回最终结果并把输出物化为字节。
/// 取消或失败时输出保持不可用（Web 端无文件系统，无需清理半成品；
/// 桌面端由 [PdfService] 文件门面负责落盘，同样不会产生半成品文件）。
class PdfJob<T> {
  PdfJob._(this.task, this._outputs);

  final PdfTask<T> task;
  final List<PdfOutput> _outputs;

  /// 本任务成功完成后会产生的输出（名称在任务创建时即已知）。
  List<PdfOutput> get outputs => List.unmodifiable(_outputs);

  /// 请求取消（幂等；任务已结束时为空操作）。
  void cancel() => task.cancel();

  /// 等待任务结束并把全部输出物化为字节。
  /// 取消时抛出 [PdfCancelled]，失败时抛出引擎异常。
  Future<T> get done async {
    final result = await task;
    for (final o in _outputs) {
      o._materialize();
    }
    return result;
  }
}

/// PDF 操作核心服务（字节进出，Web 与桌面共用）：
/// 合并、拆分、提取、压缩、互转、加解密与页面编辑。
/// 基于 pdf_manipulator（Rust 引擎），所有操作均在后台执行，返回的
/// [PdfJob] / [PdfRenderJob] 支持取消。
class PdfCore {
  PdfCore._();

  static final instance = PdfCore._();

  Pdf? _engine;
  Pdf get _pdf => _engine ??= Pdf();

  /// 读取 PDF 页数。
  Future<int> pageCount(PdfInput input, {String? password}) async {
    final doc = await _pdf.open(MemorySource(input.bytes), password: password);
    try {
      return doc.pageCount;
    } finally {
      await doc.dispose();
    }
  }

  /// 读取 PDF 概要信息（页数与加密状态）。
  Future<PdfDocInfo> pdfInfo(PdfInput input, {String? password}) async {
    final doc = await _pdf.open(MemorySource(input.bytes), password: password);
    try {
      return PdfDocInfo(
        pageCount: doc.pageCount,
        isEncrypted: doc.isEncrypted,
        requiresPassword: doc.requiresPassword,
        algorithm: doc.encryptionAlgorithm,
        permissions: doc.permissions,
      );
    } finally {
      await doc.dispose();
    }
  }

  /// 合并多个 PDF，输出单个文件（文件名自动带时间戳）。
  Future<PdfJob<void>> merge(List<PdfInput> inputs) async {
    final output = PdfOutput._sink('merged-${_timestamp()}.pdf');
    final task = _pdf.merge(
      [for (final i in inputs) MemorySource(i.bytes)],
      output._sink!,
    );
    return PdfJob._(task, [output]);
  }

  /// 按每份 [every] 页拆分 [input]，输出多个文件。
  Future<PdfJob<void>> splitEvery(PdfInput input, int every) async {
    final total = await pageCount(input);
    final count = (total / every).ceil();
    final base = _stem(input.name);
    final ts = _timestamp();
    final outputs = <PdfOutput>[];
    for (var i = 0; i < count; i++) {
      final part = (i + 1).toString().padLeft(2, '0');
      outputs.add(PdfOutput._sink('$base-$ts-part$part.pdf'));
    }
    final task = _pdf.split(
      MemorySource(input.bytes),
      (index) => outputs[index]._sink!,
      every: every,
    );
    return PdfJob._(task, outputs);
  }

  /// 提取 [pages]（0 起始页码）为单独文件。
  Future<PdfJob<void>> extractPages(
    PdfInput input,
    List<int> pages, {
    String? nameSuffix,
  }) async {
    final suffix = nameSuffix ?? 'extract';
    final output = PdfOutput._sink(
      '${_stem(input.name)}-$suffix-${_timestamp()}.pdf',
    );
    final task =
        _pdf.extractPages(MemorySource(input.bytes), output._sink!, pages: pages);
    return PdfJob._(task, [output]);
  }

  /// 按 [policy] 压缩 [input]。
  Future<PdfJob<void>> compress(PdfInput input, PdfImagePolicy policy) async {
    final output =
        PdfOutput._sink('${_stem(input.name)}-compressed-${_timestamp()}.pdf');
    final task =
        _pdf.compress(MemorySource(input.bytes), output._sink!, images: policy);
    return PdfJob._(task, [output]);
  }

  /// 把多张图片（JPG/PNG）合并为一个 PDF，每张图片一页。
  Future<PdfJob<void>> imagesToPdf(List<PdfInput> images) async {
    final base = _stem(images.first.name);
    final output = PdfOutput._sink('$base-pdf-${_timestamp()}.pdf');
    final task = _pdf.imagesToPdf(
      [for (final i in images) MemorySource(i.bytes)],
      output._sink!,
    );
    return PdfJob._(task, [output]);
  }

  /// 把 [input] 逐页渲染为 PNG 图片。
  ///
  /// [maxWidth] 限制输出位图最大宽度（像素）；[pages] 为 0 起始页码，
  /// null 表示全部页。返回可取消的 [PdfRenderJob]，可通过
  /// [PdfRenderJob.exportedCount] 轮询已完成的页数。
  Future<PdfRenderJob> pdfToImages(
    PdfInput input, {
    int maxWidth = 1600,
    List<int>? pages,
  }) async {
    final state = _RenderState();
    final job = PdfRenderJob._(state);
    job._attach(_runRender(input, maxWidth, pages, state));
    return job;
  }

  Future<List<PdfOutput>> _runRender(
    PdfInput input,
    int maxWidth,
    List<int>? pages,
    _RenderState state,
  ) async {
    final doc = await _pdf.open(MemorySource(input.bytes));
    final base = _stem(input.name);
    final ts = _timestamp();
    try {
      var no = 0;
      await for (final page in doc.render(
        pages:
            pages == null ? const PdfPages.all() : PdfPages.list(pages),
        size: PdfRenderSize(maxWidth: maxWidth, maxHeight: maxWidth * 4),
      )) {
        if (state.cancelled) break;
        no++;
        state.outputs.add(
          PdfOutput.done(
            '$base-$ts-页${no.toString().padLeft(3, '0')}.png',
            page.data,
          ),
        );
      }
      if (state.cancelled) throw const PdfCancelled();
      return List.unmodifiable(state.outputs);
    } on Object {
      // 失败或取消：丢弃已渲染的字节（无文件系统，无需清理）。
      state.outputs.clear();
      rethrow;
    } finally {
      await doc.dispose();
    }
  }

  /// 加密 [input]。
  ///
  /// [ownerPassword] 为权限密码（拥有全部权限）；[userPassword] 为打开密码，
  /// 留空则无需密码即可打开（仅受 [permissions] 限制）。
  Future<PdfJob<void>> encrypt(
    PdfInput input, {
    required String ownerPassword,
    String? userPassword,
    PdfEncryptionAlgorithm algorithm = PdfEncryptionAlgorithm.aes256,
    PdfPermissions permissions = const PdfPermissions.all(),
  }) async {
    final output = PdfOutput._sink(
      '${_stem(input.name)}-encrypted-${_timestamp()}.pdf',
    );
    final editor = await _pdf.edit(MemorySource(input.bytes));
    final task = editor.save(
      output._sink!,
      options: PdfSaveOptions.fullRewrite(
        encryption: PdfEncryption.config(
          ownerPassword: ownerPassword,
          userPassword: userPassword ?? '',
          algorithm: algorithm,
          permissions: permissions,
        ),
      ),
    );
    return _editorJob(job: PdfJob._(task, [output]), editor: editor);
  }

  /// 移除 [input] 的加密（需提供打开密码 [password]）。
  Future<PdfJob<void>> decrypt(PdfInput input, String password) async {
    final output = PdfOutput._sink(
      '${_stem(input.name)}-decrypted-${_timestamp()}.pdf',
    );
    final editor =
        await _pdf.edit(MemorySource(input.bytes), password: password);
    final task = editor.save(
      output._sink!,
      options: const PdfSaveOptions.fullRewrite(
        encryption: PdfEncryption.remove(),
      ),
    );
    return _editorJob(job: PdfJob._(task, [output]), editor: editor);
  }

  /// 包装编辑器保存任务：任务结束后释放编辑器资源。
  PdfJob<void> _editorJob({
    required PdfJob<void> job,
    required PdfEditor editor,
  }) {
    unawaited(
      job.done.then(
        (_) => editor.dispose(),
        onError: (Object _) => editor.dispose(),
      ),
    );
    return job;
  }

  /// 打开可视化页面编辑会话（加密文件需传入 [password]）。
  Future<PdfEditSession> openEditor(PdfInput input, {String? password}) async {
    final editor =
        await _pdf.edit(MemorySource(input.bytes), password: password);
    final renderDoc =
        await _pdf.open(MemorySource(input.bytes), password: password);
    return PdfEditSession._(_pdf, input, editor, renderDoc, password);
  }

  /// 输出文件名用的时间戳（精确到毫秒），保证多次运行互不覆盖。
  static String _timestamp() {
    final t = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}'
        '-${two(t.hour)}${two(t.minute)}${two(t.second)}'
        '-${t.millisecond.toString().padLeft(3, '0')}';
  }

  static String _stem(String name) {
    final dot = name.lastIndexOf('.');
    return dot <= 0 ? name : name.substring(0, dot);
  }
}

/// 解析 "1-3,5"（兼容中文逗号）形式的页码范围，返回 0 起始的升序页码列表；
/// 输入非法或页码超出 [maxPageCount] 时返回 null。
List<int>? parsePageRanges(String input, int maxPageCount) {
  final pages = <int>{};
  for (final part in input.split(RegExp('[,，]'))) {
    final p = part.trim();
    if (p.isEmpty) continue;
    final m = RegExp(r'^(\d+)(?:\s*-\s*(\d+))?$').firstMatch(p);
    if (m == null) return null;
    final a = int.parse(m.group(1)!);
    final b = m.group(2) == null ? a : int.parse(m.group(2)!);
    if (a < 1 || b < a || b > maxPageCount) return null;
    for (var i = a; i <= b; i++) {
      pages.add(i - 1);
    }
  }
  if (pages.isEmpty) return null;
  return pages.toList()..sort();
}

/// 逐页渲染任务的内部共享状态。
class _RenderState {
  final outputs = <PdfOutput>[];
  bool cancelled = false;
}

/// 一次可取消的逐页渲染任务（PDF → 图片）。
///
/// 渲染基于流式 API 而非 [PdfTask]，因此取消粒度为"页与页之间"：
/// 当前页完成后即停止。[exportedCount] 可轮询已完成页数。
class PdfRenderJob {
  PdfRenderJob._(this._state);

  final _RenderState _state;
  late final Future<List<PdfOutput>> _done;

  void _attach(Future<List<PdfOutput>> future) => _done = future;

  /// 等待全部页导出完成，返回输出列表。
  /// 取消时抛出 [PdfCancelled]（已渲染字节被丢弃），失败时同样丢弃。
  Future<List<PdfOutput>> get done => _done;

  /// 已完成（且未丢弃）的页数。
  int get exportedCount => _state.outputs.length;

  /// 请求取消（幂等；当前页完成后停止）。
  void cancel() => _state.cancelled = true;
}

/// PDF 概要信息。
class PdfDocInfo {
  const PdfDocInfo({
    required this.pageCount,
    required this.isEncrypted,
    required this.requiresPassword,
    this.algorithm,
    this.permissions,
  });

  final int pageCount;
  final bool isEncrypted;

  /// 是否需要密码才能打开。
  final bool requiresPassword;

  /// 加密算法（未加密时为 null）。
  final PdfEncryptionAlgorithm? algorithm;

  /// 权限集（未加密时为 null）。
  final PdfPermissions? permissions;
}

/// 可视化页面编辑会话：渲染缩略图 + 暂存编辑操作，保存时一次性应用。
class PdfEditSession {
  PdfEditSession._(
    this._pdf,
    this._input,
    this._editor,
    this._renderDoc,
    this.password,
  );

  final Pdf _pdf;
  final PdfInput _input;
  final PdfEditor _editor;
  final PdfDoc _renderDoc;

  /// 打开文件所用的密码（加密文件时非空）。
  final String? password;

  bool _disposed = false;

  int get pageCount => _renderDoc.pageCount;

  /// 各页尺寸（点，原始页序），用于把归一化擦除区域换算为 PDF 坐标。
  List<PdfPageInfo> get pageInfos => _renderDoc.pages;

  /// 读取外部 PDF 的页数与逐页缩略图（用于"插入其他 PDF"预览）。
  Future<({int pageCount, List<Uint8List> thumbs})> loadInsertPreview(
    PdfInput source, {
    String? password,
  }) async {
    final doc =
        await _pdf.open(MemorySource(source.bytes), password: password);
    try {
      final thumbs = <Uint8List>[];
      await for (final page in doc.render(
        pages: const PdfPages.all(),
        size: const PdfRenderSize(maxWidth: 260, maxHeight: 1040),
      )) {
        thumbs.add(page.data);
      }
      return (pageCount: doc.pageCount, thumbs: thumbs);
    } finally {
      await doc.dispose();
    }
  }

  /// 低分辨率逐页缩略图流（原始页序）。
  Stream<RenderedPage> thumbnails({int maxWidth = 260}) =>
      _renderDoc.render(
        pages: const PdfPages.all(),
        size: PdfRenderSize(maxWidth: maxWidth, maxHeight: maxWidth * 4),
      );

  /// 应用编辑并保存为新 PDF。
  ///
  /// [order] 为最终页序（主文档 0 起始索引 + 外部页虚拟索引 ≥ 主文档页数，
  /// 省略即删除）；[rotations] 为页索引 → 累计旋转角度；
  /// [mergeSource]/[mergePages] 为待插入的外部 PDF 及其 0 起始源页码
  /// （null = 按追加顺序取全部页）；[erases] 为页索引 → 归一化擦除区域
  /// （0-1，左上原点）；[watermarkText] 非空时为全部页加水印；其余为文档元数据。
  ///
  /// 引擎限制：mergeFrom 只能追加，且追加后 selectPages/movePage 不再可用，
  /// 单编辑器内无法把外部页插到主文档页之间。因此：
  /// - 无外部页时直接在当前编辑器上完成（旋转 → 删选/重排 → 擦除 →
  ///   水印 → 元数据）；
  /// - 有外部页时先把每个连续同源段写成内存 PDF（段内完成删选/旋转/
  ///   擦除/水印），再按最终顺序 mergeFrom 串接并写元数据。临时段统一
  ///   解除加密以便串接，最终输出还原源文件的加密配置。
  Future<PdfJob<void>> save({
    required List<int> order,
    required Map<int, int> rotations,
    PdfInput? mergeSource,
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
    final mainCount = _renderDoc.pageCount;
    final mainSeq = [for (final idx in order) if (idx < mainCount) idx];
    final extCount = order.length - mainSeq.length;
    if (extCount > 0 && mergeSource == null) {
      throw ArgumentError.value(order, 'order', '包含外部页但未提供 mergeSource');
    }

    if (extCount > 0) {
      return _saveWithInserts(
        order: order,
        mainCount: mainCount,
        mergeSource: mergeSource!,
        mergePages: mergePages,
        rotations: rotations,
        erases: erases,
        watermarkText: watermarkText,
        watermarkPosition: watermarkPosition,
        watermarkStyle: watermarkStyle,
        title: title,
        author: author,
        subject: subject,
        keywords: keywords,
      );
    }

    // ── 快速路径：仅主文档（删选/重排/旋转/擦除/水印/元数据）。──

    // 1. 页旋转（此时索引仍为原始索引）。
    for (final entry in rotations.entries) {
      if (entry.value % 360 != 0) {
        await _editor.rotatePage(entry.key, degrees: entry.value % 360);
      }
    }

    // 2. 删选/重排（恒等时跳过）。
    if (mainSeq.length != mainCount || !_isIdentityList(mainSeq)) {
      await _editor.selectPages(mainSeq);
    }

    // 3. 内容擦除（页索引即最终输出中的位置）。
    if (erases != null) {
      final sizes = _renderDoc.pages;
      for (final entry in erases.entries) {
        final pos = order.indexOf(entry.key);
        if (pos < 0) continue;
        final info = sizes[entry.key];
        final regions = [
          for (final r in entry.value)
            PdfRect(
              x: r.left * info.width,
              y: (1 - r.bottom) * info.height,
              width: r.width * info.width,
              height: r.height * info.height,
            ),
        ];
        if (regions.isNotEmpty) {
          await _editor.eraseRegions(pos, regions);
        }
      }
    }

    // 4. 水印（全部页）。
    if (watermarkText != null && watermarkText.trim().isNotEmpty) {
      for (var i = 0; i < order.length; i++) {
        await _editor.addWatermark(
          i,
          watermarkText.trim(),
          style: watermarkStyle ?? const PdfWatermarkStyle(),
          position: watermarkPosition ?? const PdfWatermarkPosition.center(),
        );
      }
    }

    // 5. 元数据。
    if (title != null) await _editor.setTitle(title);
    if (author != null) await _editor.setAuthor(author);
    if (subject != null) await _editor.setSubject(subject);
    if (keywords != null) await _editor.setKeywords(keywords);

    final output =
        PdfOutput._sink('${PdfCore._stem(_input.name)}-edited-${PdfCore._timestamp()}.pdf');
    final task = _editor.save(output._sink!);
    final job = PdfJob._(task, [output]);
    unawaited(
      job.done.then(
        (_) => _editor.dispose(),
        onError: (Object _) => _editor.dispose(),
      ),
    );
    return job;
  }

  /// 含外部页的保存路径：把最终页序拆成连续同源段，每段先写成内存 PDF
  /// （段内完成删选/旋转/擦除/水印），再按序 mergeFrom 串接并写元数据。
  Future<PdfJob<void>> _saveWithInserts({
    required List<int> order,
    required int mainCount,
    required PdfInput mergeSource,
    List<int>? mergePages,
    required Map<int, int> rotations,
    Map<int, List<Rect>>? erases,
    String? watermarkText,
    PdfWatermarkPosition? watermarkPosition,
    PdfWatermarkStyle? watermarkStyle,
    String? title,
    String? author,
    String? subject,
    String? keywords,
  }) async {
    // 外部页虚拟索引 → 外部源 0 起始页码（按追加顺序对应）。
    final extCount = order.length - order.where((k) => k < mainCount).length;
    final srcPages = [
      for (var i = 0; i < extCount; i++) mergePages == null ? i : mergePages[i],
    ];

    // 把最终页序拆成连续同源段（同一 mergeSource 对象视为同源）。
    final runs = <_PageSegment>[];
    for (final key in order) {
      final isExt = key >= mainCount;
      final src = isExt ? mergeSource : null;
      final page = isExt ? srcPages[key - mainCount] : key;
      if (runs.isNotEmpty && identical(runs.last.src, src)) {
        runs.last.pages.add(page);
        runs.last.keys.add(key);
      } else {
        runs.add(_PageSegment(src, page, key));
      }
    }

    try {
      // 外部源页尺寸（按需读取，用于换算外部页擦除区域）。
      List<PdfPageInfo> extInfos = const [];
      if (erases?.keys.any((k) => k >= mainCount) ?? false) {
        final extDoc =
            await _pdf.open(MemorySource(mergeSource.bytes));
        try {
          extInfos = extDoc.pages;
        } finally {
          await extDoc.dispose();
        }
      }

      // 逐段生成内存 PDF。
      final segBytes = <Uint8List>[];
      for (var s = 0; s < runs.length; s++) {
        final run = runs[s];
        final editor = await _pdf.edit(
          MemorySource(run.src?.bytes ?? _input.bytes),
          password: run.src == null ? password : null,
        );
        try {
          // 删选（恒等时跳过）。
          final total = await editor.pageCount;
          if (run.pages.length != total || !_isIdentityList(run.pages)) {
            await editor.selectPages(run.pages);
          }

          // 旋转（段内新索引 i 对应 keys[i]）。
          for (var i = 0; i < run.keys.length; i++) {
            final deg = (rotations[run.keys[i]] ?? 0) % 360;
            if (deg != 0) await editor.rotatePage(i, degrees: deg);
          }

          // 擦除。
          if (erases != null) {
            for (var i = 0; i < run.keys.length; i++) {
              final rects = erases[run.keys[i]];
              if (rects == null || rects.isEmpty) continue;
              final info = run.src == null
                  ? _renderDoc.pages[run.keys[i]]
                  : extInfos[run.pages[i]];
              await editor.eraseRegions(i, [
                for (final r in rects)
                  PdfRect(
                    x: r.left * info.width,
                    y: (1 - r.bottom) * info.height,
                    width: r.width * info.width,
                    height: r.height * info.height,
                  ),
              ]);
            }
          }

          // 水印（段内每页）。
          if (watermarkText != null && watermarkText.trim().isNotEmpty) {
            for (var i = 0; i < run.keys.length; i++) {
              await editor.addWatermark(
                i,
                watermarkText.trim(),
                style: watermarkStyle ?? const PdfWatermarkStyle(),
                position:
                    watermarkPosition ?? const PdfWatermarkPosition.center(),
              );
            }
          }

          // 段临时数据统一解除加密，便于后续 mergeFrom 串接。
          final segSink = MemorySink();
          await editor.save(
            segSink,
            options: const PdfSaveOptions.fullRewrite(
              encryption: PdfEncryptionRemove(),
            ),
          );
          segBytes.add(segSink.takeBytes());
        } finally {
          await editor.dispose();
        }
      }

      // 按段顺序串接（mergeFrom 依次追加每段），最后写元数据。
      final chain = await _pdf.edit(MemorySource(segBytes.first));
      try {
        for (var s = 1; s < segBytes.length; s++) {
          await chain.mergeFrom(MemorySource(segBytes[s]));
        }
        if (title != null) await chain.setTitle(title);
        if (author != null) await chain.setAuthor(author);
        if (subject != null) await chain.setSubject(subject);
        if (keywords != null) await chain.setKeywords(keywords);

        // 还原源文件加密状态（临时段已解除加密）。
        final algorithm = _renderDoc.encryptionAlgorithm;
        final output = PdfOutput._sink(
          '${PdfCore._stem(_input.name)}-edited-${PdfCore._timestamp()}.pdf',
        );
        final task = chain.save(
          output._sink!,
          options: algorithm == null
              ? const PdfSaveOptions.fullRewrite()
              : PdfSaveOptions.fullRewrite(
                  encryption: PdfEncryption.config(
                    ownerPassword: password ?? '',
                    userPassword: password ?? '',
                    algorithm: algorithm,
                    permissions:
                        _renderDoc.permissions ?? const PdfPermissions.all(),
                  ),
                ),
        );
        final job = PdfJob._(task, [output]);
        unawaited(
          job.done.then(
            (_) => chain.dispose(),
            onError: (Object _) => chain.dispose(),
          ),
        );
        return job;
      } on Object {
        await chain.dispose();
        rethrow;
      }
    } on Object {
      // 内存段由 GC 回收，无需清理。
      rethrow;
    }
  }

  static bool _isIdentityList(List<int> list) {
    for (var i = 0; i < list.length; i++) {
      if (list[i] != i) return false;
    }
    return true;
  }

  /// 释放会话资源（幂等；保存后调用亦安全）。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _editor.dispose();
    } catch (_) {}
    try {
      await _renderDoc.dispose();
    } catch (_) {}
  }
}

/// 连续同源的页段：[src] 为 null 表示主文档段，否则为外部源。
class _PageSegment {
  _PageSegment(this.src, int firstPage, int firstKey)
      : pages = [firstPage],
        keys = [firstKey];

  final PdfInput? src;

  /// 段内各页在其所属源文档中的 0 起始页码。
  final List<int> pages;

  /// 段内各页在 [PdfEditSession.save] 的 [order] 中的键
  /// （主文档页为原始索引，外部页为虚拟索引）。
  final List<int> keys;
}
