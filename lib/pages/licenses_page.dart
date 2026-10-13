import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

/// 开源许可页：GPL 全文与第三方组件声明随二进制分发
/// （GPLv3 §4/§5：以目标代码形式分发时，接收者须能取得许可副本）。
class LicensesPage extends StatelessWidget {
  const LicensesPage({super.key});

  static const _titles = ['GPL-3.0', '第三方声明'];
  static const _assets = ['LICENSE', 'THIRD-PARTY-NOTICES.md'];

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: _titles.length,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('开源许可'),
          bottom: TabBar(tabs: [for (final t in _titles) Tab(text: t)]),
        ),
        body: TabBarView(
          children: [for (final a in _assets) _LicenseView(asset: a)],
        ),
      ),
    );
  }
}

class _LicenseView extends StatelessWidget {
  const _LicenseView({required this.asset});
  final String asset;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: rootBundle.loadString(asset),
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('无法读取 $asset：${snap.error}'),
            ),
          );
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        return SelectionArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Text(
              snap.data!,
              style: const TextStyle(fontSize: 12, height: 1.5),
            ),
          ),
        );
      },
    );
  }
}
