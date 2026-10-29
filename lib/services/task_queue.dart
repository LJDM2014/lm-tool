import 'package:flutter/foundation.dart';
import 'package:pdf_manipulator/pdf_manipulator.dart';

import 'pdf_core.dart';

/// 队列可执行的原子任务抽象，与 PDF 引擎解耦，便于测试与扩展。
abstract class QueueTask {
  /// 执行任务并返回输出列表。
  /// 取消时抛出 [PdfCancelled]，失败时抛出其他异常。
  Future<List<PdfOutput>> execute();

  /// 请求取消（幂等；对尚未创建底层任务的任务也生效）。
  void requestCancel();
}

/// [PdfJob] 的队列适配器：延迟创建任务，并处理"工厂执行期间被取消"的竞态。
class PdfJobTask implements QueueTask {
  PdfJobTask(this._factory);

  final Future<PdfJob<void>> Function() _factory;
  PdfJob<void>? _job;
  bool _cancelRequested = false;

  @override
  Future<List<PdfOutput>> execute() async {
    final job = _job ??= await _factory();
    if (_cancelRequested) job.cancel();
    await job.done;
    return job.outputs;
  }

  @override
  void requestCancel() {
    _cancelRequested = true;
    _job?.cancel();
  }
}

/// 队列条目状态。
enum TaskState { pending, running, done, failed, cancelled }

/// 队列中的一个任务条目。
class TaskQueueItem {
  TaskQueueItem({
    required this.label,
    required this.task,
    this.sourceSize,
  });

  final String label;
  final QueueTask task;

  /// 源文件大小（可选，用于展示前后对比）。
  final int? sourceSize;

  TaskState state = TaskState.pending;
  Object? error;
  List<PdfOutput> outputs = const [];

  bool get isTerminal =>
      state == TaskState.done ||
      state == TaskState.failed ||
      state == TaskState.cancelled;
}

/// 串行批量任务队列。
///
/// - 逐项执行，同一时刻只有一个任务在跑（PDF 引擎操作本身已是后台线程）
/// - 支持"运行中继续追加"：追加的条目会被后续循环拾取
/// - 单项取消 / 全部取消 / 失败重试
class TaskQueue extends ChangeNotifier {
  final _items = <TaskQueueItem>[];
  bool _running = false;
  bool _cancelAllRequested = false;

  List<TaskQueueItem> get items => List.unmodifiable(_items);

  bool get running => _running;

  int get doneCount =>
      _items.where((i) => i.state == TaskState.done).length;
  int get failedCount =>
      _items.where((i) => i.state == TaskState.failed).length;
  int get pendingCount =>
      _items.where((i) => i.state == TaskState.pending).length;

  bool get hasFinishedWork => _items.any((i) => i.isTerminal);

  void add(TaskQueueItem item) {
    _items.add(item);
    notifyListeners();
  }

  void addAll(Iterable<TaskQueueItem> items) {
    _items.addAll(items);
    notifyListeners();
  }

  /// 取消单个条目（等待中的直接标记取消；执行中的转发给底层任务）。
  void cancelItem(TaskQueueItem item) {
    if (item.state == TaskState.pending) {
      item.state = TaskState.cancelled;
    } else if (item.state == TaskState.running) {
      item.task.requestCancel();
    }
    notifyListeners();
  }

  /// 取消所有可取消的条目；[run] 循环会在当前条目结束后停止。
  void cancelAll() {
    _cancelAllRequested = true;
    for (final item in _items) {
      cancelItem(item);
    }
  }

  /// 把失败条目重置为等待中，等待下次 [run]。
  void retryFailed() {
    for (final item in _items) {
      if (item.state == TaskState.failed) {
        item.state = TaskState.pending;
        item.error = null;
      }
    }
    notifyListeners();
  }

  /// 清除已结束的条目（仅限队列空闲时调用）。
  void removeFinished() {
    if (_running) return;
    _items.removeWhere((i) => i.isTerminal);
    notifyListeners();
  }

  /// 串行执行队列中所有等待中的条目。已在运行时调用为空操作。
  Future<void> run() async {
    if (_running) return;
    _running = true;
    _cancelAllRequested = false;
    notifyListeners();
    try {
      // 直接遍历活动列表：运行中追加的条目也会被拾取。
      for (final item in _items) {
        if (_cancelAllRequested) break;
        if (item.state != TaskState.pending) continue;
        item.state = TaskState.running;
        notifyListeners();
        try {
          item.outputs = await item.task.execute();
          if (item.state == TaskState.running) {
            item.state = TaskState.done;
          }
        } on PdfCancelled {
          if (item.state == TaskState.running) {
            item.state = TaskState.cancelled;
          }
        } on Object catch (e) {
          if (item.state == TaskState.running) {
            item.state = TaskState.failed;
            item.error = e;
          }
        }
        notifyListeners();
      }
    } finally {
      _running = false;
      notifyListeners();
    }
  }
}
