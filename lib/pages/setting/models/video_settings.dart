import 'dart:io';

import 'package:PiliPlus/models/common/video/audio_quality.dart';
import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/models/common/video/live_quality.dart';
import 'package:PiliPlus/models/common/video/video_decode_type.dart';
import 'package:PiliPlus/models/common/video/video_quality.dart';
import 'package:PiliPlus/pages/setting/models/model.dart';
import 'package:PiliPlus/pages/setting/widgets/ordered_multi_select_dialog.dart';
import 'package:PiliPlus/pages/setting/widgets/select_dialog.dart';
import 'package:PiliPlus/plugin/pl_player/models/audio_output_type.dart';
import 'package:PiliPlus/plugin/pl_player/models/hwdec_type.dart';
import 'package:PiliPlus/services/cdn_score_service.dart';
import 'package:PiliPlus/utils/adaptive_playback.dart';
import 'package:PiliPlus/utils/filtering_text.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

List<SettingsModel> get _adaptivePlaybackSettings => [
  NormalModel(
    title: '自适应首选解码',
    leading: const Icon(Icons.movie_filter_outlined),
    getSubtitle: () =>
        '当前：${VideoDecodeFormatType.fromCode(Pref.adaptivePreferredDecode).description}',
    enabledListenable: AdaptivePlayback.enabled,
    onTap: _showAdaptivePreferredDecodeDialog,
  ),
  NormalModel(
    title: '冻结恢复解码',
    leading: const Icon(Icons.video_settings_outlined),
    getSubtitle: () =>
        '画面冻结/码流错误时尝试切到 ${VideoDecodeFormatType.fromCode(Pref.adaptiveRecoveryDecode).description}',
    enabledListenable: AdaptivePlayback.enabled,
    onTap: _showAdaptiveRecoveryDecodeDialog,
  ),
  NormalModel(
    title: '目标缓冲时长',
    leading: const Icon(Icons.hourglass_top_rounded),
    getSubtitle: () =>
        '目标 ${Pref.adaptiveTargetBufferSec}s；当前回填观察线 ${Pref.adaptiveRefillBufferSec}s',
    enabledListenable: AdaptivePlayback.enabled,
    onTap: _showAdaptiveTargetBufferDialog,
  ),
  NormalModel(
    title: '回填触发容差',
    leading: const Icon(Icons.av_timer_outlined),
    getSubtitle: () =>
        '距目标 ${Pref.adaptiveSegmentToleranceSec}s 时进入回填区；实际观察线 ${Pref.adaptiveRefillBufferSec}s',
    enabledListenable: AdaptivePlayback.enabled,
    onTap: _showAdaptiveSegmentToleranceDialog,
  ),
  NormalModel(
    title: 'PTS 冻结检测缓冲阈值',
    leading: const Icon(Icons.water_outlined),
    getSubtitle: () => '前向缓冲至少 ${Pref.adaptiveLowBufferSec}s 时，才把时间戳不前进判为解码冻结',
    enabledListenable: AdaptivePlayback.enabled,
    onTap: _showAdaptiveLowBufferDialog,
  ),
  NormalModel(
    title: '缓冲停滞最小增长',
    leading: const Icon(Icons.trending_up_rounded),
    getSubtitle: () =>
        '进入回填区后，窗口内净增长不足 ${Pref.adaptiveLowBufferStutterMinGrowthSec}s 时切换 CDN',
    enabledListenable: AdaptivePlayback.enabled,
    onTap: _showAdaptiveLowBufferStutterMinGrowthDialog,
  ),
  NormalModel(
    title: '缓冲停滞检测窗口',
    leading: const Icon(Icons.timer_off_outlined),
    getSubtitle: () =>
        '每次进入回填区后观察 ${Pref.adaptiveStallTimeoutSec}s，不使用独立网络读取超时',
    enabledListenable: AdaptivePlayback.enabled,
    onTap: _showAdaptiveStallTimeoutDialog,
  ),

  NormalModel(
    title: '故障 CDN 冷却',
    leading: const Icon(Icons.ac_unit_outlined),
    getSubtitle: () => '全局冷却 ${Pref.adaptiveCdnCooldownSec}s，当前视频内永久排除',
    enabledListenable: AdaptivePlayback.enabled,
    onTap: _showAdaptiveCdnCooldownDialog,
  ),
  NormalModel(
    title: '单视频最大切换次数',
    leading: const Icon(Icons.swap_horiz_rounded),
    getSubtitle: () => Pref.adaptiveTraverseAllCdns
        ? '遍历全部 CDN 已开启，此项暂不生效'
        : '当前：${Pref.adaptiveMaxCdnSwitches.round()} 次',
    enabledListenable: AdaptivePlayback.enabled,
    onTap: _showAdaptiveMaxSwitchesDialog,
  ),
  SwitchModel(
    title: '遍历全部 CDN',
    subtitle: '卡顿未恢复时按评分降序尝试所有候选 CDN',
    leading: const Icon(Icons.format_list_numbered_rounded),
    setKey: SettingBoxKey.adaptiveTraverseAllCdns,
    defaultVal: true,
    enabledListenable: AdaptivePlayback.enabled,
  ),
  NormalModel(
    title: 'CDN 稳定性评分',
    leading: const Icon(Icons.leaderboard_outlined),
    getSubtitle: _cdnScoreSummary,
    enabledListenable: AdaptivePlayback.enabled,
    onTap: _showCdnScoresDialog,
  ),
];
List<SettingsModel> get videoSettings => [
  const SwitchModel(
    title: '自适应播放',
    subtitle: '可配置解码优先级、动态缓冲并在缓冲净增长停滞时自动切换 CDN',
    leading: Icon(Icons.auto_awesome_outlined),
    setKey: SettingBoxKey.adaptivePlayback,
    defaultVal: false,
    onChanged: AdaptivePlayback.setEnabled,
    needReboot: true,
  ),
  NormalModel(
    title: '自适应播放详细设置',
    leading: const Icon(Icons.tune_rounded),
    getSubtitle: () =>
        '${VideoDecodeFormatType.fromCode(Pref.adaptivePreferredDecode).description} 优先，冻结恢复 ${VideoDecodeFormatType.fromCode(Pref.adaptiveRecoveryDecode).description}',
    enabledListenable: AdaptivePlayback.enabled,
    onTap: _openAdaptivePlaybackSettings,
  ),
  SwitchModel(
    title: '开启硬解',
    subtitle: '以较低功耗播放视频，若异常卡死请关闭',
    leading: const Icon(Icons.flash_on_outlined),
    setKey: SettingBoxKey.enableHA,
    defaultVal: true,
    enabledListenable: AdaptivePlayback.manualControlsEnabled,
  ),
  const SwitchModel(
    title: '免登录1080P',
    subtitle: '免登录查看1080P视频',
    leading: Icon(Icons.hd_outlined),
    setKey: SettingBoxKey.p1080,
    defaultVal: true,
  ),
  NormalModel(
    title: 'B站定向流量支持',
    subtitle: '若套餐含B站定向流量，则会自动使用。可查阅运营商的流量记录确认。',
    leading: const Icon(Icons.perm_data_setting_outlined),
    getTrailing: (theme) => IgnorePointer(
      child: Transform.scale(
        scale: 0.8,
        alignment: Alignment.centerRight,
        child: Switch(
          value: true,
          onChanged: (_) {},
          thumbIcon: WidgetStateProperty.all(
            const Icon(Icons.lock_outline_rounded),
          ),
        ),
      ),
    ),
  ),
  NormalModel(
    title: 'CDN 设置',
    leading: const Icon(MdiIcons.cloudPlusOutline),
    getSubtitle: () =>
        '当前使用：${VideoUtils.cdnService.desc}，部分 CDN 可能失效，如无法播放请尝试切换',
    onTap: _showCDNDialog,
    enabledListenable: AdaptivePlayback.manualControlsEnabled,
  ),
  NormalModel(
    title: '直播 CDN 设置',
    leading: const Icon(MdiIcons.cloudPlusOutline),
    getSubtitle: () => '当前使用：${Pref.liveCdnUrl ?? "默认"}',
    onTap: _showLiveCDNDialog,
  ),
  SwitchModel(
    title: 'CDN 测速',
    leading: const Icon(Icons.speed),
    subtitle: '测速通过模拟加载视频实现，注意流量消耗，结果仅供参考',
    setKey: SettingBoxKey.cdnSpeedTest,
    defaultVal: true,
    enabledListenable: AdaptivePlayback.manualControlsEnabled,
  ),
  SwitchModel(
    title: '音频不跟随 CDN 设置',
    subtitle: '直接采用备用 URL，可解决部分视频无声',
    leading: const Icon(MdiIcons.musicNotePlus),
    setKey: SettingBoxKey.disableAudioCDN,
    defaultVal: false,
    onChanged: (value) => VideoUtils.disableAudioCDN = value,
    enabledListenable: AdaptivePlayback.manualControlsEnabled,
  ),
  NormalModel(
    title: '默认画质',
    leading: const Icon(Icons.video_settings_outlined),
    getSubtitle: () =>
        '当前画质：${VideoQuality.fromCode(Pref.defaultVideoQa).desc}',
    onTap: _showVideoQaDialog,
  ),
  NormalModel(
    title: '蜂窝网络画质',
    leading: const Icon(Icons.video_settings_outlined),
    getSubtitle: () =>
        '当前画质：${VideoQuality.fromCode(Pref.defaultVideoQaCellular).desc}',
    onTap: _showVideoCellularQaDialog,
  ),
  NormalModel(
    title: '默认音质',
    leading: const Icon(Icons.music_video_outlined),
    getSubtitle: () =>
        '当前音质：${AudioQuality.fromCode(Pref.defaultAudioQa).desc}',
    onTap: _showAudioQaDialog,
  ),
  NormalModel(
    title: '蜂窝网络音质',
    leading: const Icon(Icons.music_video_outlined),
    getSubtitle: () =>
        '当前音质：${AudioQuality.fromCode(Pref.defaultAudioQaCellular).desc}',
    onTap: _showAudioCellularQaDialog,
  ),
  NormalModel(
    title: '直播默认画质',
    leading: const Icon(Icons.video_settings_outlined),
    getSubtitle: () => '当前画质：${LiveQuality.fromCode(Pref.liveQuality)?.desc}',
    onTap: _showLiveQaDialog,
  ),
  NormalModel(
    title: '蜂窝网络直播默认画质',
    leading: const Icon(Icons.video_settings_outlined),
    getSubtitle: () =>
        '当前画质：${LiveQuality.fromCode(Pref.liveQualityCellular)?.desc}',
    onTap: _showLiveCellularQaDialog,
  ),
  NormalModel(
    title: '首选解码格式',
    leading: const Icon(Icons.movie_creation_outlined),
    getSubtitle: () =>
        '首选解码格式：${VideoDecodeFormatType.fromCode(Pref.defaultDecode).description}，请根据设备支持情况与需求调整',
    onTap: _showDecodeDialog,
    enabledListenable: AdaptivePlayback.manualControlsEnabled,
  ),
  NormalModel(
    title: '次选解码格式',
    getSubtitle: () =>
        '非杜比视频次选：${VideoDecodeFormatType.fromCode(Pref.secondDecode).description}，仍无则选择首个提供的解码格式',
    leading: const Icon(Icons.swap_horizontal_circle_outlined),
    onTap: _showSecondDecodeDialog,
    enabledListenable: AdaptivePlayback.manualControlsEnabled,
  ),
  if (kDebugMode || Platform.isAndroid)
    NormalModel(
      title: '音频输出设备',
      leading: const Icon(Icons.speaker_outlined),
      getSubtitle: () => '当前：${Pref.audioOutput}',
      onTap: _showAudioOutputDialog,
    ),
  NormalModel(
    title: '缓冲大小',
    leading: const Icon(Icons.storage_outlined),
    getSubtitle: () =>
        '当前：${Pref.bufferSize}MB。同时为前向和后向缓冲区大小。对于直播流，无后向缓冲大小，全部转给前向（此选项即mpv的--demuxer-max-bytes，--demuxer-max-back-bytes）',
    onTap: _showBufferSizeDialog,
    enabledListenable: AdaptivePlayback.manualControlsEnabled,
  ),
  NormalModel(
    title: '缓冲时长',
    leading: const Icon(Icons.av_timer),
    getSubtitle: () =>
        '当前：${Pref.bufferSec}s。实际缓冲为二者最小值。对于直播流，该选项无效（此选项即mpv的--cache-secs）',
    onTap: _showBufferSecDialog,
    enabledListenable: AdaptivePlayback.manualControlsEnabled,
  ),
  NormalModel(
    title: '自动同步',
    leading: const Icon(Icons.sync_rounded),
    getSubtitle: () => '当前：${Pref.autosync}（此项即mpv的--autosync）',
    onTap: _showAutoSyncDialog,
  ),
  NormalModel(
    title: '视频同步',
    leading: const Icon(Icons.view_timeline_outlined),
    getSubtitle: () => '当前：${Pref.videoSync}（此项即mpv的--video-sync）',
    onTap: _showVideoSyncDialog,
  ),
  NormalModel(
    title: '硬解模式',
    leading: const Icon(Icons.memory_outlined),
    getSubtitle: () => '当前：${Pref.hardwareDecoding}（此项即mpv的--hwdec）',
    onTap: _showHwDecDialog,
    enabledListenable: AdaptivePlayback.manualControlsEnabled,
  ),
];

Future<void> _showCDNDialog(BuildContext context, VoidCallback setState) async {
  final res = await showDialog<CDNService>(
    context: context,
    builder: (context) => const CdnSelectDialog(),
  );
  if (res != null) {
    VideoUtils.cdnService = res;
    await GStorage.setting.put(SettingBoxKey.CDNService, res.name);
    setState();
  }
}

Future<void> _showLiveCDNDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  String host = Pref.liveCdnUrl ?? '';
  String? res = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('输入CDN host'),
      content: TextFormField(
        initialValue: host,
        autofocus: true,
        onChanged: (value) => host = value,
      ),
      actions: [
        TextButton(
          onPressed: Get.back,
          child: Text(
            '取消',
            style: TextStyle(color: ColorScheme.of(context).outline),
          ),
        ),
        TextButton(
          onPressed: () => Get.back(result: host),
          child: const Text('确定'),
        ),
      ],
    ),
  );
  if (res != null) {
    if (res.isEmpty) {
      res = null;
      await GStorage.setting.delete(SettingBoxKey.liveCdnUrl);
    } else {
      if (!res.startsWith('http')) {
        res = 'https://$res';
      }
      await GStorage.setting.put(SettingBoxKey.liveCdnUrl, res);
    }
    VideoUtils.liveCdnUrl = res;
    setState();
  }
}

Future<void> _showVideoQaDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<int>(
    context: context,
    builder: (context) => SelectDialog<int>(
      title: '默认画质',
      value: Pref.defaultVideoQa,
      values: VideoQuality.values.map((e) => (e.code, e.desc)).toList(),
    ),
  );
  if (res != null) {
    await GStorage.setting.put(SettingBoxKey.defaultVideoQa, res);
    setState();
  }
}

Future<void> _showVideoCellularQaDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<int>(
    context: context,
    builder: (context) => SelectDialog<int>(
      title: '蜂窝网络画质',
      value: Pref.defaultVideoQaCellular,
      values: VideoQuality.values.map((e) => (e.code, e.desc)).toList(),
    ),
  );
  if (res != null) {
    await GStorage.setting.put(
      SettingBoxKey.defaultVideoQaCellular,
      res,
    );
    setState();
  }
}

Future<void> _showAudioQaDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<int>(
    context: context,
    builder: (context) => SelectDialog<int>(
      title: '默认音质',
      value: Pref.defaultAudioQa,
      values: AudioQuality.values.map((e) => (e.code, e.desc)).toList(),
    ),
  );
  if (res != null) {
    await GStorage.setting.put(SettingBoxKey.defaultAudioQa, res);
    setState();
  }
}

Future<void> _showAudioCellularQaDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<int>(
    context: context,
    builder: (context) => SelectDialog<int>(
      title: '蜂窝网络音质',
      value: Pref.defaultAudioQaCellular,
      values: AudioQuality.values.map((e) => (e.code, e.desc)).toList(),
    ),
  );
  if (res != null) {
    await GStorage.setting.put(
      SettingBoxKey.defaultAudioQaCellular,
      res,
    );
    setState();
  }
}

Future<void> _showLiveQaDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<int>(
    context: context,
    builder: (context) => SelectDialog<int>(
      title: '直播默认画质',
      value: Pref.liveQuality,
      values: LiveQuality.values.map((e) => (e.code, e.desc)).toList(),
    ),
  );
  if (res != null) {
    await GStorage.setting.put(SettingBoxKey.liveQuality, res);
    setState();
  }
}

Future<void> _showLiveCellularQaDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<int>(
    context: context,
    builder: (context) => SelectDialog<int>(
      title: '蜂窝网络直播默认画质',
      value: Pref.liveQualityCellular,
      values: LiveQuality.values.map((e) => (e.code, e.desc)).toList(),
    ),
  );
  if (res != null) {
    await GStorage.setting.put(SettingBoxKey.liveQualityCellular, res);
    setState();
  }
}

Future<void> _showDecodeDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<String>(
    context: context,
    builder: (context) => SelectDialog<String>(
      title: '默认解码格式',
      value: Pref.defaultDecode,
      values: VideoDecodeFormatType.values
          .map((e) => (e.codes.first, e.description))
          .toList(),
    ),
  );
  if (res != null) {
    await GStorage.setting.put(SettingBoxKey.defaultDecode, res);
    setState();
  }
}

Future<void> _showSecondDecodeDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<String>(
    context: context,
    builder: (context) => SelectDialog<String>(
      title: '次选解码格式',
      value: Pref.secondDecode,
      values: VideoDecodeFormatType.values
          .map((e) => (e.codes.first, e.description))
          .toList(),
    ),
  );
  if (res != null) {
    await GStorage.setting.put(SettingBoxKey.secondDecode, res);
    setState();
  }
}

Future<void> _showAudioOutputDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<List<String>>(
    context: context,
    builder: (context) => OrderedMultiSelectDialog<String>(
      title: '音频输出设备',
      initValues: Pref.audioOutput.split(','),
      values: {
        for (final e in AudioOutput.values) e.name: e.label,
      },
    ),
  );
  if (res != null && res.isNotEmpty) {
    await GStorage.setting.put(
      SettingBoxKey.audioOutput,
      res.join(','),
    );
    setState();
  }
}

Future<void> _showVideoSyncDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<String>(
    context: context,
    builder: (context) => SelectDialog<String>(
      title: '视频同步',
      value: Pref.videoSync,
      values: const [
        'audio',
        'display-resample',
        'display-resample-vdrop',
        'display-resample-desync',
        'display-tempo',
        'display-vdrop',
        'display-adrop',
        'display-desync',
        'desync',
      ].map((e) => (e, e)).toList(),
    ),
  );
  if (res != null) {
    await GStorage.setting.put(SettingBoxKey.videoSync, res);
    setState();
  }
}

Future<void> _showHwDecDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<List<String>>(
    context: context,
    builder: (context) => OrderedMultiSelectDialog<String>(
      title: '硬解模式',
      initValues: Pref.hardwareDecoding.split(','),
      values: {
        for (final e in HwDecType.values) e.hwdec: '${e.hwdec}\n${e.desc}',
      },
    ),
  );
  if (res != null && res.isNotEmpty) {
    await GStorage.setting.put(
      SettingBoxKey.hardwareDecoding,
      res.join(','),
    );
    setState();
  }
}

void _showAutoSyncDialog(BuildContext context, VoidCallback setState) {
  String autosync = Pref.autosync.toString();
  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('自动同步'),
      content: TextFormField(
        autofocus: true,
        initialValue: autosync,
        keyboardType: TextInputType.number,
        onChanged: (value) => autosync = value,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      ),
      actions: [
        TextButton(
          onPressed: Get.back,
          child: Text(
            '取消',
            style: TextStyle(color: ColorScheme.of(context).outline),
          ),
        ),
        TextButton(
          onPressed: () async {
            try {
              // validate
              int.parse(autosync);
              Get.back();
              await GStorage.setting.put(SettingBoxKey.autosync, autosync);
              setState();
            } catch (e) {
              SmartDialog.showToast(e.toString());
            }
          },
          child: const Text('确定'),
        ),
      ],
    ),
  );
}

void _showDecimalDialog(
  BuildContext context,
  VoidCallback setState, {
  required String key,
  required double defVal,
  required String title,
  required String? suffix,
  double? minValue,
  double? maxValue,
  bool integer = false,
}) {
  String value = (GStorage.setting.get(key) ?? defVal).toString();
  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextFormField(
        autofocus: true,
        initialValue: value,
        keyboardType: const .numberWithOptions(decimal: true),
        onChanged: (val) => value = val,
        inputFormatters: FilteringText.decimal,
        decoration: suffix == null ? null : InputDecoration(suffixText: suffix),
      ),
      actions: [
        TextButton(
          onPressed: Get.back,
          child: Text(
            '取消',
            style: TextStyle(color: ColorScheme.of(context).outline),
          ),
        ),
        TextButton(
          onPressed: () async {
            try {
              var val = double.parse(value);
              if ((minValue != null && val < minValue) ||
                  (maxValue != null && val > maxValue)) {
                throw FormatException(
                  '请输入 ${minValue ?? "-∞"} 到 ${maxValue ?? "+∞"} 之间的数值',
                );
              }
              if (integer) val = val.roundToDouble();
              Get.back();
              await GStorage.setting.put(key, val);
              setState();
            } catch (e) {
              SmartDialog.showToast(e.toString());
            }
          },
          child: const Text('确定'),
        ),
      ],
    ),
  );
}

void _openAdaptivePlaybackSettings(
  BuildContext context,
  VoidCallback setState,
) {
  Navigator.of(context)
      .push(
        MaterialPageRoute<void>(
          builder: (context) => Scaffold(
            appBar: AppBar(title: const Text('自适应播放详细设置')),
            body: ListView.builder(
              padding: EdgeInsets.only(
                left: MediaQuery.viewPaddingOf(context).left,
                right: MediaQuery.viewPaddingOf(context).right,
                bottom: MediaQuery.viewPaddingOf(context).bottom + 100,
              ),
              itemCount: _adaptivePlaybackSettings.length,
              itemBuilder: (context, index) =>
                  _adaptivePlaybackSettings[index].widget,
            ),
          ),
        ),
      )
      .then((_) => setState());
}

Future<void> _showAdaptivePreferredDecodeDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<String>(
    context: context,
    builder: (context) => SelectDialog<String>(
      title: '自适应首选解码',
      value: Pref.adaptivePreferredDecode,
      values: VideoDecodeFormatType.values
          .map((e) => (e.codes.first, e.description))
          .toList(),
    ),
  );
  if (res != null) {
    await GStorage.setting.put(SettingBoxKey.adaptivePreferredDecode, res);
    setState();
  }
}

Future<void> _showAdaptiveRecoveryDecodeDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final res = await showDialog<String>(
    context: context,
    builder: (context) => SelectDialog<String>(
      title: '冻结恢复解码',
      value: Pref.adaptiveRecoveryDecode,
      values: VideoDecodeFormatType.values
          .map((e) => (e.codes.first, e.description))
          .toList(),
    ),
  );
  if (res != null) {
    await GStorage.setting.put(SettingBoxKey.adaptiveRecoveryDecode, res);
    setState();
  }
}

void _showAdaptiveTargetBufferDialog(
  BuildContext context,
  VoidCallback setState,
) => _showDecimalDialog(
  context,
  setState,
  key: SettingBoxKey.adaptiveTargetBufferSec,
  defVal: Pref.adaptiveTargetBufferSec,
  title: '目标缓冲时长',
  suffix: 's',
  minValue: 10,
  maxValue: 60,
);

void _showAdaptiveSegmentToleranceDialog(
  BuildContext context,
  VoidCallback setState,
) => _showDecimalDialog(
  context,
  setState,
  key: SettingBoxKey.adaptiveSegmentToleranceSec,
  defVal: Pref.adaptiveSegmentToleranceSec,
  title: '回填触发容差',
  suffix: 's',
  minValue: 0,
  maxValue: 30,
);

void _showAdaptiveLowBufferDialog(
  BuildContext context,
  VoidCallback setState,
) => _showDecimalDialog(
  context,
  setState,
  key: SettingBoxKey.adaptiveLowBufferSec,
  defVal: Pref.adaptiveLowBufferSec,
  title: 'PTS 冻结检测缓冲阈值',
  suffix: 's',
  minValue: 2,
  maxValue: 20,
);

void _showAdaptiveLowBufferStutterMinGrowthDialog(
  BuildContext context,
  VoidCallback setState,
) => _showDecimalDialog(
  context,
  setState,
  key: SettingBoxKey.adaptiveLowBufferStutterMinGrowthSec,
  defVal: Pref.adaptiveLowBufferStutterMinGrowthSec,
  title: '缓冲停滞最小增长',
  suffix: 's',
  minValue: 0,
  maxValue: 10,
);

void _showAdaptiveStallTimeoutDialog(
  BuildContext context,
  VoidCallback setState,
) => _showDecimalDialog(
  context,
  setState,
  key: SettingBoxKey.adaptiveStallTimeoutSec,
  defVal: Pref.adaptiveStallTimeoutSec,
  title: '缓冲停滞检测窗口',
  suffix: 's',
  minValue: 2,
  maxValue: 30,
);

void _showAdaptiveCdnCooldownDialog(
  BuildContext context,
  VoidCallback setState,
) => _showDecimalDialog(
  context,
  setState,
  key: SettingBoxKey.adaptiveCdnCooldownSec,
  defVal: Pref.adaptiveCdnCooldownSec,
  title: '故障 CDN 冷却',
  suffix: 's',
  minValue: 0,
  maxValue: 300,
);

void _showAdaptiveMaxSwitchesDialog(
  BuildContext context,
  VoidCallback setState,
) => _showDecimalDialog(
  context,
  setState,
  key: SettingBoxKey.adaptiveMaxCdnSwitches,
  defVal: Pref.adaptiveMaxCdnSwitches,
  title: '单视频最大切换次数',
  suffix: '次',
  minValue: 1,
  maxValue: 10,
  integer: true,
);

String _cdnScoreSummary() {
  final entries = _cdnScoreEntriesForDisplay();
  return entries
      .take(3)
      .map((item) => '${item.key} ${item.value.score.toStringAsFixed(0)}')
      .join(' · ');
}

List<MapEntry<String, CdnScoreEntry>> _cdnScoreEntriesForDisplay() {
  final entries = Map<String, CdnScoreEntry>.of(CdnScoreService.entries);
  for (final service in CDNService.values) {
    final host = service.host;
    if (host != null) entries.putIfAbsent(host, () => CdnScoreEntry.initial);
  }
  return entries.entries.toList()..sort((a, b) {
    final scoreCompare = b.value.score.compareTo(a.value.score);
    return scoreCompare != 0 ? scoreCompare : a.key.compareTo(b.key);
  });
}

Future<void> _showCdnScoresDialog(
  BuildContext context,
  VoidCallback setState,
) async {
  final entries = _cdnScoreEntriesForDisplay();
  final hasLearnedData = CdnScoreService.entries.isNotEmpty;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('CDN 稳定性评分'),
      content: SizedBox(
        width: 520,
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: entries.length,
          itemBuilder: (_, index) {
            final item = entries[index];
            final entry = item.value;
            final learned = entry.successes > 0 || entry.failures > 0;
            return ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(item.key),
              subtitle: Text(
                learned
                    ? '成功 ${entry.successes} · 故障 ${entry.failures} · '
                          '${entry.ewmaMbps.toStringAsFixed(1)} Mbps'
                    : '暂无学习数据 · 初始分',
              ),
              trailing: Text(
                entry.score.toStringAsFixed(0),
                style: Theme.of(dialogContext).textTheme.titleMedium,
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: !hasLearnedData
              ? null
              : () async {
                  await CdnScoreService.clear();
                  if (dialogContext.mounted) Navigator.pop(dialogContext);
                  setState();
                },
          child: const Text('重置评分'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}

void _showBufferSizeDialog(BuildContext context, VoidCallback setState) =>
    _showDecimalDialog(
      context,
      setState,
      key: SettingBoxKey.bufferSize,
      defVal: Pref.bufferSize,
      title: '缓冲大小',
      suffix: 'MB',
    );

void _showBufferSecDialog(BuildContext context, VoidCallback setState) =>
    _showDecimalDialog(
      context,
      setState,
      key: SettingBoxKey.bufferSec,
      defVal: Pref.bufferSec,
      title: '缓冲时长',
      suffix: 's',
    );
