import 'dart:async' show Timer, StreamSubscription;
import 'dart:convert' show jsonDecode;
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:PiliPlus/common/widgets/dialog/report.dart';
import 'package:PiliPlus/common/widgets/flutter/text_field/controller.dart';
import 'package:PiliPlus/http/live.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/super_chat_type.dart';
import 'package:PiliPlus/models/common/video/base_quality.dart';
import 'package:PiliPlus/models/model_owner.dart';
import 'package:PiliPlus/models_new/live/live_danmaku/danmaku_msg.dart';
import 'package:PiliPlus/models_new/live/live_danmaku/live_emote.dart';
import 'package:PiliPlus/models_new/live/live_dm_info/data.dart';
import 'package:PiliPlus/models_new/live/live_medal_wall/uinfo_medal.dart';
import 'package:PiliPlus/models_new/live/live_room_info_h5/data.dart';
import 'package:PiliPlus/models_new/live/live_room_play_info/codec.dart';
import 'package:PiliPlus/models_new/live/live_room_play_info/stream.dart';
import 'package:PiliPlus/models_new/live/live_superchat/item.dart';
import 'package:PiliPlus/pages/common/publish/publish_route.dart';
import 'package:PiliPlus/pages/danmaku/danmaku_model.dart';
import 'package:PiliPlus/pages/live_room/send_danmaku/view.dart';
import 'package:PiliPlus/pages/video/widgets/header_control.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/plugin/pl_player/utils/danmaku_options.dart';
import 'package:PiliPlus/services/service_locator.dart';
import 'package:PiliPlus/tcp/live.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/android/bindings.g.dart';
import 'package:PiliPlus/utils/connectivity_utils.dart';
import 'package:PiliPlus/utils/danmaku_utils.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:PiliPlus/utils/extension/iterable_ext.dart';
import 'package:PiliPlus/utils/extension/rx_ext.dart';
import 'package:PiliPlus/utils/global_data.dart';
import 'package:PiliPlus/utils/num_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/theme_utils.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:PiliPlus/utils/video_utils.dart';
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:easy_debounce/easy_throttle.dart';
import 'package:flutter/foundation.dart'
    show kDebugMode, kReleaseMode, visibleForTesting;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

const int _kMaxChatCount = 500;
const int _kTrimCount = _kMaxChatCount + 50;
const int _kSafeTrimIndex = 200;

class LiveRoomController extends GetxController {
  LiveRoomController(this.heroTag);
  final String heroTag;

  int roomId = Get.arguments;
  int? ruid;
  DanmakuController<DanmakuExtra>? danmakuController;
  final plPlayerController = PlPlayerController.getInstance(
    isLive: true,
  );

  final isLoaded = false.obs;
  final roomInfoH5 = Rxn<RoomInfoH5Data>();

  final liveTime = Rxn<int>();
  Timer? liveTimeTimer;

  void startLiveTimer() {
    if (liveTime.value != null) {
      liveTimeTimer ??= Timer.periodic(
        const Duration(minutes: 5),
        (_) => liveTime.refresh(),
      );
    }
  }

  void cancelLiveTimer() {
    liveTimeTimer?.cancel();
    liveTimeTimer = null;
  }

  Widget get timeWidget => Obx(() {
    final liveTime = this.liveTime.value;
    String text = '';
    if (liveTime != null) {
      final duration = DurationUtils.formatDurationBetween(
        liveTime * 1000,
        DateTime.now().millisecondsSinceEpoch,
      );
      text += duration.isEmpty ? '刚刚开播' : '开播$duration';
    }
    if (text.isEmpty) {
      return const SizedBox.shrink();
    }
    return Text(
      text,
      style: const TextStyle(
        fontSize: 12,
        color: Colors.white,
      ),
    );
  });

  // dm
  LiveDmInfoData? dmInfo;
  List<RichTextItem>? savedDanmaku;
  int builtLength = 0;
  final messages = <dynamic>[].obs;
  bool get shouldRefresh => builtLength != messages.length;
  late final RxList<SuperChatItem> superChatMsg = <SuperChatItem>[].obs;
  final disableAutoScroll = false.obs;
  bool autoScroll = true;
  LiveMessageStream? _msgStream;

  /// True between startLiveMsg and closeLiveMsg: the page wants live danmaku.
  bool _wantLiveMsg = false;
  Timer? _msgReconnectTimer;
  int _msgReconnectAttempt = 0;

  late final fsSC = Rxn<SuperChatItem>();
  late final enableFSSC = Pref.enableFullScreenSC;
  late final fsSCScale = Pref.fullScreenSCScale;
  late final fsSCOpacity = Pref.fullScreenSCOpacity;

  List<String> _keywordList = const [];
  Set<int> _shieldUids = const {};

  late final ScrollController scrollController;
  late final RxInt pageIndex = 0.obs;
  PageController? pageController;

  final RxBool isPortrait = false.obs;
  late List<LiveQuality> acceptQnList = [];
  final Rxn<LiveQuality> currentQn = Rxn<LiveQuality>(
    PlatformUtils.isMobile || Platform.isLinux
        ? null
        : .fromCode(Pref.liveQuality),
  );

  late final bool isLogin;
  late final int mid;

  String? videoUrl;
  bool? isPlaying;
  late bool isFullScreen = false;

  final superChatType = Pref.superChatType;
  late final showSuperChat = superChatType != SuperChatType.disable;

  final headerKey = GlobalKey<TimeBatteryMixin>();

  final RxString title = ''.obs;

  final RxnString onlineCount = RxnString();

  final RxnString watchedShow = RxnString();
  Widget get watchedWidget => Obx(() {
    if (watchedShow.value case final watchedShow?) {
      return Text(
        watchedShow,
        style: const TextStyle(
          fontSize: 12,
          color: Colors.white,
        ),
      );
    }
    return const SizedBox.shrink();
  });

  int chatSimpleIndex = 0;
  int _trimDmIndex = 0;
  int get trimDmIndex => _trimDmIndex;
  void _trimDm() {
    final trimCount = messages.length - _trimDmIndex;
    if (trimCount > _kTrimCount) {
      final endIndex = messages.length - _kMaxChatCount;
      final canTrim = (chatSimpleIndex - endIndex) > _kSafeTrimIndex;
      if (canTrim) {
        messages.fillRangeOnly(_trimDmIndex, endIndex);
        _trimDmIndex = endIndex;
      }
    }
  }

  StreamSubscription? _sizeSub;

  void _onSizeChanged((int, int) value) {
    final isVertical = value.$2 > value.$1;
    isPortrait.value = isVertical;
    plPlayerController.isVertical = isVertical;
  }

  void _startSizeSub() {
    if (isPortrait.value) return;
    _stopSizeSub();
    _sizeSub = plPlayerController.videoPlayerController?.stream.size.listen(
      _onSizeChanged,
    );
  }

  void _stopSizeSub() {
    _sizeSub?.cancel();
    _sizeSub = null;
  }

  @override
  void onInit() {
    super.onInit();
    scrollController = ScrollController()..addListener(listener);
    final account = Accounts.main;
    isLogin = account.isLogin;
    mid = account.mid;
    queryLiveUrl(autoFullScreenFlag: true);
    queryLiveInfoH5();
    if (Accounts.heartbeat.isLogin && !Pref.historyPause) {
      VideoHttp.roomEntryAction(roomId: roomId);
    }
    if (showSuperChat) {
      pageController = PageController();
    }
  }

  Future<void>? playerInit({
    bool autoplay = true,
    bool autoFullScreenFlag = false,
  }) {
    if (videoUrl == null) {
      return null;
    }
    return plPlayerController.setDataSource(
      NetworkSource(videoSource: videoUrl!, audioSource: null),
      isLive: true,
      autoplay: autoplay,
      isVertical: isPortrait.value,
      autoFullScreenFlag: autoFullScreenFlag,
    );
  }

  Future<void> queryLiveUrl({bool autoFullScreenFlag = false}) async {
    currentQn.value ??= .fromCode(
      await ConnectivityUtils.isWiFi
          ? Pref.liveQuality
          : Pref.liveQualityCellular,
    );
    final res = await LiveHttp.liveRoomInfo(
      roomId: roomId,
      qn: currentQn.value!.code,
      onlyAudio: plPlayerController.onlyPlayAudio.value,
    );
    if (res case Success(:final response)) {
      if (response.liveStatus != 1) {
        _showDialog('当前直播间未开播');
        return;
      }
      final playurl = response.playurlInfo?.playurl;
      if (playurl == null) {
        _showDialog('无法获取播放地址');
        return;
      }
      ruid = response.uid;
      if (response.roomId case final roomId?) {
        this.roomId = roomId;
      }
      liveTime.value = response.liveTime;
      startLiveTimer();
      isPortrait.value = response.isPortrait ?? false;
      stream = playurl.stream;
      _initStreamIndex();
      await debugLoadStreamAndRules(
        () => initLiveUrl(
          streamIndex: streamIndex,
          formatIndex: formatIndex,
          codecIndex: codecIndex,
          liveUrlIndex: liveUrlIndex,
        ),
        !isLoaded.value && Accounts.heartbeat.isLogin ? _fetchBlockRules : null,
      );
    } else {
      _showDialog(res.toString());
    }
  }

  late List<Stream> stream;
  int streamIndex = 0;
  int formatIndex = 0;
  int codecIndex = 0;
  int liveUrlIndex = 0;

  void _initStreamIndex() {
    final pref = Pref.liveStream;
    if (pref != null) {
      try {
        final String protocolName = pref[0];
        final String formatName = pref[1];
        final String codecName = pref[2];
        for (var (i, s) in stream.indexed) {
          if (s.protocolName == protocolName) {
            streamIndex = i;
            for (var (j, f) in s.format.indexed) {
              if (f.formatName == formatName) {
                formatIndex = j;
                for (var (k, c) in f.codec.indexed) {
                  if (c.codecName == codecName) {
                    codecIndex = k;
                    return;
                  }
                }
              }
            }
          }
        }
      } catch (_) {}
    }
  }

  Future<void>? initLiveUrl({
    int streamIndex = 0,
    int formatIndex = 0,
    int codecIndex = 0,
    int liveUrlIndex = 0,
  }) {
    this.streamIndex = streamIndex;
    this.formatIndex = formatIndex;
    this.codecIndex = codecIndex;
    this.liveUrlIndex = liveUrlIndex;

    final CodecItem item = stream
        .getOrFirst(streamIndex)
        .format
        .getOrFirst(formatIndex)
        .codec
        .getOrFirst(codecIndex);
    acceptQnList = item.acceptQn;
    // 以服务端返回的码率为准
    currentQn.value = item.currentQn;
    videoUrl = VideoUtils.getLiveCdnUrl(item, index: liveUrlIndex);
    return playerInit()?.whenComplete(_startSizeSub);
  }

  Future<void> queryLiveInfoH5() async {
    final res = await LiveHttp.liveRoomInfoH5(roomId: roomId);
    if (res case Success(:final response)) {
      roomInfoH5.value = response;
      title.value = response.roomInfo?.title ?? '';
      watchedShow.value = response.watchedShow?.textLarge;
      videoPlayerServiceHandler?.onVideoDetailChange(response, roomId, heroTag);
    } else {
      res.toast();
    }
  }

  void _showDialog(String title) {
    showDialog(
      context: Get.context!,
      builder: (_) => AlertDialog(
        title: Text(title),
        actions: [
          TextButton(
            onPressed: Get.back,
            child: Text(
              '关闭',
              style: TextStyle(color: ThemeUtils.theme.colorScheme.outline),
            ),
          ),
          TextButton(
            onPressed: () {
              if (plPlayerController.isDesktopPip) {
                plPlayerController.exitDesktopPip();
              }
              Get
                ..back()
                ..back();
            },
            child: const Text('退出'),
          ),
        ],
      ),
    );
  }

  void scrollToBottom() {
    EasyThrottle.throttle(
      'liveDm',
      const Duration(milliseconds: 500),
      () => WidgetsBinding.instance.addPostFrameCallback(_scrollToBottom),
    );
  }

  void _scrollToBottom([_]) {
    if (scrollController.hasClients) {
      scrollController.animateTo(
        scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 500),
        curve: Curves.linearToEaseOut,
      );
    }
  }

  void handleJumpToBottom() {
    disableAutoScroll.value = false;
    if (shouldRefresh) {
      messages.refresh();
      WidgetsBinding.instance.addPostFrameCallback(_jumpToBottom);
    } else {
      _jumpToBottom();
    }
  }

  void _jumpToBottom([_]) {
    if (scrollController.hasClients) {
      scrollController.jumpTo(scrollController.position.maxScrollExtent);
    }
  }

  void closeLiveMsg() {
    _wantLiveMsg = false;
    _msgReconnectTimer?.cancel();
    _msgReconnectTimer = null;
    _msgStream?.close();
    _msgStream = null;
  }

  /// The danmaku socket dropped by itself (server/network). Without this the
  /// dead stream stayed in [_msgStream] and startLiveMsg never reconnected,
  /// so all danmaku stopped until the room was reopened.
  void _onMsgStreamLost(LiveMessageStream stream, String reason) {
    if (!identical(_msgStream, stream)) return;
    _msgStream = null;
    _scheduleMsgReconnect(reason);
  }

  void _scheduleMsgReconnect(String reason) {
    if (!_wantLiveMsg || isClosed) {
      Utils.reportLog(() => 'LiveDm: socket closed reason=$reason (inactive)');
      return;
    }
    final attempt = ++_msgReconnectAttempt;
    // Refresh the token/host list after repeated failures.
    if (attempt >= 3) dmInfo = null;
    final delay = Duration(seconds: math.min(30, 1 << math.min(attempt, 5)));
    Utils.reportLog(
      () =>
          'LiveDm: socket lost reason=$reason; reconnect #$attempt in '
          '${delay.inSeconds}s',
    );
    _msgReconnectTimer?.cancel();
    _msgReconnectTimer = Timer(delay, () {
      _msgReconnectTimer = null;
      if (_wantLiveMsg && !isClosed) startLiveMsg();
    });
  }

  @pragma('vm:notify-debugger-on-exception')
  Future<void> prefetch() async {
    final res = await LiveHttp.liveRoomDmPrefetch(roomId: roomId);
    if (res case Success(:final response)) {
      if (response != null && response.isNotEmpty) {
        messages.addAll(
          response.where((item) => !isBlocked(item.text, item.extra.mid)),
        );
        scrollToBottom();
      }
    } else {
      if (kDebugMode) {
        Utils.reportError(res.toString());
      }
    }
  }

  Future<void> getSuperChatMsg() async {
    final res = await LiveHttp.superChatMsg(roomId);
    if (res.dataOrNull?.list case final list? when list.isNotEmpty) {
      superChatMsg.addAll(list);
    }
  }

  void clearSC() {
    superChatMsg.removeWhere((e) => e.expired);
  }

  /// 抽出 queryLiveUrl 的加载序列，便于测试注入回调。
  /// 屏蔽规则拉取 fire-and-forget：其成败不阻塞、不外泄，
  /// [isLoaded] 只等流地址初始化完成。
  @visibleForTesting
  Future<void> debugLoadStreamAndRules(
    Future<void>? Function() initLiveUrl,
    Future<void> Function()? fetchBlockRules,
  ) async {
    final initFuture = initLiveUrl();
    final rulesFuture = fetchBlockRules?.call();
    if (rulesFuture != null) {
      rulesFuture.ignore();
    }
    if (initFuture != null) {
      await initFuture;
    }
    isLoaded.value = true;
  }

  @pragma('vm:notify-debugger-on-exception')
  Future<void> _fetchBlockRules() async {
    try {
      final res = await LiveHttp.getLiveInfoByUser(roomId);
      if (res case Success(:final response?)) {
        if (response.keywordList case final keywordList?) {
          _keywordList = keywordList;
        }
        if (response.shieldUserList case final shieldUserList?) {
          _shieldUids = shieldUserList.map((e) => e.uid).toSet();
        }
      }
    } catch (e, s) {
      // 屏蔽规则拉取失败只记录，不影响直播流地址初始化
      if (kDebugMode) {
        Utils.reportError(e, s);
      }
    }
  }

  void updateBlockRules(List<String> keywords, Set<int> uids) {
    _keywordList = keywords;
    _shieldUids = uids;
  }

  bool isBlocked(String text, Object uid) {
    // 空串关键词会被 text.contains 恒判为命中，吞掉全部弹幕，必须跳过；
    // _shieldUids 是 Set<int>，非 int 的 uid（含空串）由类型检查天然排除。
    return _keywordList.any((k) => k.isNotEmpty && text.contains(k)) ||
        _shieldUids.contains(uid);
  }

  void startLiveMsg() {
    if (messages.isEmpty) {
      prefetch();
      if (showSuperChat) {
        getSuperChatMsg();
      }
    }
    _wantLiveMsg = true;
    if (_msgStream != null || _msgReconnectTimer != null) {
      return;
    }
    if (dmInfo != null) {
      initDm(dmInfo!);
      return;
    }
    LiveHttp.liveRoomGetDanmakuToken(roomId: roomId).then((res) {
      if (res case Success(:final response)) {
        initDm(dmInfo = response);
      } else if (_msgReconnectAttempt > 0) {
        _scheduleMsgReconnect('token-fetch-failed');
      }
    });
  }

  void listener() {
    final userScrollDirection = scrollController.position.userScrollDirection;
    if (userScrollDirection == .forward) {
      disableAutoScroll.value = true;
    } else if (userScrollDirection == .reverse) {
      final pos = scrollController.position;
      if (pos.maxScrollExtent - pos.pixels <= 100 && disableAutoScroll.value) {
        disableAutoScroll.value = false;
        refreshMsgIfNeeded();
      }
    }
  }

  void refreshMsgIfNeeded() {
    if (shouldRefresh) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        messages.refresh();
      });
    }
  }

  @override
  void onClose() {
    _stopSizeSub();
    closeLiveMsg();
    cancelLikeTimer();
    cancelLiveTimer();
    savedDanmaku?.clear();
    savedDanmaku = null;
    messages.clear();
    if (showSuperChat) {
      superChatMsg.clear();
      if (enableFSSC) {
        fsSC.value = null;
      }
    }
    scrollController
      ..removeListener(listener)
      ..dispose();
    pageController?.dispose();
    danmakuController = null;
    super.onClose();
  }

  // 修改画质
  Future<void>? changeQn(LiveQuality qn) {
    if (currentQn.value == qn) {
      return null;
    }
    currentQn.value = qn;
    return queryLiveUrl();
  }

  void initDm(LiveDmInfoData info) {
    if (info.hostList.isEmpty) {
      if (_msgReconnectAttempt > 0) _scheduleMsgReconnect('empty-host-list');
      return;
    }
    late final LiveMessageStream stream;
    stream = _msgStream =
        LiveMessageStream(
            streamToken: info.token,
            roomId: roomId,
            uid: Accounts.heartbeat.mid,
            servers: info.hostList
                .map((host) => 'wss://${host.host}:${host.wssPort}/sub')
                .toList(),
            onUnexpectedClose: (reason) => _onMsgStreamLost(stream, reason),
            showConnectErrorToast: _msgReconnectAttempt == 0,
          )
          ..addEventListener(_danmakuListener)
          ..init();
  }

  // ---- Diagnostics (log mode only): why the overlay shows no danmaku. ----
  // Summarized per state change, never per message.
  /// Current live layout, set by the view, e.g. `PP fs=false dm=false`.
  String dmLayout = '';

  /// The DanmakuScreen controller that is currently mounted, if any.
  DanmakuController<DanmakuExtra>? mountedDmScreen;
  String? _dmBlocker;
  int _dmBlockedCount = 0;
  DateTime? _dmBlockedSince;

  String? _dmOverlayBlocker() {
    if (!plPlayerController.showDanmaku) return 'app-background';
    if (!plPlayerController.enableShowLiveDanmaku.value) return 'switch-off';
    final ctr = danmakuController;
    if (ctr == null) return 'no-screen';
    if (!identical(ctr, mountedDmScreen)) return 'screen-not-mounted';
    if (!ctr.running) return 'screen-paused';
    return null;
  }

  void _noteDmOverlay(String? blocker) {
    if (blocker == _dmBlocker) {
      if (blocker != null) _dmBlockedCount++;
      return;
    }
    if (_dmBlocker case final prev?) {
      final count = _dmBlockedCount;
      final ms = DateTime.now().difference(_dmBlockedSince!).inMilliseconds;
      Utils.reportLog(
        () =>
            'LiveDm: overlay unblocked (was $prev, $count msgs, ${ms}ms) '
            'layout=$dmLayout',
      );
    }
    _dmBlocker = blocker;
    _dmBlockedCount = blocker == null ? 0 : 1;
    _dmBlockedSince = DateTime.now();
    if (blocker != null) {
      Utils.reportLog(
        () =>
            'LiveDm: overlay blocked reason=$blocker layout=$dmLayout '
            'player=${plPlayerController.playerStatus.name}',
      );
    }
  }

  void addDm(dynamic msg, [DanmakuContentItem<DanmakuExtra>? item]) {
    _trimDm();

    if (item != null) _noteDmOverlay(_dmOverlayBlocker());
    if (plPlayerController.showDanmaku) {
      if (item != null && plPlayerController.enableShowLiveDanmaku.value) {
        danmakuController?.addDanmaku(item);
      }
      if (autoScroll && !disableAutoScroll.value) {
        messages.add(msg);
        scrollToBottom();
        return;
      }
    }

    messages.addOnly(msg);
  }

  @pragma('vm:notify-debugger-on-exception')
  void _danmakuListener(dynamic obj) {
    if (_msgReconnectAttempt != 0) {
      final attempts = _msgReconnectAttempt;
      _msgReconnectAttempt = 0;
      Utils.reportLog(
        () => 'LiveDm: socket recovered after $attempts attempt(s)',
      );
    }
    try {
      // logger.i(' 原始弹幕消息 ======> ${jsonEncode(obj)}');
      switch (obj['cmd']) {
        case 'DANMU_MSG':
          final info = obj['info'];
          final first = info[0];
          final content = first[15];
          final user = content['user'];
          // final midHash = first[7];
          final uid = user['uid'] as int;
          final msg = info[1];
          if (isBlocked(msg, uid)) {
            return;
          }
          final Map<String, dynamic> extra = jsonDecode(content['extra']);
          final name = user['base']['name'];
          BaseEmote? uemote;
          if (first[13] case Map<String, dynamic> map) {
            uemote = BaseEmote.fromJson(map);
          }
          final checkInfo = info[9];
          final liveExtra = LiveDanmaku(
            id: extra['id_str'],
            mid: uid,
            dmType: extra['dm_type'],
            ts: checkInfo['ts'],
            ct: checkInfo['ct'],
          );
          Owner? reply;
          final replyMid = extra['reply_mid'];
          if (replyMid != null && replyMid != 0) {
            reply = Owner(
              mid: replyMid,
              name: extra['reply_uname'],
            );
          }
          addDm(
            DanmakuMsg(
              name: name,
              text: msg,
              emots: (extra['emots'] as Map<String, dynamic>?)?.map(
                (k, v) => MapEntry(k, BaseEmote.fromJson(v)),
              ),
              uemote: uemote,
              extra: liveExtra,
              reply: reply,
              medalInfo: GlobalData().showMedal
                  ? UinfoMedal.lightMedal(user['medal'])
                  : null,
            ),
            DanmakuContentItem(
              msg,
              color: DanmakuOptions.blockColorful
                  ? Colors.white
                  : DmUtils.decimalToColor(extra['color']),
              type: DmUtils.getPosition(extra['mode']),
              // extra['send_from_me'] is invalid
              selfSend: isLogin && uid == mid,
              extra: liveExtra,
            ),
          );
          break;
        case 'SUPER_CHAT_MESSAGE' when showSuperChat:
          final item = SuperChatItem.fromJson(obj['data'], roomId);
          superChatMsg.insert(0, item);
          addDm(item);
          if (!enableFSSC) return;
          if (Platform.isAndroid && AndroidHelper.isPipMode) return;
          if (plPlayerController.showDanmaku &&
              (isFullScreen || plPlayerController.isDesktopPip)) {
            fsSC.value = item.copyWith(
              endTime: math.min(
                item.endTime,
                DateTime.now().millisecondsSinceEpoch ~/ 1000 + 10,
              ),
            );
          }
          break;
        // case 'SUPER_CHAT_MESSAGE_DELETE' when showSuperChat:
        //   if (obj['roomid'] == roomId) {
        //     final ids = obj['data']?['ids'] as List?;
        //     if (ids != null && ids.isNotEmpty) {
        //       if (superChatType == .valid) {
        //         superChatMsg.removeWhere((e) => ids.contains(e.id));
        //       } else {
        //         bool? refresh;
        //         for (final id in ids) {
        //           if (superChatMsg.firstWhereOrNull((e) => e.id == id)
        //               case final item?) {
        //             item.deleted = true;
        //             refresh ??= true;
        //           }
        //         }
        //         if (refresh ?? false) {
        //           superChatMsg.refresh();
        //         }
        //       }
        //     }
        //   }
        case 'WATCHED_CHANGE':
          watchedShow.value = obj['data']['text_large'];
          break;
        case 'ONLINE_RANK_COUNT':
          onlineCount.value = NumUtils.numFormat(obj['data']['count']);
          break;
        case 'ROOM_CHANGE':
          title.value = obj['data']['title'];
          break;
      }
    } catch (e, s) {
      if (kDebugMode) {
        Utils.reportError(e, s);
      }
    }
  }

  final RxInt likeClickTime = 0.obs;
  Timer? likeClickTimer;

  void cancelLikeTimer() {
    likeClickTimer?.cancel();
    likeClickTimer = null;
  }

  void onLikeTapDown(_) {
    cancelLikeTimer();
    likeClickTime.value++;
  }

  void onLikeTapUp([_]) {
    likeClickTimer ??= Timer(const Duration(milliseconds: 800), onLike);
  }

  Future<void> onLike() async {
    if (!isLogin) {
      likeClickTime.value = 0;
      return;
    }
    final res = await LiveHttp.liveLikeReport(
      clickTime: likeClickTime.value,
      roomId: roomId,
      uid: mid,
      anchorId: roomInfoH5.value?.roomInfo?.uid,
    );
    if (res.isSuccess) {
      SmartDialog.showToast('点赞成功');
    } else {
      res.toast();
    }
    likeClickTime.value = 0;
  }

  void toastNotLogin() {
    SmartDialog.showToast('账号未登录');
  }

  void onSendDanmaku([bool fromEmote = false]) {
    if (kReleaseMode && !isLogin) {
      toastNotLogin();
      return;
    }
    Get.key.currentState!.push(
      PublishRoute(
        barrierColor: Colors.transparent,
        pageBuilder: (context, animation, secondaryAnimation) {
          return Theme(
            data: ThemeUtils.darkTheme,
            child: LiveSendDmPanel(
              liveRoomController: this,
              items: savedDanmaku,
              autofocus: !fromEmote,
              panelType: fromEmote ? .emoji : .none,
              onSave: (msg) {
                if (msg.isEmpty) {
                  savedDanmaku?.clear();
                  savedDanmaku = null;
                } else {
                  savedDanmaku = msg.toList();
                }
              },
            ),
          );
        },
        transitionDuration: fromEmote
            ? const Duration(milliseconds: 400)
            : PlatformUtils.isDesktop
            ? const Duration(milliseconds: 350)
            : const Duration(milliseconds: 400),
      ),
    );
  }

  void onAtUser(DanmakuMsg item) {
    savedDanmaku = [
      RichTextItem.fromStart(
        '@${item.name} ',
        rawText: item.extra.mid.toString(),
        type: .at,
        id: item.extra.id.toString(),
      ),
    ];
    onSendDanmaku();
  }

  void reportSC(SuperChatItem item) {
    if (!isLogin) {
      toastNotLogin();
      return;
    }
    autoWrapReportDialog(
      Get.context!,
      ReportOptions.liveDanmakuReport,
      withContent: ReportOptions.liveDanmakuReportCheck,
      contentRequired: ReportOptions.liveDanmakuReportCheck,
      (reasonType, reasonDesc, banUid) {
        return LiveHttp.superChatReport(
          id: item.id,
          roomId: roomId,
          uid: item.uid,
          msg: item.message,
          reason: ReportOptions.liveDanmakuReport['']![reasonType]!,
          ts: item.ts,
          token: item.token,
        );
      },
    );
  }

  void toggleDanmaku() {
    final newVal = !plPlayerController.enableShowLiveDanmaku.rawValue;
    plPlayerController.enableShowLiveDanmaku.value = newVal;
    if (!plPlayerController.tempPlayerConf) {
      GStorage.setting.put(
        SettingBoxKey.enableShowLiveDanmaku,
        newVal,
      );
    }
  }
}
