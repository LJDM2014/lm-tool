import 'package:flutter/material.dart';

import 'pages/compress_page.dart';
import 'pages/merge_page.dart';
import 'pages/split_page.dart';

void main() {
  runApp(const LmToolApp());
}

class LmToolApp extends StatelessWidget {
  const LmToolApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LM 工具箱',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3D5AFE)),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _index = 0;

  static const _destinations = [
    NavigationRailDestination(
      icon: Icon(Icons.merge_type_outlined),
      selectedIcon: Icon(Icons.merge_type),
      label: Text('合并 PDF'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.call_split_outlined),
      selectedIcon: Icon(Icons.call_split),
      label: Text('拆分 PDF'),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.compress_outlined),
      selectedIcon: Icon(Icons.compress),
      label: Text('压缩 PDF'),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          final extended = constraints.maxWidth >= 900;
          return Row(
            children: [
              SafeArea(
                child: NavigationRail(
                  selectedIndex: _index,
                  onDestinationSelected: (i) => setState(() => _index = i),
                  extended: extended,
                  minExtendedWidth: 160,
                  leading: Padding(
                    padding: EdgeInsets.symmetric(
                      vertical: 16,
                      horizontal: extended ? 16 : 0,
                    ),
                    child: Column(
                      children: [
                        Icon(
                          Icons.description_outlined,
                          size: 32,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        if (extended) ...[
                          const SizedBox(height: 4),
                          Text(
                            'LM 工具箱',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ],
                      ],
                    ),
                  ),
                  destinations: _destinations,
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: IndexedStack(
                  index: _index,
                  children: const [
                    MergePage(),
                    SplitPage(),
                    CompressPage(),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
