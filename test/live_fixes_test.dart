import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/models/user/info.dart';
import 'package:PiliPlus/pages/live_room/controller.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';

void main() {
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('pili-live-fixes-');
    Hive.init(tempDir.path);
    GStorage.regAdapter();
    GStorage.setting = await Hive.openBox('setting');
    GStorage.video = await Hive.openBox('video');
    GStorage.localCache = await Hive.openBox('localCache');
    GStorage.userInfo = await Hive.openBox<UserInfoData>('userInfo');
    GStorage.historyWord = await Hive.openBox('historyWord');
    GStorage.watchProgress = await Hive.openBox<int>('watchProgress');
    Accounts.account = await Hive.openBox<LoginAccount>('account');
    Get.testMode = true;
    Get.routing.args = 42;
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  LiveRoomController newLive() => LiveRoomController('hero');

  group('A: isLoaded 只依赖流地址初始化', () {
    test('规则拉取挂起时 isLoaded 仍会置位', () async {
      final live = newLive();
      final pending = live.debugLoadStreamAndRules(
        () async {},
        () => Completer<void>().future,
      );
      await Future.any([
        pending,
        Future<void>.delayed(const Duration(seconds: 2)),
      ]);
      expect(live.isLoaded.value, isTrue);
    });

    test('规则拉取抛错时错误不外泄且 isLoaded 置位', () async {
      final live = newLive();
      await expectLater(
        live.debugLoadStreamAndRules(
          () async {},
          () async => throw StateError('rules down'),
        ),
        completes,
      );
      expect(live.isLoaded.value, isTrue);
    });

    test('流地址初始化抛错仍向外传播且不置 isLoaded', () async {
      final live = newLive();
      await expectLater(
        live.debugLoadStreamAndRules(
          () async => throw StateError('init down'),
          null,
        ),
        throwsA(isA<StateError>()),
      );
      expect(live.isLoaded.value, isFalse);
    });
  });

  group('B: isLive 时跳过 CDN 健康检查', () {
    test('live 时 _checkCdnHealth 不启动低缓冲观察', () {
      final c = VideoDetailController();
      c.plPlayerController.isLive = true;
      c.debugCheckCdnHealth();
      expect(c.debugLowBufferWatchActive, isFalse);
    });

    test('非 live 对照：_checkCdnHealth 仍启动低缓冲观察', () {
      final c = VideoDetailController();
      c.plPlayerController.isLive = false;
      c.debugCheckCdnHealth();
      expect(c.debugLowBufferWatchActive, isTrue);
    });

    test('live 时 isBuffering 变化不记录碎片化卡顿', () {
      final c = VideoDetailController();
      c.plPlayerController.isLive = true;
      c.debugOnIsBufferingChanged(true);
      expect(c.debugFragmentStallCount, 0);
    });

    test('非 live 对照：isBuffering 变化记录碎片化卡顿', () {
      final c = VideoDetailController();
      c.plPlayerController.isLive = false;
      c.debugOnIsBufferingChanged(true);
      expect(c.debugFragmentStallCount, 1);
    });
  });

  group('C: isBlocked 空关键词', () {
    test('空串关键词不吞掉所有弹幕', () {
      final live = newLive()..updateBlockRules(const ['', 'spam'], const {});
      expect(live.isBlocked('hello', 1), isFalse);
      expect(live.isBlocked('spam hit', 1), isTrue);
    });

    test('屏蔽 uid 仍生效', () {
      final live = newLive()..updateBlockRules(const [''], const {7});
      expect(live.isBlocked('hello', 7), isTrue);
      expect(live.isBlocked('hello', 8), isFalse);
    });
  });
}