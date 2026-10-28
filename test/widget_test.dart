import 'package:flutter_test/flutter_test.dart';
import 'package:lm_tool/main.dart';

void main() {
  testWidgets('应用能正常启动并显示三个功能入口', (tester) async {
    await tester.pumpWidget(const LmToolApp());
    expect(find.text('合并 PDF'), findsOneWidget);
    expect(find.text('拆分 PDF'), findsOneWidget);
    expect(find.text('压缩 PDF'), findsOneWidget);
    expect(find.text('合并'), findsOneWidget);
  });
}
