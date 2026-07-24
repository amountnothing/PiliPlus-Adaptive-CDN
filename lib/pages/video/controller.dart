import 'dart:async';
import 'dart:math' show max, min;
import 'dart:ui';

import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/pair.dart';
import 'package:PiliPlus/common/widgets/progress_bar/segment_progress_bar.dart';
import 'package:PiliPlus/grpc/bilibili/app/listener/v1.pbenum.dart'
    show PlaylistSource;
import 'package:PiliPlus/http/fav.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/user.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/models/common/sponsor_block/action_type.dart';
import 'package:PiliPlus/models/common/sponsor_block/post_segment_model.dart';
import 'package:PiliPlus/models/common/sponsor_block/segment_model.dart';
import 'package:PiliPlus/models/common/sponsor_block/segment_type.dart';
import 'package:PiliPlus/models/common/video/audio_quality.dart';
import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/models/common/video/source_type.dart';
import 'package:PiliPlus/models/common/video/subtitle_pref_type.dart';
import 'package:PiliPlus/models/common/video/video_decode_type.dart';
import 'package:PiliPlus/models/common/video/video_quality.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/models_new/media_list/media_list.dart';
import 'package:PiliPlus/models_new/pgc/pgc_info_model/result.dart';
import 'package:PiliPlus/models_new/video/video_detail/data.dart';
import 'package:PiliPlus/models_new/video/video_detail/episode.dart' as ugc;
import 'package:PiliPlus/models_new/video/video_detail/page.dart';
import 'package:PiliPlus/models_new/video/video_pbp/data.dart';
import 'package:PiliPlus/models_new/video/video_play_info/subtitle.dart';
import 'package:PiliPlus/models_new/video/video_stein_edgeinfo/data.dart';
import 'package:PiliPlus/pages/audio/view.dart';
import 'package:PiliPlus/pages/common/publish/publish_route.dart';
import 'package:PiliPlus/pages/search/widgets/search_text.dart';
import 'package:PiliPlus/pages/sponsor_block/block_mixin.dart';
import 'package:PiliPlus/pages/video/download_panel/view.dart';
import 'package:PiliPlus/pages/video/introduction/pgc/controller.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/controller.dart';
import 'package:PiliPlus/pages/video/medialist/view.dart';
import 'package:PiliPlus/pages/video/note/view.dart';
import 'package:PiliPlus/pages/video/post_panel/view.dart';
import 'package:PiliPlus/pages/video/send_danmaku/view.dart';
import 'package:PiliPlus/pages/video/widgets/header_control.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/plugin/pl_player/models/heart_beat_type.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/services/cdn_score_service.dart';
import 'package:PiliPlus/services/download/download_service.dart';
import 'package:PiliPlus/services/cdn_relay_server.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/adaptive_playback.dart';
import 'package:PiliPlus/utils/connectivity_utils.dart';
import 'package:PiliPlus/utils/extension/context_ext.dart';
import 'package:PiliPlus/utils/extension/iterable_ext.dart';
import 'package:PiliPlus/utils/extension/num_ext.dart';
import 'package:PiliPlus/utils/extension/size_ext.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/theme_utils.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:collection/collection.dart';
import 'package:extended_nested_scroll_view/extended_nested_scroll_view.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:media_kit/media_kit.dart' hide Subtitle;

class VideoDetailController extends GetxController
    with GetTickerProviderStateMixin, BlockMixin {
  static int _activeVideoPageCount = 0;

  /// 路由传参
  late final Map args;
  late String bvid;
  late int aid;
  late final RxInt cid;
  int? epId;
  int? seasonId;
  int? pgcType;
  late final String heroTag;
  late final String? coverHeroTag;
  late final RxString cover;

  // 视频类型 默认投稿视频
  late final VideoType videoType;
  @override
  late final isUgc = videoType == VideoType.ugc;
  VideoType? _actualVideoType;

  // 页面来源 稍后再看 收藏夹
  late bool isPlayAll;
  late SourceType sourceType;
  late BiliDownloadEntryInfo entry;
  late bool isFileSource;
  late bool _mediaDesc = false;
  late final RxList<MediaListItemModel> mediaList = <MediaListItemModel>[].obs;
  late String watchLaterTitle;

  /// tabs相关配置
  late TabController tabCtr;

  // 请求返回的视频信息
  late PlayUrlModel data;
  final RxBool videoState = false.obs;

  /// 播放器配置 画质 音质 解码格式
  final Rxn<VideoQuality> currentVideoQa = Rxn<VideoQuality>();
  AudioQuality? currentAudioQa;
  late VideoDecodeFormatType currentDecodeFormats;

  // 是否开始自动播放 存在多p的情况下，第二p需要为true
  final RxBool _autoPlay = Pref.autoPlayEnable.obs;

  final videoPlayerKey = GlobalKey();
  final childKey = GlobalKey<ScaffoldState>();

  final plPlayerController = PlPlayerController.getInstance()
    ..brightness.value = -1;
  bool get setSystemBrightness => plPlayerController.setSystemBrightness;
  bool get removeSafeArea => plPlayerController.removeSafeArea;
  double get uiScale => plPlayerController.uiScale;

  late VideoItem firstVideo;
  String? videoUrl;
  String? audioUrl;
  Duration get _bufferStallTimeout => Duration(
    milliseconds: (Pref.adaptiveStallTimeoutSec * 1000).round(),
  );
  Duration get _lowForwardBuffer => Duration(
    milliseconds: (Pref.adaptiveLowBufferSec * 1000).round(),
  );
  Duration get _refillForwardBuffer => Duration(
    milliseconds: (Pref.adaptiveRefillBufferSec * 1000).round(),
  );
  Duration get _lowBufferStutterMinGrowth => Duration(
    milliseconds: (Pref.adaptiveLowBufferStutterMinGrowthSec * 1000).round(),
  );
  int get _maxCdnSwitches => Pref.adaptiveTraverseAllCdns
      ? max(1, _videoCdnCandidates.length - 1)
      : Pref.adaptiveMaxCdnSwitches.round();
  String get _preferredDecode =>
      Pref.adaptivePlayback ? Pref.adaptivePreferredDecode : cacheDecode;
  String get _fallbackDecode =>
      Pref.adaptivePlayback ? Pref.adaptiveRecoveryDecode : cacheSecondDecode;
  VideoDecodeFormatType get _recoveryDecodeFormat =>
      VideoDecodeFormatType.fromString(_fallbackDecode);

  Timer? _cdnHealthTimer;
  List<String> _videoCdnCandidates = const [];
  List<String> _audioCdnCandidates = const [];
  final Set<String> _failedCdnHosts = {};
  int _videoCdnIndex = 0;
  int _audioCdnIndex = 0;
  int _adaptiveBandwidth = 0;
  int _directCdnSwitchCount = 0;
  bool _switchingCdn = false;
  CdnRelaySession? _cdnRelaySession;
  final List<CdnRelaySession> _retiredCdnRelays = [];
  final List<Timer> _retiredCdnRelayTimers = [];
  Duration _lastBufferedPosition = Duration.zero;
  bool _lowBufferTriggered = false;
  DateTime? _lowBufferStutterSince;
  Duration _lowBufferStutterStart = Duration.zero;
  Duration _lastPlaybackPosition = Duration.zero;
  DateTime _lastSeekRebufferAt = DateTime.fromMillisecondsSinceEpoch(0);
  Duration? _lastVideoPts;
  Duration? _lastAudioPts;
  DateTime _lastVideoFrameProgressAt = DateTime.now();
  DateTime _lastAudioFrameProgressAt = DateTime.now();
  DateTime _lastVideoFreezeRecoveryAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastPlayerErrorRecoveryAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _videoFreezeRecoveryCount = 0;
  Duration? defaultST;
  Duration? playedTime;
  String get playedTimePos {
    final pos = playedTime?.inMilliseconds;
    return pos == null || pos == 0 ? '' : '?t=${pos / 1000}';
  }

  // 亮度
  double? brightness;

  late final headerCtrKey = GlobalKey<TimeBatteryMixin>();

  Box setting = GStorage.setting;

  // 预设的解码格式
  late String cacheDecode = Pref.defaultDecode; // def avc
  late String cacheSecondDecode = Pref.secondDecode; // def av1

  bool get showReply => isFileSource
      ? false
      : isUgc
      ? plPlayerController.showVideoReply
      : plPlayerController.showBangumiReply;

  bool get showRelatedVideo =>
      isFileSource ? false : plPlayerController.showRelatedVideo;

  ScrollController? introScrollCtr;
  ScrollController get effectiveIntroScrollCtr =>
      introScrollCtr ??= ScrollController();

  int? seasonCid;
  late final RxInt seasonIndex = 0.obs;

  PlayerStatus? playerStatus;

  late final scrollKey = GlobalKey<ExtendedNestedScrollViewState>();
  late final RxBool isVertical;
  late final RxDouble scrollRatio = 0.0.obs;

  ScrollController? _scrollCtr;
  ScrollController get scrollCtr =>
      _scrollCtr ??= ScrollController()..addListener(scrollListener);

  late bool isExpanding = false;
  late bool isCollapsing = false;

  late double minVideoHeight;
  late double maxVideoHeight;
  late double videoHeight;
  late double animHeight;

  AnimationController? animController;
  AnimationController get animationController =>
      animController ??= (AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 200),
      )..addListener(_animListener));

  void refreshPage() {
    if (scrollKey.currentState?.mounted ?? false) {
      (scrollKey.currentState!.context as Element).markNeedsBuild();
    }
  }

  void _animListener() {
    if (animationController.isForwardOrCompleted) {
      _calcAnimHeight();
      refreshPage();
    }
  }

  void _calcAnimHeight() {
    if (isExpanding) {
      animHeight = clampDouble(
        videoHeight * animationController.value,
        kToolbarHeight,
        videoHeight,
      );
    } else if (isCollapsing) {
      animHeight = clampDouble(
        maxVideoHeight -
            (maxVideoHeight - minVideoHeight) * animationController.value,
        minVideoHeight,
        maxVideoHeight,
      );
    }
  }

  void animToTop() {
    final outerController = scrollKey.currentState!.outerController;
    if (outerController.hasClients) {
      outerController.animateTo(
        outerController.offset,
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeInOut,
      );
    }
  }

  bool _needAnimOnDimensionChanged(bool isVertical) {
    if (isFullScreen) {
      if (PlatformUtils.isMobile) {
        plPlayerController.changeOrientation(isVertical: isVertical);
      }
      return false;
    }
    return true;
  }

  @pragma('vm:notify-debugger-on-exception')
  void _setVideoHeight() {
    try {
      var width = firstVideo.width;
      var height = firstVideo.height;
      if (width == null || height == null) {
        if (isUgc && !isFileSource) {
          final ugcIntroCtr = Get.find<UgcIntroController>(tag: heroTag);
          final cid = this.cid.value;
          final part = ugcIntroCtr.videoDetail.value.pages?.firstWhereOrNull(
            (e) => e.cid == cid,
          );
          if (part != null) {
            final dimension = part.dimension!;
            width = dimension.width!;
            height = dimension.height!;
          } else {
            return;
          }
        } else {
          return;
        }
      }
      final isVertical = height > width;
      if (_scrollCtr?.hasClients != true) {
        videoHeight = isVertical ? maxVideoHeight : minVideoHeight;
        if (this.isVertical.value != isVertical) {
          this.isVertical.value = isVertical;
          _needAnimOnDimensionChanged(isVertical);
        }
        return;
      }
      if (this.isVertical.value != isVertical) {
        this.isVertical.value = isVertical;
        double videoHeight = isVertical ? maxVideoHeight : minVideoHeight;
        if (this.videoHeight != videoHeight) {
          if (videoHeight > this.videoHeight) {
            // current minVideoHeight
            if (_needAnimOnDimensionChanged(isVertical)) {
              isExpanding = true;
              animationController.forward(
                from: (minVideoHeight - scrollCtr.offset) / maxVideoHeight,
              );
            }
            this.videoHeight = maxVideoHeight;
          } else {
            // current maxVideoHeight
            final currentHeight = (maxVideoHeight - scrollCtr.offset)
                .toPrecision(2);
            double minVideoHeightPrecise = minVideoHeight.toPrecision(2);
            if (currentHeight == minVideoHeightPrecise) {
              this.videoHeight = minVideoHeight;
              if (_needAnimOnDimensionChanged(isVertical)) {
                isExpanding = true;
                animationController.forward(from: 1);
              }
            } else if (currentHeight < minVideoHeightPrecise) {
              // expand
              if (_needAnimOnDimensionChanged(isVertical)) {
                isExpanding = true;
                animationController.forward(
                  from: currentHeight / minVideoHeight,
                );
              }
              this.videoHeight = minVideoHeight;
            } else {
              // collapse
              if (_needAnimOnDimensionChanged(isVertical)) {
                isCollapsing = true;
                animationController.forward(
                  from: scrollCtr.offset / (maxVideoHeight - minVideoHeight),
                );
              }
              this.videoHeight = minVideoHeight;
            }
          }
        }
      } else {
        if (scrollCtr.offset != 0) {
          isExpanding = true;
          animationController.forward(from: 1 - scrollCtr.offset / videoHeight);
        }
      }
    } catch (_) {}
  }

  void scrollListener() {
    if (scrollCtr.hasClients) {
      if (scrollCtr.offset == 0) {
        scrollRatio.value = 0;
      } else {
        double offset = scrollCtr.offset - (videoHeight - minVideoHeight);
        if (offset > 0) {
          scrollRatio.value = clampDouble(
            offset.toPrecision(2) /
                (minVideoHeight - kToolbarHeight).toPrecision(2),
            0.0,
            1.0,
          );
        } else {
          scrollRatio.value = 0;
        }
      }
    }
  }

  final isLoginVideo = Accounts.get(AccountType.video).isLogin;

  late final watchProgress = GStorage.watchProgress;
  void cacheLocalProgress() {
    if (plPlayerController.playerStatus.isCompleted) {
      watchProgress.put(cid.value.toString(), entry.totalTimeMilli);
    } else if (playedTime case final playedTime?) {
      watchProgress.put(cid.value.toString(), playedTime.inMilliseconds);
    }
  }

  void initFileSource(BiliDownloadEntryInfo entry, {bool isInit = true}) {
    this.entry = entry;
    firstVideo = VideoItem(
      quality: VideoQuality.fromCode(entry.preferedVideoQuality),
      width: entry.ep?.width ?? entry.pageData?.width ?? 1,
      height: entry.ep?.height ?? entry.pageData?.height ?? 1,
    );
    if (watchProgress.get(cid.value.toString()) case final int progress?) {
      if (progress >= entry.totalTimeMilli - 400) {
        defaultST = Duration.zero;
      } else {
        defaultST = Duration(milliseconds: progress);
      }
    } else {
      defaultST = Duration.zero;
    }
    data = PlayUrlModel(timeLength: entry.totalTimeMilli);
    _setVideoHeight();
  }

  @override
  void onInit() {
    super.onInit();
    _activeVideoPageCount += 1;
    plPlayerController.onPlayerError = _onPlayerError;
    args = Get.arguments;
    videoType = args['videoType'];
    if (videoType == VideoType.pgc) {
      if (!isLoginVideo) {
        _actualVideoType = VideoType.ugc;
      }
    } else if (args['pgcApi'] == true) {
      _actualVideoType = VideoType.pgc;
    }

    bvid = args['bvid'];
    aid = args['aid'];
    cid = RxInt(args['cid']);
    epId = args['epId'];
    seasonId = args['seasonId'];
    pgcType = args['pgcType'];
    heroTag = args['heroTag'];
    coverHeroTag = args['coverHeroTag'];
    cover = RxString(args['cover'] ?? '');
    isVertical = RxBool(args['isVertical'] ?? false);

    sourceType = args['sourceType'] ?? SourceType.normal;
    isFileSource = sourceType == SourceType.file;
    isPlayAll = sourceType != SourceType.normal && !isFileSource;
    if (isFileSource) {
      initFileSource(args['entry']);
    } else if (isPlayAll) {
      watchLaterTitle = args['favTitle'];
      _mediaDesc = args['desc'];
      getMediaList();
    }

    tabCtr = TabController(
      length: 2,
      vsync: this,
      initialIndex: Pref.defaultShowComment ? 1 : 0,
    );
  }

  Future<void> getMediaList({
    bool isReverse = false,
    bool isLoadPrevious = false,
  }) async {
    final count = args['count'];
    if (!isReverse && count != null && mediaList.length >= count) {
      return;
    }
    final res = await UserHttp.getMediaList(
      type: args['mediaType'] ?? sourceType.mediaType,
      bizId: args['mediaId'] ?? -1,
      ps: 20,
      direction: isLoadPrevious ? true : false,
      oid: isReverse
          ? null
          : mediaList.isEmpty
          ? args['isContinuePlaying'] == true
                ? args['oid']
                : null
          : isLoadPrevious
          ? mediaList.first.aid
          : mediaList.last.aid,
      otype: isReverse
          ? null
          : mediaList.isEmpty
          ? null
          : isLoadPrevious
          ? mediaList.first.type
          : mediaList.last.type,
      desc: _mediaDesc,
      sortField: args['sortField'] ?? 1,
      withCurrent: mediaList.isEmpty && args['isContinuePlaying'] == true
          ? true
          : false,
    );
    if (res case Success(:final response)) {
      if (response.mediaList.isNotEmpty) {
        if (isReverse) {
          mediaList.value = response.mediaList;
          for (final item in mediaList) {
            if (item.cid != null) {
              try {
                Get.find<UgcIntroController>(
                  tag: heroTag,
                ).onChangeEpisode(item);
              } catch (_) {}
              break;
            }
          }
        } else if (isLoadPrevious) {
          mediaList.insertAll(0, response.mediaList);
        } else {
          mediaList.addAll(response.mediaList);
        }
      }
    } else {
      res.toast();
    }
  }

  void showMediaListPanel(BuildContext context) {
    if (mediaList.isNotEmpty) {
      Widget panel() => MediaListPanel(
        mediaList: mediaList,
        onChangeEpisode: (episode) {
          try {
            Get.find<UgcIntroController>(tag: heroTag).onChangeEpisode(episode);
          } catch (_) {}
        },
        panelTitle: watchLaterTitle,
        bvid: bvid,
        count: args['count'],
        loadMoreMedia: getMediaList,
        desc: _mediaDesc,
        onReverse: () {
          _mediaDesc = !_mediaDesc;
          getMediaList(isReverse: true);
        },
        loadPrevious: args['isContinuePlaying'] == true
            ? () => getMediaList(isLoadPrevious: true)
            : null,
        onDelete:
            sourceType == SourceType.watchLater ||
                (sourceType == SourceType.fav && args['isOwner'] == true)
            ? (item, index) async {
                if (sourceType == SourceType.watchLater) {
                  final res = await UserHttp.toViewDel(
                    aids: item.aid.toString(),
                  );
                  if (res.isSuccess) {
                    mediaList.removeAt(index);
                  }
                } else {
                  final res = await FavHttp.favVideo(
                    resources: '${item.aid}:${item.type}',
                    delIds: '${args['mediaId']}',
                  );
                  if (res.isSuccess) {
                    mediaList.removeAt(index);
                    SmartDialog.showToast('取消收藏');
                  } else {
                    res.toast();
                  }
                }
              }
            : null,
      );
      if (plPlayerController.isFullScreen.value || showVideoSheet) {
        PageUtils.showVideoBottomSheet(
          context,
          child: plPlayerController.darkVideoPage
              ? Theme(data: ThemeUtils.darkTheme, child: panel())
              : panel(),
        );
      } else {
        childKey.currentState?.showBottomSheet(
          backgroundColor: Colors.transparent,
          constraints: const BoxConstraints(),
          (context) => panel(),
        );
      }
    } else {
      getMediaList();
    }
  }

  bool isPortrait = true;

  bool get horizontalScreen => plPlayerController.horizontalScreen;

  bool get showVideoSheet =>
      (!horizontalScreen && !isPortrait) || plPlayerController.isDesktopPip;

  @override
  late final RxString videoLabel = ''.obs;
  @override
  int? get timeLength => data.timeLength;
  @override
  BlockConfigMixin get blockConfig => plPlayerController;
  @override
  Player? get player => plPlayerController.videoPlayerController;
  @override
  bool get isFullScreen => plPlayerController.isFullScreen.value;
  @override
  bool get autoPlay => _autoPlay.value;
  set autoPlay(bool value) => _autoPlay.value = value;
  @override
  bool get preInitPlayer => plPlayerController.preInitPlayer;
  @override
  int get currPosInMilliseconds =>
      defaultST?.inMilliseconds ?? plPlayerController.position.inMilliseconds;
  @override
  Future<void> seekTo(Duration duration, {required bool isSeek}) =>
      plPlayerController.seekTo(duration, isSeek: isSeek);

  @override
  Widget buildItem(Object item, Animation<double> animation) {
    final theme = ThemeUtils.theme;
    return Align(
      alignment: Alignment.centerLeft,
      child: SlideTransition(
        position: animation.drive(
          Tween<Offset>(
            begin: const Offset(-1.0, 0.0),
            end: Offset.zero,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.only(top: 5),
          child: GestureDetector(
            onHorizontalDragUpdate: (DragUpdateDetails details) {
              if (details.delta.dx < 0) {
                onRemoveItem(listData.indexOf(item), item);
              }
            },
            child: SearchText(
              bgColor: theme.colorScheme.secondaryContainer.withValues(
                alpha: 0.8,
              ),
              textColor: theme.colorScheme.onSecondaryContainer,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              fontSize: 14,
              text: item is SegmentModel
                  ? '跳过: ${item.segmentType.shortTitle}'
                  : '上次看到第${(item as int) + 1}P，点击跳转',
              onTap: (_) {
                if (item is int) {
                  try {
                    UgcIntroController ugcIntroController =
                        Get.find<UgcIntroController>(tag: heroTag);
                    Part part =
                        ugcIntroController.videoDetail.value.pages![item];
                    ugcIntroController.onChangeEpisode(part);
                    SmartDialog.showToast('已跳至第${item + 1}P');
                  } catch (e) {
                    if (kDebugMode) debugPrint('$e');
                    SmartDialog.showToast('跳转失败');
                  }
                  onRemoveItem(listData.indexOf(item), item);
                } else if (item is SegmentModel) {
                  onSkip(item, isSeek: false);
                  onRemoveItem(listData.indexOf(item), item);
                }
              },
            ),
          ),
        ),
      ),
    );
  }

  ({int mode, int fontSize, Color color})? dmConfig;
  String? savedDanmaku;

  /// 发送弹幕
  Future<void> showShootDanmakuSheet() async {
    if (plPlayerController.dmState.contains(cid.value)) {
      SmartDialog.showToast('UP主已关闭弹幕');
      return;
    }
    final isPlaying =
        _autoPlay.value && plPlayerController.playerStatus.isPlaying;
    if (isPlaying) {
      await plPlayerController.pause();
    }
    await Get.key.currentState!.push(
      PublishRoute(
        pageBuilder: (buildContext, animation, secondaryAnimation) {
          final child = SendDanmakuPanel(
            cid: cid.value,
            bvid: bvid,
            progress: plPlayerController.position.inMilliseconds,
            initialValue: savedDanmaku,
            onSave: (danmaku) => savedDanmaku = danmaku,
            onSuccess: (danmakuModel) {
              savedDanmaku = null;
              plPlayerController.danmakuController?.addDanmaku(danmakuModel);
            },
            dmConfig: dmConfig,
            onSaveDmConfig: (dmConfig) => this.dmConfig = dmConfig,
          );
          if (plPlayerController.darkVideoPage) {
            return Theme(data: ThemeUtils.darkTheme, child: child);
          }
          return child;
        },
      ),
    );
    if (isPlaying) {
      plPlayerController.play();
    }
  }

  VideoItem findVideoByQa(int qa) {
    /// 根据currentVideoQa和currentDecodeFormats 重新设置videoUrl
    final videoList = data.dash!.video!.where((i) => i.id == qa).toList();

    final currentDecodeFormats = this.currentDecodeFormats.codes;
    final defaultDecodeFormats = VideoDecodeFormatType.fromString(
      _preferredDecode,
    ).codes;
    final secondDecodeFormats = VideoDecodeFormatType.fromString(
      _fallbackDecode,
    ).codes;

    VideoItem? video;
    for (final i in videoList) {
      final codec = i.codecs!;
      if (currentDecodeFormats.any(codec.startsWith)) {
        video = i;
        break;
      } else if (defaultDecodeFormats.any(codec.startsWith)) {
        video = i;
      } else if (video == null && secondDecodeFormats.any(codec.startsWith)) {
        video = i;
      }
    }
    return video ?? videoList.first;
  }

  bool _isCdnCandidateAvailable(String url) {
    final host = VideoUtils.cdnHost(url);
    return host != null &&
        !_failedCdnHosts.contains(host) &&
        !VideoUtils.isCdnCoolingDown(url);
  }

  int _initialCdnIndex(List<String> candidates) {
    final available = candidates.indexWhere(_isCdnCandidateAvailable);
    if (available >= 0) return available;
    return candidates.indexWhere(
      (url) => !_failedCdnHosts.contains(VideoUtils.cdnHost(url)),
    );
  }

  int _nextCdnIndex(List<String> candidates, int current) {
    if (candidates.length < 2) return -1;
    final currentUrl = candidates[current];
    for (final candidate in CdnScoreService.rankCandidates(candidates)) {
      if (candidate == currentUrl) continue;
      if (_isCdnCandidateAvailable(candidate)) {
        return candidates.indexOf(candidate);
      }
    }
    return -1;
  }

  Duration? _readPts(String property) {
    try {
      final raw = plPlayerController.videoPlayerController?.getProperty(
        property,
      );
      if (raw == null || raw.isEmpty || raw == 'no') return null;
      final seconds = double.tryParse(raw);
      if (seconds == null || !seconds.isFinite || seconds < 0) return null;
      return Duration(milliseconds: (seconds * 1000).round());
    } catch (_) {
      return null;
    }
  }

  void _logAdaptive(String message) {
    Utils.reportLog(() => 'AdaptivePlayback $message');
  }

  static String _briefPlayerError(String event) {
    final singleLine = event.replaceAll(RegExp(r'\s+'), ' ').trim();
    return singleLine.length <= 180
        ? singleLine
        : '${singleLine.substring(0, 180)}…';
  }

  AudioItem? _currentAudioItem() {
    if (currentAudioQa case final qa?) {
      return data.dash?.audio?.firstWhereOrNull((item) => item.id == qa.code);
    }
    return null;
  }

  bool _switchToRecoveryDecodeForFrozenVideo() {
    final qa = currentVideoQa.value;
    final videos = data.dash?.video;
    if (qa == null || videos == null || videos.isEmpty) return false;
    final recoveryFormats = _recoveryDecodeFormat;
    if (currentDecodeFormats == recoveryFormats) return false;

    final recoveryVideo = videos
        .where((item) => item.id == qa.code)
        .firstWhereOrNull(
          (item) =>
              item.codecs != null &&
              recoveryFormats.codes.any(item.codecs!.startsWith),
        );
    if (recoveryVideo == null || recoveryVideo.codecs == firstVideo.codecs) {
      return false;
    }

    currentDecodeFormats = recoveryFormats;
    firstVideo = recoveryVideo;
    _setVideoHeight();
    _configureAdaptiveSources(
      videoUrls: firstVideo.playUrls,
      audioUrls: _currentAudioItem()?.playUrls,
      bandwidth: firstVideo.bandWidth,
    );
    return true;
  }

  void _resetVideoFrameHealth(DateTime now) {
    _lastVideoPts = _readPts('video-pts');
    _lastAudioPts = _readPts('audio-pts');
    _lastVideoFrameProgressAt = now;
    _lastAudioFrameProgressAt = now;
  }

  void _configureAdaptiveSources({
    required Iterable<String> videoUrls,
    Iterable<String>? audioUrls,
    int? bandwidth,
  }) {
    if (!Pref.adaptivePlayback) {
      _videoCdnCandidates = const [];
      _audioCdnCandidates = const [];
      _adaptiveBandwidth = bandwidth ?? 0;
      videoUrl = VideoUtils.getCdnUrl(videoUrls);
      audioUrl = audioUrls == null
          ? ''
          : VideoUtils.getCdnUrl(audioUrls, isAudio: true);
      return;
    }
    _videoCdnCandidates = CdnScoreService.rankCandidates(
      VideoUtils.getCdnCandidates(
        videoUrls,
        preferredService: CDNService.ali,
      ),
    );
    _audioCdnCandidates = audioUrls == null
        ? const []
        : CdnScoreService.rankCandidates(
            VideoUtils.getCdnCandidates(
              audioUrls,
              isAudio: true,
              preferredService: CDNService.ali,
            ),
          );
    _adaptiveBandwidth = bandwidth ?? 0;

    final videoIndex = _initialCdnIndex(_videoCdnCandidates);
    if (videoIndex >= 0) {
      _videoCdnIndex = videoIndex;
      videoUrl = _videoCdnCandidates[videoIndex];
    }
    final audioIndex = _initialCdnIndex(_audioCdnCandidates);
    if (audioIndex >= 0) {
      _audioCdnIndex = audioIndex;
      audioUrl = _audioCdnCandidates[audioIndex];
    } else if (_audioCdnCandidates.isEmpty) {
      audioUrl = '';
    }
  }

  void _startCdnHealthMonitor() {
    _cdnHealthTimer?.cancel();
    if (!Pref.adaptivePlayback ||
        isFileSource ||
        _videoCdnCandidates.length < 2) {
      return;
    }
    _lastBufferedPosition = plPlayerController.buffered.value;
    final now = DateTime.now();
    _lastPlaybackPosition = plPlayerController.position;
    _resetVideoFrameHealth(now);
    _videoFreezeRecoveryCount = 0;
    final forwardBuffer = _lastBufferedPosition > _lastPlaybackPosition
        ? _lastBufferedPosition - _lastPlaybackPosition
        : Duration.zero;
    _resetLowBufferWatch(now, forwardBuffer);
    _cdnHealthTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _checkCdnHealth(),
    );
  }

  bool _onPlayerError(String event) {
    if (_isExpectedRelayRebuildNoise(event)) return true;

    final isLocalRelayFailure = _isLocalRelayOpenFailure(event);
    final isBitstreamCorruption = _isVideoBitstreamCorruption(event);
    final isRecoverable = _isRecoverableAdaptivePlayerError(event);
    final hasReachedContentEnd = AdaptivePlayback.hasReachedContentEnd(
      duration: plPlayerController.duration.value,
      position: plPlayerController.position,
      buffered: plPlayerController.buffered.value,
    );
    if (isRecoverable && hasReachedContentEnd) return true;
    if (!Pref.adaptivePlayback ||
        isFileSource ||
        isClosed ||
        plPlayerController.onlyPlayAudio.value ||
        (!plPlayerController.playbackRequested.value && !isLocalRelayFailure) ||
        (!isRecoverable && !isLocalRelayFailure)) {
      return false;
    }

    final now = DateTime.now();
    final recoveryCooldown = isLocalRelayFailure
        ? const Duration(seconds: 1)
        : isBitstreamCorruption
        ? const Duration(seconds: 2)
        : const Duration(seconds: 8);
    if (now.difference(_lastPlayerErrorRecoveryAt) < recoveryCooldown) {
      return true;
    }
    if (event.toLowerCase().contains('seek failed') &&
        now.difference(_lastSeekRebufferAt) <= _bufferStallTimeout) {
      return true;
    }

    _lastPlayerErrorRecoveryAt = now;
    _logAdaptive(
      'player-error bitstream=$isBitstreamCorruption '
      'localRelay=$isLocalRelayFailure '
      'positionMs=${plPlayerController.position.inMilliseconds} '
      'bufferedMs=${plPlayerController.buffered.value.inMilliseconds} '
      'message=${_briefPlayerError(event)}',
    );
    unawaited(
      _recoverFromPlayerError(
        forceRelayRebuild: isLocalRelayFailure,
        forcePlayerRebuild: isBitstreamCorruption,
      ),
    );
    return true;
  }

  bool _isRecoverableAdaptivePlayerError(String event) {
    final lower = event.toLowerCase();
    return lower.contains('invalid obu length') ||
        lower.contains('failed to parse temporal unit') ||
        lower.contains('obu_reserved_') ||
        lower.contains('obu_forbidden_bit') ||
        lower.contains('extension_header_reserved_') ||
        lower.contains('invalid leb128') ||
        lower.contains('failed to read unit') ||
        lower.contains('bitstream ended') ||
        lower.contains('trailing_one_bit') ||
        lower.contains('trailing_zero_bit') ||
        lower.contains('seq_profile out of range') ||
        lower.contains('frame_height_bits_minus_1') ||
        lower.contains('missing picture in access unit') ||
        lower.contains('invalid nal unit size') ||
        lower.contains('stream ends prematurely') ||
        lower.contains('mbedtls_ssl_read') ||
        lower.contains('mbedtls_ssl_handshake') ||
        lower.contains('error decoding audio') ||
        lower.contains('seek failed') ||
        _isLocalRelayOpenFailure(event);
  }

  bool _isLocalRelayOpenFailure(String event) {
    final lower = event.toLowerCase();
    return ((lower.contains('failed to open http://127.0.0.1') ||
            lower.contains('failed to open http://localhost')) &&
        lower.contains('/relay/'));
  }

  bool _isVideoBitstreamCorruption(String event) {
    final lower = event.toLowerCase();
    return lower.contains('invalid obu length') ||
        lower.contains('failed to parse temporal unit') ||
        lower.contains('invalid nal unit size') ||
        lower.contains('missing picture in access unit');
  }

  bool _isExpectedRelayRebuildNoise(String event) {
    final lower = event.toLowerCase();
    return (lower.contains('pad aid') && lower.contains('not connected')) ||
        (_cdnRelaySession != null &&
            AdaptivePlayback.isExpectedRelayInterruptionError(event));
  }

  Future<void> _recoverFromPlayerError({
    bool forceRelayRebuild = false,
    bool forcePlayerRebuild = false,
  }) async {
    if (forceRelayRebuild) {
      await _rebuildRelayAndPlayer(
        delayOldRelay: true,
        stopCurrentSource: forcePlayerRebuild,
        reason: 'local-relay-error',
      );
      return;
    }
    final switched = await _switchToNextCdn(reason: 'player-error');
    if (forcePlayerRebuild) {
      await _rebuildRelayAndPlayer(
        stopCurrentSource: true,
        reason: 'bitstream-error',
      );
      return;
    }
    if (switched) return;
    await _recoverFrozenPlayback(frozenTracks: 'unknown');
  }

  Future<void> _rebuildRelayAndPlayer({
    bool delayOldRelay = false,
    bool stopCurrentSource = false,
    String reason = 'relay-rebuild',
  }) async {
    if (_switchingCdn || videoUrl == null || isClosed) return;
    _switchingCdn = true;
    try {
      final autoplay = plPlayerController.playbackRequested.value;
      playedTime = plPlayerController.position;
      _logAdaptive(
        'rebuild reason=$reason cid=${cid.value} '
        'checkpointMs=${playedTime!.inMilliseconds} autoplay=$autoplay',
      );
      _lastBufferedPosition = Duration.zero;
      final now = DateTime.now();
      _lastPlaybackPosition = playedTime ?? Duration.zero;
      _resetVideoFrameHealth(now);
      _resetLowBufferWatch(now, Duration.zero);
      if (stopCurrentSource) await plPlayerController.stopCurrentSource();
      await _disposeCdnRelay(delayed: delayOldRelay);
      await playerInit(autoplay: autoplay);
    } finally {
      _switchingCdn = false;
    }
  }

  void _checkCdnHealth() {
    if (_switchingCdn || plPlayerController.processing || isClosed) return;

    final buffered = plPlayerController.buffered.value;
    final position = plPlayerController.position;
    final duration = plPlayerController.duration.value;
    final now = DateTime.now();
    final shouldMonitor = AdaptivePlayback.shouldAccumulateCdnStall(
      playbackRequested: plPlayerController.playbackRequested.value,
      isPlaying: plPlayerController.playerStatus.isPlaying,
    );
    _cdnRelaySession?.setPlaybackPaused(!shouldMonitor);

    if (!shouldMonitor) {
      // A manual pause may leave isBuffering true for a short time. Do not
      // inherit either the playback or download stall clock after resuming.
      _lastBufferedPosition = buffered;
      final forwardBuffer = buffered > position
          ? buffered - position
          : Duration.zero;
      _resetLowBufferWatch(now, forwardBuffer);
      _lastPlaybackPosition = position;
      _resetVideoFrameHealth(now);
      return;
    }

    if (AdaptivePlayback.hasReachedContentEnd(
      duration: duration,
      position: position,
      buffered: buffered,
    )) {
      _cdnRelaySession?.setPlaybackPaused(true);
      // No more bytes are expected once the buffered/played edge reaches the
      // media tail. Reset the stall clock so a later seek starts a fresh check.
      _lastBufferedPosition = buffered;
      _resetLowBufferWatch(now, Duration.zero);
      _lastPlaybackPosition = position;
      _resetVideoFrameHealth(now);
      return;
    }
    final positionDelta = (position - _lastPlaybackPosition).inMilliseconds
        .abs();
    final forwardBuffer = buffered > position
        ? buffered - position
        : Duration.zero;
    if (positionDelta >= const Duration(seconds: 2).inMilliseconds &&
        (buffered < _lastBufferedPosition ||
            forwardBuffer <= const Duration(seconds: 1))) {
      _resetAdaptiveCdnAfterSeek(
        buffered: buffered,
        position: position,
        now: now,
      );
      return;
    }

    final videoPts = _readPts('video-pts');
    final lastVideoPts = _lastVideoPts;
    if (videoPts == null ||
        lastVideoPts == null ||
        videoPts < lastVideoPts ||
        videoPts - lastVideoPts >= const Duration(milliseconds: 250)) {
      _lastVideoPts = videoPts;
      _lastVideoFrameProgressAt = now;
    }
    final audioPts = _readPts('audio-pts');
    final lastAudioPts = _lastAudioPts;
    if (audioPts == null ||
        lastAudioPts == null ||
        audioPts < lastAudioPts ||
        audioPts - lastAudioPts >= const Duration(milliseconds: 250)) {
      _lastAudioPts = audioPts;
      _lastAudioFrameProgressAt = now;
    }

    final videoFrozen = AdaptivePlayback.shouldRecoverFrozenTrack(
      trackPts: videoPts,
      lastTrackPts: lastVideoPts,
      forwardBuffer: forwardBuffer,
      minForwardBuffer: _lowForwardBuffer,
      noFrameProgressFor: now.difference(_lastVideoFrameProgressAt),
      freezeTimeout: const Duration(seconds: 8),
      isPlaying: shouldMonitor,
      trackExpected: !plPlayerController.onlyPlayAudio.value,
    );
    final audioFrozen = AdaptivePlayback.shouldRecoverFrozenTrack(
      trackPts: audioPts,
      lastTrackPts: lastAudioPts,
      forwardBuffer: forwardBuffer,
      minForwardBuffer: _lowForwardBuffer,
      noFrameProgressFor: now.difference(_lastAudioFrameProgressAt),
      freezeTimeout: const Duration(seconds: 8),
      isPlaying: shouldMonitor,
      trackExpected: audioUrl?.isNotEmpty == true,
    );
    if (videoFrozen || audioFrozen) {
      final frozenTracks = videoFrozen && audioFrozen
          ? 'video+audio'
          : videoFrozen
          ? 'video'
          : 'audio';
      _logAdaptive(
        'pts-freeze track=$frozenTracks '
        'positionMs=${position.inMilliseconds} '
        'bufferMs=${forwardBuffer.inMilliseconds} '
        'videoPtsMs=${videoPts?.inMilliseconds} '
        'audioPtsMs=${audioPts?.inMilliseconds}',
      );
      unawaited(
        _recoverFrozenPlayback(frozenTracks: frozenTracks),
      );
      return;
    }
    if (positionDelta >= 250) {
      _lastPlaybackPosition = position;
    }

    if (buffered < _lastBufferedPosition ||
        buffered - _lastBufferedPosition >= const Duration(milliseconds: 500)) {
      _lastBufferedPosition = buffered;
    }

    if (_shouldSwitchForPersistentLowBuffer(now, forwardBuffer)) {
      _logAdaptive(
        'buffer-stall forwardMs=${forwardBuffer.inMilliseconds} '
        'thresholdMs=${_refillForwardBuffer.inMilliseconds} '
        'windowMs=${_bufferStallTimeout.inMilliseconds} '
        'minGrowthMs=${_lowBufferStutterMinGrowth.inMilliseconds}',
      );
      unawaited(_switchToNextCdn(reason: 'buffer-growth'));
      return;
    }
  }

  void _resetLowBufferWatch(DateTime now, Duration forwardBuffer) {
    _lowBufferTriggered = false;
    if (forwardBuffer <= _refillForwardBuffer) {
      _lowBufferStutterSince = now;
      _lowBufferStutterStart = forwardBuffer;
    } else {
      _lowBufferStutterSince = null;
      _lowBufferStutterStart = Duration.zero;
    }
  }

  void _resetLowBufferWatchAfterCdnSwitch(DateTime now) {
    final buffered = plPlayerController.buffered.value;
    final position = plPlayerController.position;
    _resetLowBufferWatch(
      now,
      buffered > position ? buffered - position : Duration.zero,
    );
  }

  bool _shouldSwitchForPersistentLowBuffer(
    DateTime now,
    Duration forwardBuffer,
  ) {
    if (forwardBuffer > _refillForwardBuffer) {
      _resetLowBufferWatch(now, forwardBuffer);
      return false;
    }

    _lowBufferStutterSince ??= now;
    if (_lowBufferStutterSince == now) {
      _lowBufferStutterStart = forwardBuffer;
    }
    final netGrowth = forwardBuffer - _lowBufferStutterStart;
    if (_lowBufferTriggered) {
      return false;
    }
    final observedFor = now.difference(_lowBufferStutterSince!);
    if (observedFor < _bufferStallTimeout) return false;
    if (!AdaptivePlayback.shouldSwitchForStalledBuffer(
      forwardBuffer: forwardBuffer,
      refillThreshold: _refillForwardBuffer,
      observedFor: observedFor,
      observationWindow: _bufferStallTimeout,
      bufferGrowth: netGrowth,
      minGrowth: _lowBufferStutterMinGrowth,
    )) {
      _lowBufferStutterSince = now;
      _lowBufferStutterStart = forwardBuffer;
      return false;
    }

    _lowBufferTriggered = true;
    return true;
  }

  void _resetAdaptiveCdnAfterSeek({
    required Duration buffered,
    required Duration position,
    required DateTime now,
  }) {
    _lastSeekRebufferAt = now;
    _lastBufferedPosition = buffered;
    _lastPlaybackPosition = position;
    _resetLowBufferWatch(
      now,
      buffered > position ? buffered - position : Duration.zero,
    );
    _resetVideoFrameHealth(now);
  }

  Future<void> _recoverFrozenPlayback({required String frozenTracks}) async {
    final now = DateTime.now();
    if (_switchingCdn ||
        videoUrl == null ||
        now.difference(_lastVideoFreezeRecoveryAt) <
            const Duration(seconds: 12) ||
        AdaptivePlayback.hasReachedContentEnd(
          duration: plPlayerController.duration.value,
          position: plPlayerController.position,
          buffered: plPlayerController.buffered.value,
        )) {
      return;
    }

    _switchingCdn = true;
    _lastVideoFreezeRecoveryAt = now;
    final pauseGeneration = plPlayerController.manualPauseGeneration;
    plPlayerController.presentationStalled.value = true;
    try {
      await plPlayerController.pause(isInterrupt: true);
      playedTime = plPlayerController.position;
      _lastBufferedPosition = plPlayerController.buffered.value;
      _lastPlaybackPosition = plPlayerController.position;
      _resetVideoFrameHealth(now);

      final includesVideo = frozenTracks.contains('video');
      if (_videoFreezeRecoveryCount > 0 &&
          includesVideo &&
          _switchToRecoveryDecodeForFrozenVideo()) {
        _videoFreezeRecoveryCount += 1;
        _logAdaptive('pts-recovery action=fallback-decode track=$frozenTracks');
        SmartDialog.showToast('画面再次冻结，已切换恢复解码');
        await playerInit(autoplay: true);
        return;
      }

      if (includesVideo) _videoFreezeRecoveryCount += 1;
      _logAdaptive('pts-recovery action=reload track=$frozenTracks');
      SmartDialog.showToast('音视频时间戳冻结，正在恢复播放');
      final refreshed = plPlayerController.refreshPlayer();
      if (refreshed != null) {
        await refreshed;
      } else {
        await playerInit(autoplay: true);
      }
    } finally {
      _switchingCdn = false;
      plPlayerController.presentationStalled.value = false;
      if (plPlayerController.playbackRequested.value &&
          pauseGeneration == plPlayerController.manualPauseGeneration) {
        if (!plPlayerController.playerStatus.isPlaying) {
          await plPlayerController.play();
        }
      } else {
        await plPlayerController.pause(isInterrupt: true);
      }
    }
  }

  Future<bool> _switchToNextCdn({String reason = 'buffer-growth'}) async {
    final relay = _cdnRelaySession;
    if (_switchingCdn ||
        (relay == null && _directCdnSwitchCount >= _maxCdnSwitches) ||
        videoUrl == null ||
        AdaptivePlayback.hasReachedContentEnd(
          duration: plPlayerController.duration.value,
          position: plPlayerController.position,
          buffered: plPlayerController.buffered.value,
        )) {
      return false;
    }
    _switchingCdn = true;
    try {
      if (relay != null) {
        final switched = relay.switchVideo(
          expectedUrl: videoUrl,
          reason: reason,
        );
        if (!switched) {
          SmartDialog.showToast(
            '当前视频没有更多可用 CDN',
          );
          return false;
        }
        videoUrl = relay.currentVideoSource;
        audioUrl = relay.currentAudioSource;
        final videoIndex = _videoCdnCandidates.indexOf(videoUrl!);
        if (videoIndex >= 0) _videoCdnIndex = videoIndex;
        final currentAudioUrl = audioUrl;
        if (currentAudioUrl != null) {
          final audioIndex = _audioCdnCandidates.indexOf(currentAudioUrl);
          if (audioIndex >= 0) _audioCdnIndex = audioIndex;
        }
        _lastBufferedPosition = plPlayerController.buffered.value;
        final now = DateTime.now();
        _resetLowBufferWatchAfterCdnSwitch(now);
        return true;
      }

      final failedHost = VideoUtils.cdnHost(videoUrl);
      if (failedHost != null) _failedCdnHosts.add(failedHost);
      VideoUtils.markCdnFailed(videoUrl);
      CdnScoreService.recordFailure(videoUrl!);

      final nextVideoIndex = _nextCdnIndex(
        _videoCdnCandidates,
        _videoCdnIndex,
      );
      if (nextVideoIndex < 0) {
        SmartDialog.showToast(
          '当前视频没有更多可用 CDN',
        );
        return false;
      }

      _videoCdnIndex = nextVideoIndex;
      videoUrl = _videoCdnCandidates[nextVideoIndex];

      if (audioUrl != null &&
          failedHost != null &&
          VideoUtils.cdnHost(audioUrl) == failedHost) {
        final nextAudioIndex = _nextCdnIndex(
          _audioCdnCandidates,
          _audioCdnIndex,
        );
        if (nextAudioIndex >= 0) {
          _audioCdnIndex = nextAudioIndex;
          audioUrl = _audioCdnCandidates[nextAudioIndex];
        }
      }

      _directCdnSwitchCount += 1;
      playedTime = plPlayerController.position;
      _lastBufferedPosition = Duration.zero;
      final now = DateTime.now();
      _resetLowBufferWatchAfterCdnSwitch(now);
      SmartDialog.showToast(
        'CDN 缓冲停滞，正在切换节点',
      );
      await playerInit(autoplay: true);
      return true;
    } finally {
      _switchingCdn = false;
    }
  }

  void _onRelaySwitch(
    CdnRelayTrack track,
    String failedUrl,
    String nextUrl,
  ) {
    if (isClosed) return;
    final failedHost = VideoUtils.cdnHost(failedUrl);
    if (failedHost != null) _failedCdnHosts.add(failedHost);
    if (track == CdnRelayTrack.video) {
      videoUrl = nextUrl;
      final index = _videoCdnCandidates.indexOf(nextUrl);
      if (index >= 0) _videoCdnIndex = index;
      _lastBufferedPosition = plPlayerController.buffered.value;
      final now = DateTime.now();
      _resetLowBufferWatchAfterCdnSwitch(now);
      SmartDialog.showToast('已保留缓冲并切换 CDN 节点');
    } else {
      audioUrl = nextUrl;
      final index = _audioCdnCandidates.indexOf(nextUrl);
      if (index >= 0) _audioCdnIndex = index;
    }
  }

  void _onRelayRecoveryRequired(
    CdnRelayTrack track,
    int offset,
    String reason,
  ) {
    if (isClosed) return;
    _logAdaptive(
      'relay-recovery track=${track.name} offset=$offset reason=$reason',
    );
    unawaited(
      _rebuildRelayAndPlayer(
        stopCurrentSource: true,
        reason: 'relay-$reason',
      ),
    );
  }

  Future<(String, String?)> _relayPlaybackSources() async {
    if (!Pref.adaptivePlayback || _videoCdnCandidates.length < 2) {
      await _disposeAllCdnRelays();
      return (videoUrl!, audioUrl);
    }

    final relayVideoCandidates = _videoCdnCandidates
        .where(_isCdnCandidateAvailable)
        .toList(growable: false);
    final relayAudioCandidates = _audioCdnCandidates
        .where(_isCdnCandidateAvailable)
        .toList(growable: false);
    if (relayVideoCandidates.length < 2) {
      await _disposeAllCdnRelays();
      return (videoUrl!, audioUrl);
    }
    final relayVideoIndex = relayVideoCandidates.indexOf(videoUrl!);
    final relayAudioIndex = audioUrl == null
        ? -1
        : relayAudioCandidates.indexOf(audioUrl!);

    final relay = _cdnRelaySession;
    if (relay == null || relay.isDisposed) {
      _cdnRelaySession = await CdnRelayServer.shared.createSession(
        videoCandidates: relayVideoCandidates,
        videoIndex: relayVideoIndex < 0 ? 0 : relayVideoIndex,
        audioCandidates: relayAudioCandidates,
        audioIndex: relayAudioIndex < 0 ? 0 : relayAudioIndex,
        cooldown: Duration(
          milliseconds: (Pref.adaptiveCdnCooldownSec * 1000).round(),
        ),
        maxSwitches: _maxCdnSwitches,
        onSwitch: _onRelaySwitch,
        onRecoveryRequired: _onRelayRecoveryRequired,
        onLog: Utils.reportLog,
      );
    } else {
      relay.updateSources(
        videoCandidates: relayVideoCandidates,
        videoIndex: relayVideoIndex < 0 ? 0 : relayVideoIndex,
        audioCandidates: relayAudioCandidates,
        audioIndex: relayAudioIndex < 0 ? 0 : relayAudioIndex,
      );
    }
    final activeRelay = _cdnRelaySession!;
    return (activeRelay.videoUrl, activeRelay.audioUrl);
  }

  Future<void> _disposeCdnRelay({bool delayed = false}) async {
    final relay = _cdnRelaySession;
    _cdnRelaySession = null;
    if (relay == null) return;
    if (!delayed) {
      await relay.dispose();
      return;
    }

    _retiredCdnRelays.add(relay);
    late final Timer timer;
    timer = Timer(const Duration(seconds: 3), () {
      _retiredCdnRelayTimers.remove(timer);
      _retiredCdnRelays.remove(relay);
      unawaited(relay.dispose());
    });
    _retiredCdnRelayTimers.add(timer);
  }

  Future<void> _disposeAllCdnRelays() async {
    for (final timer in _retiredCdnRelayTimers) {
      timer.cancel();
    }
    _retiredCdnRelayTimers.clear();

    final retiredRelays = List<CdnRelaySession>.of(_retiredCdnRelays);
    _retiredCdnRelays.clear();

    await _disposeCdnRelay();
    for (final relay in retiredRelays) {
      await relay.dispose();
    }
  }

  /// 更新画质、音质
  void updatePlayer() {
    final currentVideoQa = this.currentVideoQa.value;
    if (currentVideoQa == null) return;
    _autoPlay.value = true;
    playedTime = plPlayerController.position;
    plPlayerController
      ..isBuffering.value = false
      ..buffered.value = Duration.zero;

    final video = findVideoByQa(currentVideoQa.code);
    if (firstVideo.codecs != video.codecs) {
      currentDecodeFormats = VideoDecodeFormatType.fromString(video.codecs!);
    }
    firstVideo = video;

    /// 根据currentAudioQa 重新设置audioUrl
    AudioItem? firstAudio;
    if (currentAudioQa != null) {
      firstAudio = data.dash!.audio!.firstWhere(
        (i) => i.id == currentAudioQa!.code,
        orElse: () => data.dash!.audio!.first,
      );
    }

    _configureAdaptiveSources(
      videoUrls: firstVideo.playUrls,
      audioUrls: firstAudio?.playUrls,
      bandwidth: firstVideo.bandWidth,
    );

    playerInit();
  }

  Future<void>? _initPlayerIfNeeded(bool autoFullScreenFlag) {
    if (_autoPlay.value ||
        (plPlayerController.preInitPlayer && !plPlayerController.processing) &&
            (isFileSource
                ? true
                : videoPlayerKey.currentState?.mounted == true)) {
      return playerInit(
        autoFullScreenFlag: autoFullScreenFlag && _autoPlay.value,
      );
    }
    return null;
  }

  Future<void> playerInit({
    bool? autoplay,
    bool autoFullScreenFlag = false,
  }) async {
    plPlayerController.onPlayerError = _onPlayerError;
    Duration? seek = defaultST ?? playedTime;
    if (seek == null || seek == Duration.zero) {
      seek = getFirstSegment();
    }
    final (playbackVideoUrl, playbackAudioUrl) = isFileSource
        ? (videoUrl ?? '', audioUrl)
        : await _relayPlaybackSources();
    await plPlayerController.setDataSource(
      isFileSource
          ? FileSource(
              dir: args['dirPath'],
              typeTag: entry.typeTag!,
              isMp4: entry.mediaType == 1,
              hasDashAudio: entry.hasDashAudio,
            )
          : NetworkSource(
              videoSource: playbackVideoUrl,
              audioSource: playbackAudioUrl,
              bandwidth: _adaptiveBandwidth,
            ),
      seekTo: seek,
      duration: data.timeLength == null
          ? null
          : Duration(milliseconds: data.timeLength!),
      isVertical: isVertical.value,
      aid: aid,
      bvid: bvid,
      cid: cid.value,
      autoplay: autoplay ?? _autoPlay.value,
      epid: isUgc ? null : epId,
      seasonId: isUgc ? null : seasonId,
      pgcType: isUgc ? null : pgcType,
      videoType: videoType,
      onInit: () {
        videoState.value = true;
        setSubtitle(vttSubtitlesIndex.value);
      },
      width: firstVideo.width,
      height: firstVideo.height,
      volume: volume,
      autoFullScreenFlag: autoFullScreenFlag,
    );

    if (isClosed) return;

    if (!isFileSource) {
      if (plPlayerController.enableBlock) {
        initSkip();
      }

      if (vttSubtitlesIndex.value == -1) {
        _queryPlayInfo();
      }

      if (plPlayerController.showDmChart && dmTrend.value == null) {
        _getDmTrend();
      }
    }

    defaultST = null;
    _startCdnHealthMonitor();
  }

  bool isQuerying = false;

  final languages = Rxn<List<LanguageItem>>();
  final currLang = Rxn<String>();
  void setLanguage(String language) {
    if (currLang.value == language) return;
    if (!isLoginVideo) {
      SmartDialog.showToast('账号未登录');
      return;
    }
    currLang.value = language;
    queryVideoUrl(fromReset: true);
  }

  Volume? volume;

  // 视频链接
  Future<void> queryVideoUrl({
    bool fromReset = false,
    bool autoFullScreenFlag = false,
  }) async {
    if (isFileSource) {
      return _initPlayerIfNeeded(autoFullScreenFlag);
    }
    if (isQuerying) {
      return;
    }
    isQuerying = true;
    if (plPlayerController.enableSponsorBlock && isBlock && !fromReset) {
      querySponsorBlock(bvid: bvid, cid: cid.value);
    }
    if (plPlayerController.cacheVideoQa == null) {
      final isWiFi = await ConnectivityUtils.isWiFi;
      plPlayerController
        ..cacheVideoQa = isWiFi
            ? Pref.defaultVideoQa
            : Pref.defaultVideoQaCellular
        ..cacheAudioQa = isWiFi
            ? Pref.defaultAudioQa
            : Pref.defaultAudioQaCellular;
    }

    final result = await VideoHttp.videoUrl(
      cid: cid.value,
      bvid: bvid,
      epid: epId,
      seasonId: seasonId,
      qn: plPlayerController.cacheVideoQa,
      tryLook: plPlayerController.tryLook,
      videoType: _actualVideoType ?? videoType,
      language: currLang.value,
      voiceBalance: plPlayerController.enableAudioNormalization,
    );

    if (result case Success(:final response)) {
      data = response;

      languages.value = data.language?.items;
      currLang.value = data.curLanguage;

      volume = data.volume;

      if (!fromReset) {
        final progress = args.remove('progress');
        if (progress != null) {
          defaultST = Duration(milliseconds: progress);
        } else {
          defaultST = Duration(milliseconds: data.lastPlayTime);
        }
      }

      if (!isUgc && !fromReset && plPlayerController.enablePgcSkip) {
        if (data.clipInfoList case final clipInfoList?) {
          resetBlock();
          handleSBData(clipInfoList);
        }
      }

      if (data.acceptDesc?.contains('试看') == true) {
        SmartDialog.showToast(
          '该视频为专属视频，仅提供试看',
          displayTime: const Duration(seconds: 3),
        );
      }
      if (data.dash == null && data.durl != null) {
        final first = data.durl!.first;
        _configureAdaptiveSources(videoUrls: first.playUrls);

        // 实际为FLV/MP4格式，但已被淘汰，这里仅做兜底处理
        final videoQuality = VideoQuality.fromCode(data.quality!);
        firstVideo = VideoItem(
          id: data.quality!,
          baseUrl: videoUrl,
          codecs: 'avc1',
          quality: videoQuality,
        );
        _setVideoHeight();
        currentDecodeFormats = VideoDecodeFormatType.fromString('avc1');
        currentVideoQa.value = videoQuality;
        await _initPlayerIfNeeded(autoFullScreenFlag);
        isQuerying = false;
        return;
      }
      if (data.dash == null) {
        SmartDialog.showToast('视频资源不存在');
        _autoPlay.value = false;
        videoState.value = false;
        if (plPlayerController.isFullScreen.value) {
          plPlayerController.triggerFullScreen(status: false);
        }
        isQuerying = false;
        return;
      }
      final List<VideoItem> videoList = data.dash!.video!;
      // if (kDebugMode) debugPrint("allVideosList:${allVideosList}");
      // 当前可播放的最高质量视频
      final curHighestVideoQa = videoList.first.quality.code;
      // 预设的画质为null，则当前可用的最高质量
      int targetVideoQa = curHighestVideoQa;
      if (data.acceptQuality?.isNotEmpty == true &&
          plPlayerController.cacheVideoQa! <= curHighestVideoQa) {
        // 如果预设的画质低于当前最高
        targetVideoQa = data.acceptQuality!.findClosestTarget(
          (e) => e <= plPlayerController.cacheVideoQa!,
          (a, b) => a > b ? a : b,
        );
      }
      currentVideoQa.value = VideoQuality.fromCode(targetVideoQa);

      /// 取出符合当前画质的videoList
      final List<VideoItem> videosList = videoList
          .where((e) => e.quality.code == targetVideoQa)
          .toList();

      /// 优先顺序 设置中指定解码格式 -> 当前可选的首个解码格式
      final List<FormatItem> supportFormats = data.supportFormats!;
      // 根据画质选编码格式
      final List<String> supportDecodeFormats = supportFormats
          .firstWhere(
            (e) => e.quality == targetVideoQa,
            orElse: () => supportFormats.first,
          )
          .codecs!;
      // 默认从设置中取AV1
      currentDecodeFormats = VideoDecodeFormatType.fromString(_preferredDecode);
      VideoDecodeFormatType secondDecodeFormats =
          VideoDecodeFormatType.fromString(_fallbackDecode);
      // 当前视频没有对应格式返回第一个
      int flag = 0;
      for (final e in supportDecodeFormats) {
        if (currentDecodeFormats.codes.any(e.startsWith)) {
          flag = 1;
          break;
        } else if (secondDecodeFormats.codes.any(e.startsWith)) {
          flag = 2;
        }
      }
      if (flag == 2) {
        currentDecodeFormats = secondDecodeFormats;
      } else if (flag == 0) {
        currentDecodeFormats = VideoDecodeFormatType.fromString(
          supportDecodeFormats.first,
        );
      }

      /// 取出符合当前解码格式的videoItem
      firstVideo = videosList.firstWhere(
        (e) => currentDecodeFormats.codes.any(e.codecs!.startsWith),
        orElse: () => videosList.first,
      );
      _setVideoHeight();

      /// 优先顺序 设置中指定质量 -> 当前可选的最高质量
      AudioItem? firstAudio;
      final audioList = data.dash?.audio;
      if (audioList != null && audioList.isNotEmpty) {
        final List<int> audioIds = audioList.map((map) => map.id!).toList();
        int closestNumber = audioIds.findClosestTarget(
          (e) => e <= plPlayerController.cacheAudioQa,
          (a, b) => a > b ? a : b,
        );
        if (!audioIds.contains(plPlayerController.cacheAudioQa) &&
            audioIds.any((e) => e > plPlayerController.cacheAudioQa)) {
          closestNumber = AudioQuality.k192.code;
        }
        firstAudio = audioList.firstWhere(
          (e) => e.id == closestNumber,
          orElse: () => audioList.first,
        );
        if (firstAudio.id case final int id?) {
          currentAudioQa = AudioQuality.fromCode(id);
        }
      }
      _configureAdaptiveSources(
        videoUrls: firstVideo.playUrls,
        audioUrls: firstAudio?.playUrls,
        bandwidth: firstVideo.bandWidth,
      );
      await _initPlayerIfNeeded(autoFullScreenFlag);
    } else {
      _autoPlay.value = false;
      videoState.value = false;
      if (plPlayerController.isFullScreen.value) {
        plPlayerController.triggerFullScreen(status: false);
      }
      result.toast();
    }
    isQuerying = false;
  }

  late final List<PostSegmentModel> postList = <PostSegmentModel>[];
  void onBlock(BuildContext context) {
    if (postList.isEmpty) {
      postList.add(
        PostSegmentModel(
          segment: Pair(
            first: 0,
            second: plPlayerController.position.inMilliseconds / 1000,
          ),
          category: SegmentType.sponsor,
          actionType: ActionType.skip,
        ),
      );
    }
    if (plPlayerController.isFullScreen.value || showVideoSheet) {
      final child = PostPanel(
        enableSlide: false,
        videoDetailController: this,
        plPlayerController: plPlayerController,
      );
      PageUtils.showVideoBottomSheet(
        context,
        child: plPlayerController.darkVideoPage
            ? Theme(data: ThemeUtils.darkTheme, child: child)
            : child,
      );
    } else {
      childKey.currentState?.showBottomSheet(
        backgroundColor: Colors.transparent,
        constraints: const BoxConstraints(),
        (context) => PostPanel(
          videoDetailController: this,
          plPlayerController: plPlayerController,
        ),
      );
    }
  }

  RxList<Subtitle> subtitles = RxList<Subtitle>();
  final Map<int, ({bool isData, String id})> vttSubtitles = {};
  late final RxInt vttSubtitlesIndex = (-1).obs;
  late final RxBool showVP = true.obs;
  late final RxList<ViewPointSegment> viewPointList = <ViewPointSegment>[].obs;

  // 设定字幕轨道
  Future<void> setSubtitle(int index) async {
    if (index <= 0) {
      await plPlayerController.videoPlayerController?.setSubtitleTrack(
        SubtitleTrack.no(),
      );
      vttSubtitlesIndex.value = index;
      return;
    }

    Future<void> setSub(({bool isData, String id}) subtitle) async {
      final sub = subtitles[index - 1];

      String subUri = subtitle.id;
      if (subtitle.isData) {
        subUri = 'memory://$subUri';
      }
      await plPlayerController.videoPlayerController?.setSubtitleTrack(
        SubtitleTrack(subUri, sub.lanDoc, sub.lan, uri: true),
      );
      vttSubtitlesIndex.value = index;
    }

    ({bool isData, String id})? subtitle = vttSubtitles[index - 1];
    if (subtitle != null) {
      await setSub(subtitle);
    } else {
      final result = await VideoHttp.vttSubtitles(
        subtitles[index - 1].subtitleUrl!,
      );
      if (!isClosed && result != null) {
        final subtitle = (isData: true, id: result);
        vttSubtitles[index - 1] = subtitle;
        await setSub(subtitle);
      }
    }
  }

  // interactive video
  int? graphVersion;
  EdgeInfoData? steinEdgeInfo;
  late final RxBool showSteinEdgeInfo = false.obs;

  Future<void> getSteinEdgeInfo([int? edgeId]) async {
    steinEdgeInfo = null;
    try {
      final res = await Request().get(
        '/x/stein/edgeinfo_v2',
        queryParameters: {
          'bvid': bvid,
          'graph_version': graphVersion,
          'edge_id': ?edgeId,
        },
      );
      if (res.data['code'] == 0) {
        steinEdgeInfo = EdgeInfoData.fromJson(res.data['data']);
      } else {
        if (kDebugMode) {
          debugPrint('getSteinEdgeInfo error: ${res.data['message']}');
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('getSteinEdgeInfo: $e');
    }
  }

  late bool continuePlayingPart = Pref.continuePlayingPart;

  Future<void> _queryPlayInfo() async {
    vttSubtitles.clear();
    vttSubtitlesIndex.value = 0;
    if (plPlayerController.showViewPoints) {
      viewPointList.clear();
    }
    final res = await VideoHttp.playInfo(
      bvid: bvid,
      cid: cid.value,
      seasonId: seasonId,
      epId: epId,
    );
    if (res case Success(:final response)) {
      // interactive video
      if (isUgc && graphVersion == null) {
        try {
          final introCtr = Get.find<UgcIntroController>(tag: heroTag);
          if (introCtr.videoDetail.value.rights?.isSteinGate == 1) {
            graphVersion = response.interaction?.graphVersion;
            getSteinEdgeInfo();
          }
        } catch (e) {
          if (kDebugMode) debugPrint('handle stein: $e');
        }
      }

      if (isUgc && continuePlayingPart) {
        continuePlayingPart = false;
        try {
          UgcIntroController ugcIntroController = Get.find<UgcIntroController>(
            tag: heroTag,
          );
          if ((ugcIntroController.videoDetail.value.pages?.length ?? 0) > 1 &&
              response.lastPlayCid != null &&
              response.lastPlayCid != 0) {
            if (response.lastPlayCid != cid.value) {
              int index = ugcIntroController.videoDetail.value.pages!
                  .indexWhere((item) => item.cid == response.lastPlayCid);
              if (index != -1) {
                onAddItem(index);
              }
            }
          }
        } catch (_) {}
      }

      if (plPlayerController.showViewPoints &&
          response.viewPoints?.firstOrNull?.type == 2) {
        try {
          viewPointList.value = response.viewPoints!.map((item) {
            final end = (item.to! / (data.timeLength! / 1000)).clamp(0.0, 1.0);
            return ViewPointSegment(
              end: end,
              title: item.content,
              url: item.imgUrl,
              from: item.from,
              to: item.to,
            );
          }).toList();
        } catch (_) {}
      }

      if (response.subtitle?.subtitles?.isNotEmpty == true) {
        subtitles.value = response.subtitle!.subtitles!;

        final idx = switch (Pref.subtitlePreferenceV2) {
          SubtitlePrefType.off => 0,
          SubtitlePrefType.on => 1,
          SubtitlePrefType.withoutAi =>
            subtitles.first.lan.startsWith('ai') ? 0 : 1,
          SubtitlePrefType.auto =>
            !subtitles.first.lan.startsWith('ai') ||
                    (PlatformUtils.isMobile &&
                        (await FlutterVolumeController.getVolume() ?? 0.0) <=
                            0.0)
                ? 1
                : 0,
        };
        await setSubtitle(idx);
      }
    }
  }

  void updateMediaListHistory(int aid) {
    if (args['sortField'] != null) {
      VideoHttp.medialistHistory(
        desc: _mediaDesc ? 1 : 0,
        oid: aid,
        upperMid: args['mediaId'],
      );
    }
  }

  void makeHeartBeat() {
    if (plPlayerController.enableHeart &&
        !plPlayerController.playerStatus.isCompleted &&
        playedTime != null) {
      try {
        plPlayerController.makeHeartBeat(
          data.timeLength != null
              ? (data.timeLength! - playedTime!.inMilliseconds).abs() <= 1000
                    ? -1
                    : playedTime!.inSeconds
              : playedTime!.inSeconds,
          type: HeartBeatType.completed,
          isManual: true,
          aid: aid,
          bvid: bvid,
          cid: cid.value,
          epid: isUgc ? null : epId,
          seasonId: isUgc ? null : seasonId,
          pgcType: isUgc ? null : pgcType,
          videoType: videoType,
        );
      } catch (_) {}
    }
  }

  @override
  void onClose() {
    final hasUnderlyingVideoPage =
        _activeVideoPageCount > 1 && !plPlayerController.isCloseAll;
    _cdnHealthTimer?.cancel();
    plPlayerController.presentationStalled.value = false;
    plPlayerController.onPlayerError = null;
    if (hasUnderlyingVideoPage) {
      Utils.reportLog(
        () =>
            'VideoPageStack: skip stopCurrentSource on stacked video close count=$_activeVideoPageCount',
      );
    } else {
      unawaited(plPlayerController.stopCurrentSource());
    }
    unawaited(_disposeAllCdnRelays());
    cid.close();
    if (isFileSource) {
      cacheLocalProgress();
    }
    introScrollCtr?.dispose();
    introScrollCtr = null;
    tabCtr.dispose();
    _scrollCtr
      ?..removeListener(scrollListener)
      ..dispose();
    animController
      ?..removeListener(_animListener)
      ..dispose();
    subtitles.clear();
    vttSubtitles.clear();
    _activeVideoPageCount = max(0, _activeVideoPageCount - 1);
    super.onClose();
  }

  void onReset({bool isStein = false}) {
    _cdnHealthTimer?.cancel();
    plPlayerController.presentationStalled.value = false;
    unawaited(_disposeAllCdnRelays());
    _failedCdnHosts.clear();
    _videoCdnCandidates = const [];
    _audioCdnCandidates = const [];
    _directCdnSwitchCount = 0;
    _switchingCdn = false;
    if (isFileSource) {
      cacheLocalProgress();
    }

    playedTime = null;
    defaultST = null;
    videoUrl = null;
    audioUrl = null;

    if (scrollRatio.value != 0) {
      scrollRatio.refresh();
    }

    // danmaku
    savedDanmaku = null;

    // subtitle
    subtitles.clear();
    vttSubtitlesIndex.value = -1;
    vttSubtitles.clear();

    if (!isFileSource) {
      // language
      languages.value = null;
      currLang.value = null;

      // dm trend
      if (plPlayerController.showDmChart) {
        dmTrend.value = null;
      }

      // view point
      if (plPlayerController.showViewPoints) {
        viewPointList.clear();
      }

      // sponsor block
      if (blockConfig.enableBlock) {
        resetBlock();
      }

      // interactive video
      if (!isStein) {
        graphVersion = null;
      }
      steinEdgeInfo = null;
      showSteinEdgeInfo.value = false;
    }
  }

  late final Rx<LoadingState<List<double>>?> dmTrend =
      Rx<LoadingState<List<double>>?>(null);
  late final RxBool showDmTrendChart = true.obs;

  Future<void> _getDmTrend() async {
    dmTrend.value = LoadingState<List<double>>.loading();
    try {
      final res = await Request().get(
        'https://bvc.bilivideo.com/pbp/data',
        queryParameters: {
          'bvid': bvid,
          'cid': cid.value,
        },
      );
      PbpData data = PbpData.fromJson(res.data);
      int stepSec = data.stepSec ?? 0;
      if (stepSec != 0 && data.events?.eDefault?.isNotEmpty == true) {
        dmTrend.value = Success(data.events!.eDefault!);
        return;
      }
      dmTrend.value = const Error(null);
    } catch (e) {
      dmTrend.value = const Error(null);
      if (kDebugMode) debugPrint('_getDmTrend: $e');
    }
  }

  void showNoteList(BuildContext context) {
    String? title;
    try {
      title = Get.find<UgcIntroController>(
        tag: heroTag,
      ).videoDetail.value.title;
    } catch (_) {}
    if (plPlayerController.isFullScreen.value || showVideoSheet) {
      final child = NoteListPage(
        oid: aid,
        enableSlide: false,
        heroTag: heroTag,
        isStein: graphVersion != null,
        title: title,
      );
      PageUtils.showVideoBottomSheet(
        context,
        child: plPlayerController.darkVideoPage
            ? Theme(data: ThemeUtils.darkTheme, child: child)
            : child,
      );
    } else {
      childKey.currentState?.showBottomSheet(
        backgroundColor: Colors.transparent,
        constraints: const BoxConstraints(),
        (context) => NoteListPage(
          oid: aid,
          heroTag: heroTag,
          isStein: graphVersion != null,
          title: title,
        ),
      );
    }
  }

  @pragma('vm:notify-debugger-on-exception')
  bool onSkipSegment() {
    try {
      if (plPlayerController.enableBlock) {
        if (listData.lastOrNull case final SegmentModel item) {
          onSkip(item, isSeek: false);
          onRemoveItem(listData.indexOf(item), item);
          return true;
        }
      }
    } catch (e, s) {
      Utils.reportError(e, s);
    }
    return false;
  }

  void toAudioPage() {
    int? id;
    int? extraId;
    PlaylistSource from = PlaylistSource.UP_ARCHIVE;
    if (isPlayAll) {
      id = args['mediaId'];
      extraId = sourceType.extraId;
      from = sourceType.playlistSource!;
    } else if (isUgc) {
      try {
        final ctr = Get.find<UgcIntroController>(tag: heroTag);
        id = ctr.videoDetail.value.ugcSeason?.id;
        if (id != null) {
          extraId = 8;
          from = PlaylistSource.MEDIA_LIST;
        }
      } catch (_) {}
    }
    AudioPage.toAudioPage(
      itemType: 1,
      id: id,
      oid: aid,
      subId: [cid.value],
      from: from,
      heroTag: _autoPlay.value ? heroTag : null,
      start: playedTime,
      audioUrl: audioUrl,
      extraId: extraId,
    );
  }

  Future<void> onDownload(BuildContext context) async {
    VideoDetailData? videoDetail;
    List<ugc.BaseEpisodeItem>? episodes;
    UgcIntroController? ugcIntroController;
    PgcInfoModel? pgcItem;
    if (isUgc) {
      try {
        ugcIntroController = Get.find<UgcIntroController>(tag: heroTag);
        videoDetail = ugcIntroController.videoDetail.value;
        if (videoDetail.ugcSeason?.sections case final sections?) {
          episodes = <ugc.BaseEpisodeItem>[];
          for (final i in sections) {
            if (i.episodes case final e?) {
              episodes.addAll(e);
            }
          }
        } else {
          episodes = videoDetail.pages;
        }
      } catch (e, s) {
        if (kDebugMode) {
          debugPrint('download ugc: $e\n\n$s');
        }
      }
    } else {
      try {
        pgcItem = Get.find<PgcIntroController>(tag: heroTag).pgcItem;
        episodes = pgcItem.episodes;
      } catch (e, s) {
        if (kDebugMode) {
          debugPrint('download pgc: $e\n\n$s');
        }
      }
    }
    if (episodes != null && episodes.isNotEmpty) {
      final downloadService = Get.find<DownloadService>();
      await downloadService.waitForInitialization;
      if (!context.mounted) {
        return;
      }
      final Set<int> cidSet = downloadService.downloadList
          .followedBy(downloadService.waitDownloadQueue)
          .map((e) => e.cid)
          .toSet();
      final index = episodes.indexWhere(
        (e) => e.cid == (seasonCid ?? cid.value),
      );

      showModalBottomSheet(
        context: context,
        useSafeArea: true,
        isScrollControlled: true,
        constraints: BoxConstraints(
          maxWidth: min(640, context.mediaQueryShortestSide),
        ),
        builder: (context) {
          final maxChildSize =
              PlatformUtils.isMobile && !context.mediaQuerySize.isPortrait
              ? 1.0
              : 0.7;
          return DraggableScrollableSheet(
            snap: true,
            expand: false,
            minChildSize: 0,
            snapSizes: [maxChildSize],
            maxChildSize: maxChildSize,
            initialChildSize: maxChildSize,
            builder: (context, scrollController) => DownloadPanel(
              index: index,
              videoDetail: videoDetail,
              pgcItem: pgcItem,
              episodes: episodes!,
              scrollController: scrollController,
              videoDetailController: this,
              heroTag: heroTag,
              ugcIntroController: ugcIntroController,
              cidSet: cidSet,
            ),
          );
        },
      );
    }
  }

  void editPlayUrl() {
    String videoUrl = this.videoUrl ?? '';
    String audioUrl = this.audioUrl ?? '';
    Widget textField({
      required String label,
      required String initialValue,
      required ValueChanged<String> onChanged,
    }) => TextFormField(
      minLines: 1,
      maxLines: 3,
      onChanged: onChanged,
      initialValue: initialValue,
      decoration: InputDecoration(
        label: Text(label),
        border: const OutlineInputBorder(),
      ),
    );
    showDialog(
      context: Get.context!,
      builder: (context) => AlertDialog(
        constraints: Style.dialogFixedConstraints,
        title: const Text('播放地址'),
        content: Column(
          spacing: 20,
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            textField(
              label: 'Video Url',
              initialValue: videoUrl,
              onChanged: (value) => videoUrl = value,
            ),
            textField(
              label: 'Audio Url',
              initialValue: audioUrl,
              onChanged: (value) => audioUrl = value,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Get.back();
              this.videoUrl = videoUrl;
              this.audioUrl = audioUrl;
              playerInit();
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  @pragma('vm:notify-debugger-on-exception')
  Future<void> onCast() async {
    SmartDialog.showLoading();
    final res = await VideoHttp.tvPlayUrl(
      cid: cid.value,
      objectId: epId ?? aid,
      playurlType: epId != null ? 2 : 1,
      qn: currentVideoQa.value?.code,
    );
    SmartDialog.dismiss();
    if (res case Success(:final response)) {
      final first = response.durl?.firstOrNull;
      if (first == null || first.playUrls.isEmpty) {
        SmartDialog.showToast('不支持投屏');
        return;
      }
      final url = VideoUtils.getCdnUrl(first.playUrls);

      String? title;
      try {
        if (isUgc) {
          title = Get.find<UgcIntroController>(
            tag: heroTag,
          ).videoDetail.value.title;
        } else {
          title = Get.find<PgcIntroController>(
            tag: heroTag,
          ).videoDetail.value.title;
        }
      } catch (_) {}
      if (kDebugMode) {
        debugPrint(title);
      }
      Get.toNamed(
        '/dlna',
        parameters: {
          'url': url,
          'title': ?title,
        },
      );
    } else {
      res.toast();
    }
  }
}
