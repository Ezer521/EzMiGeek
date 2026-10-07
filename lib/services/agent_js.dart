// agent_js.dart —— 注入脚本加载（从资产读，只读一次缓存）。
library;

import 'package:flutter/services.dart' show rootBundle;

String? _source;

Future<String> loadAgentJs() async {
  final cached = _source;
  if (cached != null) return cached;
  final data = await rootBundle.loadString('assets/agent.js');
  _source = data;
  return data;
}
