# LMTool

基于 Flutter 开发的 PDF 文件处理工具，支持 **Windows 桌面端**与 **Web 浏览器端**，
功能覆盖合并、拆分、压缩、互转、加解密与可视化页面编辑。

## 功能

- **合并 PDF**：多选文件、自由调整合并顺序，输出单个文件
- **拆分 PDF**：
  - 按页数拆分：每 N 页生成一个新文件（1/2/3/5/10/20/50 可选）
  - 提取指定页面：支持 `1-3,5` 形式的页码范围（兼容中文逗号）
- **批量压缩 PDF**：多选/拖入文件，队列逐个压缩，逐项与总体展示前后体积对比
  - 四档策略：
    - 无损优化：不降低画质，仅重排与无损重编码
    - 高清打印：300 ppi · JPEG 85，适合打印
    - 均衡（推荐）：150 ppi · JPEG 75，并重编码已有 JPEG 图片（针对照片/扫描件优化）
    - 极限压缩：72 ppi · JPEG 60，体积最小
- **图片转 PDF**：多选/拖入 JPG/PNG 图片，自由排序，每张图片一页合成 PDF
- **PDF 转图片**：逐页导出 PNG，三档清晰度（1600/3000/5000 px 最大宽度），支持指定页码范围，导出过程实时显示进度
- **加密保护**：
  - 加密：设置权限密码（必填）与打开密码（可选），可勾选允许打印/复制/修改，支持 AES-128 / AES-256
  - 解密：输入打开密码后输出无加密副本
- **页面编辑**：可视化缩略图编辑器，支持单页旋转、删除、前后移动与整体旋转，保存为新 PDF；加密文件输入密码后同样可编辑
  - 插入其他 PDF：选择外部 PDF 追加页面，可与原页面自由交错重排（支持只挑选部分页）
  - 内容擦除：擦除模式下在页面缩略图上拖动框选，抹掉区域内文字与内容
  - 文字水印：居中或平铺（3×3），可调透明度，应用到全部页
  - 元数据编辑：可设置标题、作者、主题与关键词

## 特性

- **桌面与浏览器同源体验**：同一套界面与引擎，Web 端由 WASM 内核在浏览器本地完成全部处理，文件不上传服务器
- 全页面支持**拖拽导入**文件，拖入窗口即添加
- 批量任务队列：逐项执行、单项取消、全部取消、失败重试、运行中可继续追加
- 任务进行中可随时**取消**
- 输出文件名带毫秒级时间戳，多次运行互不覆盖
- 桌面端：失败自动清理半成品文件；一键打开输出所在文件夹；输出目录在各功能页之间共享记忆
- Web 端：结果逐文件提供**下载按钮**，无需选择输出目录
- 选择文件后自动读取页数与大小，压缩后显示节省百分比
- Material 3 中文界面，操作全部在后台线程执行，界面不卡顿

## 技术栈

| 组件 | 说明 |
| --- | --- |
| [pdf_manipulator](https://pub.dev/packages/pdf_manipulator) | PDF 引擎（Rust 内核），合并/拆分/提取/压缩，支持取消；Web 端以 WASM + Web Worker 运行 |
| [desktop_drop](https://pub.dev/packages/desktop_drop) | 拖拽文件导入 |
| [file_picker](https://pub.dev/packages/file_picker) | 文件与目录选择 |
| [open_filex](https://pub.dev/packages/open_filex) | 打开输出文件夹（仅桌面） |
| [web](https://pub.dev/packages/web) | Web 端触发浏览器下载 |

## 运行

```bash
flutter pub get
flutter run -d windows        # 开发运行（桌面）
flutter run -d chrome         # 开发运行（Web）
flutter test                  # 运行测试（含引擎级回归测试）
flutter build windows --release   # 构建 Windows Release
flutter build web --release       # 构建 Web Release
```

- Windows 构建产物位于 `build/windows/x64/runner/Release/lm_tool.exe`。
- Web 构建产物位于 `build/web/`（静态站点，任意静态服务器可直接托管）。
- Web 引擎资产由构建钩子自动安装到 `web/pdf_manipulator/`；若缺失可执行
  `dart run pdf_manipulator:setup` 手动拉取。

> 说明：Windows 下首次构建会自动下载引擎二进制，之后完全离线可用；
> Web 端引擎（WASM）在构建时已打包进产物，运行期无需任何网络请求（纯静态托管）。
> 代码本身跨平台，需要其他平台时执行 `flutter create --platforms=android .` 等补充平台目录即可。

## 平台差异

| 能力 | Windows 桌面端 | Web 端 |
| --- | --- | --- |
| 文件选择 / 拖入 | 支持 | 支持（选择即读入内存） |
| 输出方式 | 写入所选输出目录 | 浏览器逐文件下载 |
| 输出目录 | 可选、跨页面记忆 | 无此概念（结果区内提供下载按钮） |
| 引擎执行 | 本机后台线程 | WASM + Web Worker（本地执行，不联网上传） |
| 大文件 | 流式落盘路径可用 | 受浏览器内存限制（建议单文件 < 数百 MB） |

## 项目结构

```
lib/
├── main.dart                  # 应用外壳与导航
├── pages/
│   ├── merge_page.dart        # 合并页
│   ├── split_page.dart        # 拆分页
│   ├── compress_page.dart     # 批量压缩页（四档策略 + 任务队列）
│   ├── images_to_pdf_page.dart # 图片转 PDF 页
│   ├── pdf_to_images_page.dart # PDF 转图片页
│   ├── protect_page.dart      # 加密保护页（加密/解密）
│   └── page_editor_page.dart  # 可视化页面编辑器
├── services/
│   ├── pdf_core.dart          # 字节核心（PdfCore/PdfJob/PdfRenderJob/PdfEditSession，Web 与桌面共用）
│   ├── pdf_file_service.dart  # 桌面文件门面（File 进/出，条件导出，Web 构建不含）
│   ├── platform_io.dart       # 平台 I/O 抽象（选择/拖入/保存/下载，desktop 与 web 双实现）
│   ├── task_queue.dart        # 批量任务队列（串行执行、取消/重试）
│   └── app_settings.dart      # 全局设置（输出目录）
└── widgets/common.dart        # 通用组件（拖拽导入、分区卡片、进度条、结果视图等）
test/
├── pdf_service_test.dart      # 合并/拆分/提取/压缩/取消 回归测试
├── task_queue_test.dart       # 任务队列逻辑与引擎集成测试
├── convert_test.dart          # 图片转 PDF / PDF 转图片 / 页码解析测试
├── secure_edit_test.dart      # 加密/解密与页面编辑器测试
├── advanced_edit_test.dart    # 页面编辑进阶测试（元数据/水印/擦除/插入页面）
├── compress_effect_test.dart  # 压缩有效性测试（针对已含 JPEG 的 PDF）
└── widget_test.dart           # UI 冒烟测试
```
