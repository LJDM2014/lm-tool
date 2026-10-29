import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lm_tool/services/pdf_core.dart';
import 'package:lm_tool/services/task_queue.dart';
import 'package:pdf_manipulator/pdf_manipulator.dart';

import 'pdf_test_utils.dart';

void main() {
  group('TaskQueue 基础逻辑（不依赖引擎）', () {
    test('串行执行并隔离单个失败', () async {
      final queue = TaskQueue();
      final calls = <String>[];
      queue.addAll([
        TaskQueueItem(
          label: 'a',
          task: _FakeTask('a', onRun: () => calls.add('a')),
        ),
        TaskQueueItem(
          label: 'bad',
          task: _FakeTask('bad', throwException: 'boom'),
        ),
        TaskQueueItem(
          label: 'c',
          task: _FakeTask('c', onRun: () => calls.add('c')),
        ),
      ]);

      await queue.run();

      // 失败不影响后续任务；顺序保持串行。
      expect(calls, ['a', 'c']);
      expect(queue.items[0].state, TaskState.done);
      expect(queue.items[1].state, TaskState.failed);
      expect(queue.items[1].error.toString(), contains('boom'));
      expect(queue.items[2].state, TaskState.done);
      expect(queue.failedCount, 1);
      expect(queue.doneCount, 2);
    });

    test('等待中条目可直接取消，run 跳过', () async {
      final queue = TaskQueue();
      final ran = <String>[];
      queue.addAll([
        TaskQueueItem(
          label: 'a',
          task: _FakeTask('a', onRun: () => ran.add('a')),
        ),
        TaskQueueItem(
          label: 'b',
          task: _FakeTask('b', onRun: () => ran.add('b')),
        ),
      ]);

      queue.cancelItem(queue.items[1]);
      await queue.run();

      expect(ran, ['a']);
      expect(queue.items[1].state, TaskState.cancelled);
    });

    test('cancelAll 停止队列且不再执行后续条目', () async {
      final queue = TaskQueue();
      final ran = <String>[];
      queue.addAll([
        TaskQueueItem(
          label: 'a',
          task: _FakeTask('a', onRun: () {
            ran.add('a');
            queue.cancelAll();
          }),
        ),
        TaskQueueItem(
          label: 'b',
          task: _FakeTask('b', onRun: () => ran.add('b')),
        ),
      ]);

      await queue.run();

      // cancelAll 语义：等待中的条目全部取消（含执行中的当前条目）。
      expect(ran, ['a']);
      expect(queue.items[0].state, TaskState.cancelled);
      expect(queue.items[1].state, TaskState.cancelled);
      expect(queue.running, isFalse);
    });

    test('retryFailed 只重置失败条目并可再次执行', () async {
      var failFirstTime = true;
      final queue = TaskQueue();
      queue.add(
        TaskQueueItem(
          label: 'flaky',
          task: _FakeTask(
            'flaky',
            throwException: 'first-run-fails',
            shouldFail: () {
              final f = failFirstTime;
              failFirstTime = false;
              return f;
            },
          ),
        ),
      );

      await queue.run();
      expect(queue.items.single.state, TaskState.failed);

      queue.retryFailed();
      expect(queue.items.single.state, TaskState.pending);
      expect(queue.items.single.error, isNull);

      await queue.run();
      expect(queue.items.single.state, TaskState.done);
    });

    test('removeFinished 只清除已结束条目', () async {
      final queue = TaskQueue();
      queue.addAll([
        TaskQueueItem(label: 'a', task: _FakeTask('a')),
        TaskQueueItem(label: 'b', task: _FakeTask('b', throwException: 'x')),
      ]);
      await queue.run();

      queue.removeFinished();
      expect(queue.items, isEmpty);
    });
  });

  group('TaskQueue + 引擎集成（真实压缩）', () {
    late Directory tempDir;
    late Pdf engine;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('lmtool_queue_test');
      engine = Pdf();
    });

    tearDown(() async {
      await engine.dispose();
      await tempDir.delete(recursive: true);
    });

    test('队列串行压缩多个文件，逐项产出输出', () async {
      final outDir = Directory('${tempDir.path}/out');
      await outDir.create();
      final files = <File>[
        for (var i = 0; i < 2; i++)
          await writePdfBytes(
            tempDir,
            'doc$i.pdf',
            await makePdf(engine, 2),
          ),
      ];

      final queue = TaskQueue();
      queue.addAll([
        for (final f in files)
          TaskQueueItem(
            label: f.uri.pathSegments.last,
            sourceSize: f.lengthSync(),
            task: PdfJobTask(
              () async => PdfCore.instance.compress(
                PdfInput(f.uri.pathSegments.last, await f.readAsBytes()),
                PdfImagePolicy(
                  colorPpi: 72,
                  grayPpi: 72,
                  monoPpi: 300,
                  jpegQuality: 60,
                  convertCmykToRgb: true,
                  recompressJpeg: true,
                  minSavings: 0,
                  downsampleThreshold: 1.0,
                ),
              ),
            ),
          ),
      ]);

      await queue.run();

      expect(queue.doneCount, 2);
      expect(queue.failedCount, 0);
      for (final item in queue.items) {
        expect(item.state, TaskState.done);
        expect(item.outputs, hasLength(1));
        expect(item.outputs.single.bytes, isNotEmpty);
      }
    });

    test('取消单个执行中的条目，其余条目照常完成', () async {
      final outDir = Directory('${tempDir.path}/out');
      await outDir.create();
      final a = await writePdfBytes(
        tempDir,
        'a.pdf',
        await makePdf(engine, 2),
      );
      final b = await writePdfBytes(
        tempDir,
        'b.pdf',
        await makePdf(engine, 2),
      );

      final queue = TaskQueue();
      queue.addAll([
        TaskQueueItem(
          label: 'a',
          task: PdfJobTask(
            () async => PdfCore.instance.compress(
              PdfInput(a.uri.pathSegments.last, await a.readAsBytes()),
              PdfImagePolicy.lossless,
            ),
          ),
        ),
        TaskQueueItem(
          label: 'b',
          task: PdfJobTask(
            () async => PdfCore.instance.compress(
              PdfInput(b.uri.pathSegments.last, await b.readAsBytes()),
              PdfImagePolicy.lossless,
            ),
          ),
        ),
      ]);

      // 入队后立即取消第一条（等待中 → 直接标记取消）。
      queue.cancelItem(queue.items[0]);
      await queue.run();

      expect(queue.items[0].state, TaskState.cancelled);
      expect(queue.items[1].state, TaskState.done);
      expect(queue.items[1].outputs.single.bytes, isNotEmpty);
    });
  });
}

/// 测试用假任务。
class _FakeTask implements QueueTask {
  _FakeTask(
    this.name, {
    this.onRun,
    this.throwException,
    this.shouldFail,
  });

  final String name;
  final void Function()? onRun;

  /// 非 null 时任务失败并抛出该消息。
  final String? throwException;

  /// 动态决定是否失败（用于重试场景）。
  final bool Function()? shouldFail;

  bool _cancelled = false;

  @override
  Future<List<PdfOutput>> execute() async {
    final fail = shouldFail?.call() ?? (throwException != null);
    if (fail) {
      throw Exception(throwException ?? 'fake-failure');
    }
    onRun?.call();
    if (_cancelled) throw PdfCancelled();
    return [PdfOutput.done('$name-output.pdf', Uint8List(0))];
  }

  @override
  void requestCancel() => _cancelled = true;
}
