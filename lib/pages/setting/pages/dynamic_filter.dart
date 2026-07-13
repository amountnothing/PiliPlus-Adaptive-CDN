import 'package:PiliPlus/utils/dynamic_filter.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

class DynamicFilterSettingsPage extends StatefulWidget {
  const DynamicFilterSettingsPage({super.key});

  @override
  State<DynamicFilterSettingsPage> createState() =>
      _DynamicFilterSettingsPageState();
}

class _DynamicFilterSettingsPageState extends State<DynamicFilterSettingsPage> {
  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.viewPaddingOf(context);
    return Scaffold(
      appBar: AppBar(title: const Text('动态过滤')),
      body: ListView(
        padding: EdgeInsets.only(
          left: padding.left,
          right: padding.right,
          bottom: padding.bottom + 100,
        ),
        children: [
          _switchTile(
            title: '文本匹配',
            subtitle: '广告词/自定义词，支持正则',
            keyName: SettingBoxKey.dynamicFilterTextEnable,
            defaultValue: true,
            route: '/dynamicFilter/text',
          ),
          _switchTile(
            title: '短转发刷屏',
            subtitle: '原动态作者已关注，转发正文很短且不是更新/修正类说明',
            keyName: SettingBoxKey.dynamicFilterShortForwardEnable,
            defaultValue: true,
          ),
          _switchTile(
            title: '开始直播动态',
            subtitle: '过滤“正在直播/开播”类动态',
            keyName: SettingBoxKey.dynamicFilterLiveStartEnable,
            defaultValue: true,
          ),
          _switchTile(
            title: '短直播预约',
            subtitle: '过滤非抽奖、正文较短的直播预约',
            keyName: SettingBoxKey.dynamicFilterLiveReserveEnable,
            defaultValue: true,
          ),
          _switchTile(
            title: '指定用户的转发动态',
            subtitle: '按 UID 过滤某些关注用户的所有转发',
            keyName: SettingBoxKey.dynamicFilterForwardUserEnable,
            defaultValue: true,
            route: '/dynamicFilter/users',
          ),
          _switchTile(
            title: '直播回放动态',
            subtitle: '过滤标题/徽标标记为直播回放、录播的动态',
            keyName: SettingBoxKey.dynamicFilterLiveReplayEnable,
            defaultValue: true,
          ),
        ],
      ),
    );
  }

  Widget _switchTile({
    required String title,
    required String subtitle,
    required String keyName,
    required bool defaultValue,
    String? route,
  }) {
    final value = GStorage.setting.get(keyName, defaultValue: defaultValue);
    return ListTile(
      leading: const Icon(Icons.filter_alt_outlined),
      title: Text(title),
      subtitle: Text(subtitle),
      onTap: route == null
          ? () => _set(keyName, !value)
          : () => Get.toNamed(route),
      trailing: Switch(
        value: value,
        onChanged: (value) => _set(keyName, value),
      ),
    );
  }

  Future<void> _set(String keyName, bool value) async {
    await GStorage.setting.put(keyName, value);
    DynamicFilter.reload();
    if (mounted) setState(() {});
  }
}

class DynamicFilterTextRulesPage extends StatefulWidget {
  const DynamicFilterTextRulesPage({super.key});

  @override
  State<DynamicFilterTextRulesPage> createState() =>
      _DynamicFilterTextRulesPageState();
}

class _DynamicFilterTextRulesPageState
    extends State<DynamicFilterTextRulesPage> {
  late List<DynamicFilterTextRule> _rules;

  @override
  void initState() {
    super.initState();
    _rules = DynamicFilter.readTextRules();
  }

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.viewPaddingOf(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('文本匹配'),
        actions: [
          IconButton(
            tooltip: '添加',
            onPressed: _editRule,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.only(
          left: padding.left,
          right: padding.right,
          bottom: padding.bottom + 100,
        ),
        children: [
          ListTile(
            leading: const Icon(Icons.text_fields),
            title: const Text('内置广告词'),
            subtitle: Text(DynamicFilter.defaultTextRules.join('、')),
          ),
          const Divider(height: 1),
          if (_rules.isEmpty)
            const ListTile(
              title: Text('还没有自定义匹配项'),
              subtitle: Text('右上角添加；内置广告词仍会生效'),
            )
          else
            for (var i = 0; i < _rules.length; i++) _ruleTile(i),
        ],
      ),
    );
  }

  Widget _ruleTile(int index) {
    final rule = _rules[index];
    return ListTile(
      title: Text(rule.text),
      subtitle: Text(rule.regex ? '正则表达式' : '普通文本'),
      leading: const Icon(Icons.short_text),
      onTap: () => _editRule(index),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch(
            value: rule.enabled,
            onChanged: (value) {
              _rules[index] = DynamicFilterTextRule(
                text: rule.text,
                regex: rule.regex,
                enabled: value,
              );
              _save();
            },
          ),
          IconButton(
            tooltip: '删除',
            icon: const Icon(Icons.delete_outline),
            onPressed: () {
              _rules.removeAt(index);
              _save();
            },
          ),
        ],
      ),
    );
  }

  Future<void> _editRule([int? index]) async {
    final oldRule = index == null ? null : _rules[index];
    String text = oldRule?.text ?? '';
    bool regex = oldRule?.regex ?? false;
    final result = await showDialog<DynamicFilterTextRule>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(index == null ? '添加匹配项' : '编辑匹配项'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                autofocus: true,
                initialValue: text,
                decoration: const InputDecoration(labelText: '文本/正则'),
                onChanged: (value) => text = value,
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('按正则表达式匹配'),
                value: regex,
                onChanged: (value) =>
                    setDialogState(() => regex = value == true),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: Get.back, child: const Text('取消')),
            TextButton(
              child: const Text('保存'),
              onPressed: () {
                final value = text.trim();
                if (value.isEmpty) {
                  SmartDialog.showToast('匹配内容不能为空');
                  return;
                }
                if (regex) {
                  try {
                    RegExp(value);
                  } catch (_) {
                    SmartDialog.showToast('正则表达式无效');
                    return;
                  }
                }
                Get.back(
                  result: DynamicFilterTextRule(
                    text: value,
                    regex: regex,
                    enabled: oldRule?.enabled ?? true,
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
    if (result == null) return;
    if (index == null) {
      _rules.add(result);
    } else {
      _rules[index] = result;
    }
    await _save();
  }

  Future<void> _save() async {
    await DynamicFilter.saveTextRules(_rules);
    if (mounted) setState(() {});
  }
}

class DynamicFilterForwardUsersPage extends StatefulWidget {
  const DynamicFilterForwardUsersPage({super.key});

  @override
  State<DynamicFilterForwardUsersPage> createState() =>
      _DynamicFilterForwardUsersPageState();
}

class _DynamicFilterForwardUsersPageState
    extends State<DynamicFilterForwardUsersPage> {
  late List<DynamicFilterForwardUserRule> _rules;

  @override
  void initState() {
    super.initState();
    _rules = DynamicFilter.readForwardUserRules();
  }

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.viewPaddingOf(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('指定转发用户'),
        actions: [
          IconButton(
            tooltip: '添加',
            onPressed: _editRule,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.only(
          left: padding.left,
          right: padding.right,
          bottom: padding.bottom + 100,
        ),
        children: [
          if (_rules.isEmpty)
            const ListTile(
              title: Text('还没有指定用户'),
              subtitle: Text('添加 UID 后，该用户的转发动态会被过滤'),
            )
          else
            for (var i = 0; i < _rules.length; i++) _ruleTile(i),
        ],
      ),
    );
  }

  Widget _ruleTile(int index) {
    final rule = _rules[index];
    return ListTile(
      title: Text(rule.name.isEmpty ? rule.mid.toString() : rule.name),
      subtitle: Text('UID: ${rule.mid}'),
      leading: const Icon(Icons.person_off_outlined),
      onTap: () => _editRule(index),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch(
            value: rule.enabled,
            onChanged: (value) {
              _rules[index] = DynamicFilterForwardUserRule(
                mid: rule.mid,
                name: rule.name,
                enabled: value,
              );
              _save();
            },
          ),
          IconButton(
            tooltip: '删除',
            icon: const Icon(Icons.delete_outline),
            onPressed: () {
              _rules.removeAt(index);
              _save();
            },
          ),
        ],
      ),
    );
  }

  Future<void> _editRule([int? index]) async {
    final oldRule = index == null ? null : _rules[index];
    String mid = oldRule?.mid.toString() ?? '';
    String name = oldRule?.name ?? '';
    final result = await showDialog<DynamicFilterForwardUserRule>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(index == null ? '添加用户' : '编辑用户'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              autofocus: true,
              initialValue: mid,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: 'UID'),
              onChanged: (value) => mid = value,
            ),
            TextFormField(
              initialValue: name,
              decoration: const InputDecoration(labelText: '备注名（可选）'),
              onChanged: (value) => name = value,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: Get.back, child: const Text('取消')),
          TextButton(
            child: const Text('保存'),
            onPressed: () {
              final value = int.tryParse(mid);
              if (value == null || value <= 0) {
                SmartDialog.showToast('UID 无效');
                return;
              }
              Get.back(
                result: DynamicFilterForwardUserRule(
                  mid: value,
                  name: name.trim(),
                  enabled: oldRule?.enabled ?? true,
                ),
              );
            },
          ),
        ],
      ),
    );
    if (result == null) return;
    if (index == null) {
      _rules.add(result);
    } else {
      _rules[index] = result;
    }
    await _save();
  }

  Future<void> _save() async {
    await DynamicFilter.saveForwardUserRules(_rules);
    if (mounted) setState(() {});
  }
}
