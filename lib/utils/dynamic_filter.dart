import 'dart:convert';

import 'package:PiliPlus/models/common/dynamic/dynamics_type.dart';
import 'package:PiliPlus/models/dynamics/result.dart';
import 'package:PiliPlus/models/dynamics/up.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';

class DynamicFilterTextRule {
  DynamicFilterTextRule({
    required this.text,
    this.regex = false,
    this.enabled = true,
  });

  final String text;
  final bool regex;
  final bool enabled;

  factory DynamicFilterTextRule.fromJson(Map<String, dynamic> json) =>
      DynamicFilterTextRule(
        text: json['text']?.toString() ?? '',
        regex: json['regex'] == true,
        enabled: json['enabled'] != false,
      );

  Map<String, dynamic> toJson() => {
    'text': text,
    'regex': regex,
    'enabled': enabled,
  };
}

class DynamicFilterForwardUserRule {
  DynamicFilterForwardUserRule({
    required this.mid,
    this.name = '',
    this.enabled = true,
  });

  final int mid;
  final String name;
  final bool enabled;

  factory DynamicFilterForwardUserRule.fromJson(Map<String, dynamic> json) =>
      DynamicFilterForwardUserRule(
        mid: int.tryParse(json['mid']?.toString() ?? '') ?? 0,
        name: json['name']?.toString() ?? '',
        enabled: json['enabled'] != false,
      );

  Map<String, dynamic> toJson() => {
    'mid': mid,
    'name': name,
    'enabled': enabled,
  };
}

abstract final class DynamicFilter {
  static const List<String> defaultTextRules = [
    '美团',
    '闪购',
    '外卖券',
    '优惠券',
    '领券',
    '红包',
    '下单',
    '返利',
    '折扣',
    '秒杀',
    '拼多多',
    '京东',
    '淘宝',
    '天猫',
    '饿了么',
    '得物',
    '携程',
    '飞猪',
    '带货',
    '团购',
    '直播间下单',
    '购买链接',
  ];

  static const List<String> _forwardModifyWords = [
    '更新',
    '修正',
    '补充',
    '更换',
    '新增',
    '修改',
    '勘误',
    '更正',
    '追加',
    '说明',
    '替换',
  ];

  static const List<String> _lotteryWords = ['抽奖', '开奖', '转发抽', '评论抽'];

  static bool _loaded = false;
  static bool _enabled = false;
  static bool _textEnabled = true;
  static bool _shortForwardEnabled = true;
  static bool _liveStartEnabled = true;
  static bool _liveReserveEnabled = true;
  static bool _forwardUserEnabled = true;
  static bool _liveReplayEnabled = true;
  static List<DynamicFilterTextRule> _textRules = const [];
  static Set<int> _forwardUserMids = const {};
  static Set<int> _followedMids = const {};

  static void reload() {
    _enabled = _getBool(SettingBoxKey.dynamicFilterEnable);
    _textEnabled = _getBool(SettingBoxKey.dynamicFilterTextEnable, true);
    _shortForwardEnabled = _getBool(
      SettingBoxKey.dynamicFilterShortForwardEnable,
      true,
    );
    _liveStartEnabled = _getBool(
      SettingBoxKey.dynamicFilterLiveStartEnable,
      true,
    );
    _liveReserveEnabled = _getBool(
      SettingBoxKey.dynamicFilterLiveReserveEnable,
      true,
    );
    _forwardUserEnabled = _getBool(
      SettingBoxKey.dynamicFilterForwardUserEnable,
      true,
    );
    _liveReplayEnabled = _getBool(
      SettingBoxKey.dynamicFilterLiveReplayEnable,
      true,
    );
    _textRules = readTextRules();
    _forwardUserMids = readForwardUserRules()
        .where((e) => e.enabled && e.mid > 0)
        .map((e) => e.mid)
        .toSet();
    _loaded = true;
  }

  static void setFollowedUps(Iterable<UpItem> items) {
    _followedMids = items.map((e) => e.mid).where((e) => e > 0).toSet();
  }

  static bool shouldHide(DynamicItemModel item, DynamicsTabType type) {
    if (!_loaded) reload();
    if (!_enabled) return false;

    if (_textEnabled && _matchesText(item)) return true;
    if (_shortForwardEnabled && _isShortForwardFromFollowed(item)) return true;
    if (_liveStartEnabled && _isLiveStart(item)) return true;
    if (_liveReserveEnabled && _isSmallReserveWithoutLottery(item)) return true;
    if (_forwardUserEnabled && _isForwardFromBlockedUser(item)) return true;
    if (_liveReplayEnabled && _isLiveReplay(item)) return true;

    return false;
  }

  static List<DynamicFilterTextRule> readTextRules() =>
      _readList(
            SettingBoxKey.dynamicFilterTextRules,
          )
          .map(DynamicFilterTextRule.fromJson)
          .where((e) => e.text.isNotEmpty)
          .toList();

  static Future<void> saveTextRules(
    List<DynamicFilterTextRule> rules,
  ) async {
    await _saveList(
      SettingBoxKey.dynamicFilterTextRules,
      rules.map((e) => e.toJson()).toList(),
    );
    reload();
  }

  static List<DynamicFilterForwardUserRule> readForwardUserRules() => _readList(
    SettingBoxKey.dynamicFilterForwardUsers,
  ).map(DynamicFilterForwardUserRule.fromJson).where((e) => e.mid > 0).toList();

  static Future<void> saveForwardUserRules(
    List<DynamicFilterForwardUserRule> rules,
  ) async {
    await _saveList(
      SettingBoxKey.dynamicFilterForwardUsers,
      rules.map((e) => e.toJson()).toList(),
    );
    reload();
  }

  static bool _getBool(String key, [bool defaultValue = false]) =>
      GStorage.setting.get(key, defaultValue: defaultValue);

  static List<Map<String, dynamic>> _readList(String key) {
    final value = GStorage.setting.get(key, defaultValue: '[]');
    try {
      final json = jsonDecode(value.toString());
      if (json is List) {
        return json.whereType<Map>().map(Map<String, dynamic>.from).toList();
      }
    } catch (_) {}
    return const [];
  }

  static Future<void> _saveList(
    String key,
    List<Map<String, dynamic>> value,
  ) => GStorage.setting.put(key, jsonEncode(value));

  static bool _matchesText(DynamicItemModel item) {
    final text =
        '${_textOf(item)} ${item.orig == null ? '' : _textOf(item.orig!)}';
    if (text.isEmpty) return false;
    if (defaultTextRules.any(text.contains)) return true;
    return _textRules.any((rule) {
      if (!rule.enabled) return false;
      if (rule.regex) {
        try {
          return RegExp(rule.text, caseSensitive: false).hasMatch(text);
        } catch (_) {
          return false;
        }
      }
      return text.toLowerCase().contains(rule.text.toLowerCase());
    });
  }

  static bool _isForwardFromBlockedUser(DynamicItemModel item) =>
      item.type == 'DYNAMIC_TYPE_FORWARD' &&
      _forwardUserMids.contains(item.modules.moduleAuthor?.mid);

  static bool _isShortForwardFromFollowed(DynamicItemModel item) {
    if (item.type != 'DYNAMIC_TYPE_FORWARD') return false;
    final origMid = item.orig?.modules.moduleAuthor?.mid;
    if (origMid == null || !_followedMids.contains(origMid)) return false;

    final text = item.modules.moduleDynamic?.desc?.text ?? '';
    if (_forwardModifyWords.any(text.contains)) return false;
    return _cjkCount(_cleanForwardText(text)) < 10;
  }

  static bool _isLiveStart(DynamicItemModel item) =>
      item.type == 'DYNAMIC_TYPE_LIVE' ||
      item.type == 'DYNAMIC_TYPE_LIVE_RCMD' ||
      item.modules.moduleDynamic?.major?.live != null ||
      item.modules.moduleDynamic?.major?.liveRcmd != null;

  static bool _isSmallReserveWithoutLottery(DynamicItemModel item) {
    final additional = item.modules.moduleDynamic?.additional;
    final reserve = additional?.reserve;
    if (additional?.type != 'ADDITIONAL_TYPE_RESERVE' || reserve == null) {
      return false;
    }
    final text = [
      item.modules.moduleDynamic?.desc?.text,
      reserve.title,
      reserve.desc1?.text,
      reserve.desc2?.text,
      reserve.desc3?.text,
    ].whereType<String>().join();
    if (_lotteryWords.any(text.contains)) return false;
    return _cjkCount(_cleanForwardText(text)) <= 15;
  }

  static bool _isLiveReplay(DynamicItemModel item) {
    final text = _textOf(item);
    final major = item.modules.moduleDynamic?.major;
    return text.contains('直播回放') ||
        text.contains('直播录像') ||
        text.contains('录播') ||
        major?.archive?.badge?.text == '直播回放' ||
        major?.ugcSeason?.badge?.text == '直播回放';
  }

  static String _textOf(DynamicItemModel item) {
    final dynamic = item.modules.moduleDynamic;
    final major = dynamic?.major;
    final additional = dynamic?.additional;
    return [
      dynamic?.desc?.text,
      major?.opus?.title,
      major?.opus?.summary?.text,
      major?.archive?.title,
      major?.ugcSeason?.title,
      major?.pgc?.title,
      major?.courses?.title,
      major?.common?.title,
      major?.common?.desc,
      major?.upowerCommon?.title,
      major?.music?.title,
      major?.medialist?.title,
      additional?.reserve?.title,
      additional?.reserve?.desc1?.text,
      additional?.reserve?.desc2?.text,
      additional?.reserve?.desc3?.text,
      additional?.common?.title,
      additional?.common?.desc1,
      additional?.common?.desc2,
      additional?.ugc?.title,
      additional?.vote?.title,
      dynamic?.topic?.name,
    ].whereType<String>().join(' ');
  }

  static String _cleanForwardText(String text) => text
      .replaceAll(RegExp(r'@[\u4e00-\u9fa5A-Za-z0-9_\-]+'), '')
      .replaceAll(RegExp(r'[^\u4e00-\u9fa5]'), '');

  static int _cjkCount(String text) =>
      RegExp(r'[\u4e00-\u9fa5]').allMatches(text).length;
}
