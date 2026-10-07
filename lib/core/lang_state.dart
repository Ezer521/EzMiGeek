// lang_state.dart —— 当前界面语言（i18n 的内存态；落盘在 settings.json LangZh）。
library;

String _lang = 'zh';

abstract final class LangState {
  static String get current => _lang;
  static bool get zh => _lang == 'zh';
  static void set(String v) => _lang = v == 'en' ? 'en' : 'zh';
}
