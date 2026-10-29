/// LM 工具箱 PDF 服务统一出口。
///
/// - [PdfCore]（pdf_core.dart）：字节核心，Web 与桌面共用，页面代码使用；
/// - `PdfService`（pdf_file_service.dart）：桌面文件门面（File 进/出），
///   仅桌面与测试使用，Web 构建中由条件导出排除。
library;

export 'pdf_core.dart';
export 'pdf_file_service.dart' if (dart.library.js_interop) 'pdf_file_service_stub.dart';
