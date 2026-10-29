import 'package:flutter_test/flutter_test.dart';
import 'package:lm_tool/main.dart';

void main() {
  testWidgets('应用能正常启动并显示七个功能入口', (tester) async {
    await tester.pumpWidget(const LmToolApp());
    expect(find.text('合并 PDF'), findsOneWidget);
    expect(find.text('拆分 PDF'), findsOneWidget);
    expect(find.text('压缩 PDF'), findsOneWidget);
    expect(find.text('图片转 PDF'), findsOneWidget);
    expect(find.text('PDF 转图片'), findsOneWidget);
    expect(find.text('加密保护'), findsOneWidget);
    expect(find.text('页面编辑'), findsOneWidget);
    expect(find.text('合并'), findsOneWidget);
  });
}
