# LMTool

基于 Flutter 开发的 PDF 文件处理工具（Windows 桌面端），支持合并、拆分与压缩。

## 功能

- **合并 PDF**：多选文件、自由调整合并顺序，输出单个文件
- **拆分 PDF**：
  - 按页数拆分：每 N 页生成一个新文件（1/2/3/5/10/20/50 可选）
  - 提取指定页面：支持 `1-3,5` 形式的页码范围（兼容中文逗号）
- **压缩 PDF**：四档策略，完成后展示压缩前后体积对比
  - 无损优化：不降低画质，仅重排与无损重编码
  - 高清打印：300 ppi · JPEG 85，适合打印
  - 均衡（推荐）：150 ppi · JPEG 75，并重编码已有 JPEG 图片（针对照片/扫描件优化）
  - 极限压缩：72 ppi · JPEG 60，体积最小

## 特性

- 任务进行中可随时**取消**，失败自动清理半成品文件
- 输出文件名带毫秒级时间戳，多次运行互不覆盖，清理不影响历史结果
- 选择文件后自动读取页数与大小，压缩后显示节省百分比
- 一键打开输出所在文件夹；输出目录在三个功能页之间共享记忆
- Material 3 中文界面，操作全部在后台线程执行，界面不卡顿

## 技术栈

| 组件 | 说明 |
| --- | --- |
| [pdf_manipulator](https://pub.dev/packages/pdf_manipulator) | PDF 引擎（Rust 内核），合并/拆分/提取/压缩，支持取消 |
| [file_picker](https://pub.dev/packages/file_picker) | 文件与目录选择 |
| [open_filex](https://pub.dev/packages/open_filex) | 打开输出文件夹 |

## 运行

```bash
flutter pub get
flutter run -d windows        # 开发运行
flutter test                  # 运行测试（含引擎级回归测试）
flutter build windows --release   # 构建 Release
```

构建产物位于 `build/windows/x64/runner/Release/lm_tool.exe`。

> 说明：Windows 下首次构建会自动下载引擎二进制，之后完全离线可用。
> 代码本身跨平台，需要其他平台时执行 `flutter create --platforms=android .` 等补充平台目录即可。

## 项目结构

```
lib/
├── main.dart                  # 应用外壳与导航
├── pages/
│   ├── merge_page.dart        # 合并页
│   ├── split_page.dart        # 拆分页
│   └── compress_page.dart     # 压缩页（含四档策略）
├── services/
│   ├── pdf_service.dart       # PDF 引擎封装（PdfJob：可取消、失败清理）
│   └── app_settings.dart      # 全局设置（输出目录）
└── widgets/common.dart        # 通用组件（分区卡片、进度条、结果视图等）
test/
├── pdf_service_test.dart      # 合并/拆分/提取/压缩/取消 回归测试
├── compress_effect_test.dart  # 压缩有效性测试（针对已含 JPEG 的 PDF）
└── widget_test.dart           # UI 冒烟测试
```
