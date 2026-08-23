import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/services/cdn_score_service.dart';
import 'package:PiliPlus/services/cdn_relay_server.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CdnRelayServer', () {
    late CdnRelayServer relayServer;
    final upstreamServers = <HttpServer>[];

    setUp(() {
      CdnScoreService.resetMemoryForTest();
      relayServer = CdnRelayServer(connectivityProbe: () async => true);
    });

    tearDown(() async {
      CdnScoreService.resetMemoryForTest();
      await relayServer.close();
      for (final server in upstreamServers) {
        await server.close(force: true);
      }
      upstreamServers.clear();
    });

    test(
      'closes the active response and serves the next Range from the new CDN',
      () async {
        const prefixLength = 300 * 1024;
        final payload = List<int>.generate(512 * 1024, (index) => index % 256);
        final upstreamStalled = Completer<void>();
        final first = await _startUpstream(
          payload,
          stallAfterBytes: prefixLength,
          stallFor: const Duration(seconds: 2),
          onStallStarted: () {
            if (!upstreamStalled.isCompleted) upstreamStalled.complete();
          },
        );
        final second = await _startUpstream(payload);
        upstreamServers.addAll([first, second]);

        final switches = <(String, String)>[];
        final firstUrl = 'http://127.0.0.1:${first.port}/video.m4s';
        final session = await relayServer.createSession(
          videoCandidates: [
            firstUrl,
            'http://localhost:${second.port}/video.m4s',
          ],
          videoIndex: 0,
          cooldown: Duration.zero,
          maxSwitches: 3,
          onSwitch: (track, failed, next) {
            if (track == CdnRelayTrack.video) switches.add((failed, next));
          },
        );

        final client = HttpClient();
        final stableUrl = session.videoUrl;
        final request = await client.getUrl(Uri.parse(stableUrl));
        final response = await request.close();
        final receivedPrefix = Completer<void>();
        final readFuture = _readBytesAllowingPrematureClose(
          response,
          onBytes: (bytes) {
            if (bytes.length >= prefixLength && !receivedPrefix.isCompleted) {
              receivedPrefix.complete();
            }
          },
        );
        await receivedPrefix.future.timeout(const Duration(seconds: 1));
        expect(
          await session.switchVideo(expectedUrl: firstUrl, reason: 'test'),
          isTrue,
        );
        final firstBytes = await readFuture;

        expect(firstBytes, payload.sublist(0, prefixLength));
        expect(switches, hasLength(1));
        expect(
          session.currentVideoSource,
          contains('localhost:${second.port}'),
        );
        expect(session.videoUrl, stableUrl);
        final resumedRequest = await client.getUrl(Uri.parse(stableUrl));
        resumedRequest.headers.set(
          HttpHeaders.rangeHeader,
          'bytes=$prefixLength-',
        );
        final resumedBytes = await (await resumedRequest.close())
            .fold<List<int>>(
              <int>[],
              (bytes, chunk) => bytes..addAll(chunk),
            );
        client.close(force: true);

        expect(resumedBytes, payload.sublist(prefixLength));
      },
    );

    test(
      'controller switch selects the next CDN without changing local URL',
      () async {
        final payload = List<int>.generate(32, (index) => index);
        final requestStarted = Completer<void>();
        final first = await _startUpstream(
          payload,
          responseDelay: const Duration(seconds: 2),
          onRequest: () {
            if (!requestStarted.isCompleted) requestStarted.complete();
          },
        );
        final second = await _startUpstream(payload);
        upstreamServers.addAll([first, second]);

        final firstUrl = 'http://127.0.0.1:${first.port}/video.m4s';
        final session = await relayServer.createSession(
          videoCandidates: [
            firstUrl,
            'http://localhost:${second.port}/video.m4s',
          ],
          videoIndex: 0,
          cooldown: Duration.zero,
          maxSwitches: 3,
        );

        final client = HttpClient();
        final stableUrl = session.videoUrl;
        final request = await client.getUrl(Uri.parse(session.videoUrl));
        final responseFuture = request.close();

        await requestStarted.future.timeout(const Duration(seconds: 1));
        expect(await session.switchVideo(expectedUrl: firstUrl), isTrue);
        final response = await responseFuture;
        final bytes = await response.fold<List<int>>(
          <int>[],
          (buffer, chunk) => buffer..addAll(chunk),
        );
        client.close(force: true);

        expect(session.videoUrl, stableUrl);
        expect(bytes, payload);
        expect(
          session.currentVideoSource,
          contains('localhost:${second.port}'),
        );
      },
    );

    test(
      'video switch leaves a healthy audio response on its current CDN',
      () async {
        final payload = List<int>.generate(32, (index) => index);
        final first = await _startUpstream(payload);
        final second = await _startUpstream(payload);
        upstreamServers.addAll([first, second]);

        final failedVideo = 'http://127.0.0.1:${first.port}/video.m4s';
        final failedAudio = 'http://127.0.0.1:${first.port}/audio.m4s';
        final session = await relayServer.createSession(
          videoCandidates: [
            failedVideo,
            'http://localhost:${second.port}/video.m4s',
          ],
          videoIndex: 0,
          audioCandidates: [
            failedAudio,
            'http://localhost:${second.port}/audio.m4s',
          ],
          audioIndex: 0,
          cooldown: Duration.zero,
          maxSwitches: 3,
        );

        expect(await session.switchVideo(expectedUrl: failedVideo), isTrue);

        expect(session.currentAudioSource, failedAudio);
        final entry = CdnScoreService.entryForUrl(failedVideo);
        expect(entry.failures, 1);
        expect(entry.score, 36);
      },
    );

    test('video switch budget does not block audio recovery', () async {
      final payload = List<int>.generate(32, (index) => index);
      final failedAudio = await _startUpstream(
        payload,
        disconnectAfterBytes: 0,
      );
      final healthyAudio = await _startUpstream(payload);
      upstreamServers.addAll([failedAudio, healthyAudio]);

      final session = await relayServer.createSession(
        videoCandidates: const [
          'https://video-a.invalid/video.m4s',
          'https://video-b.invalid/video.m4s',
        ],
        videoIndex: 0,
        audioCandidates: [
          'http://127.0.0.1:${failedAudio.port}/audio.m4s',
          'http://localhost:${healthyAudio.port}/audio.m4s',
        ],
        audioIndex: 0,
        cooldown: Duration.zero,
        maxSwitches: 1,
        maxAudioSwitches: 1,
      );

      expect(await session.switchVideo(reason: 'test'), isTrue);
      expect(session.remainingSwitches, 0);
      expect(session.remainingAudioSwitches, 1);

      final client = HttpClient();
      final firstRequest = await client.getUrl(Uri.parse(session.audioUrl!));
      final firstResponse = await firstRequest.close();
      await _readBytesAllowingPrematureClose(firstResponse);

      expect(session.remainingAudioSwitches, 0);
      expect(
        session.currentAudioSource,
        contains('localhost:${healthyAudio.port}'),
      );

      final retry = await client.getUrl(Uri.parse(session.audioUrl!));
      final bytes = await (await retry.close()).fold<List<int>>(
        <int>[],
        (buffer, chunk) => buffer..addAll(chunk),
      );
      client.close(force: true);
      expect(bytes, payload);
    });

    test('retired relay no longer calls the active controller', () async {
      final switches = <(String, String)>[];
      final logs = <String>[];
      final session = await relayServer.createSession(
        videoCandidates: const [
          'https://first.example/video.m4s',
          'https://second.example/video.m4s',
        ],
        videoIndex: 0,
        cooldown: Duration.zero,
        maxSwitches: 3,
        onSwitch: (track, failed, next) => switches.add((failed, next)),
        onLog: logs.add,
      );
      logs.clear();

      session.retire();
      expect(await session.switchVideo(reason: 'test'), isFalse);

      expect(switches, isEmpty);
      expect(logs, isEmpty);
      expect(session.currentVideoSource, contains('first.example'));
      expect(
        CdnScoreService.entryForUrl(
          'https://first.example/video.m4s',
        ).failures,
        0,
      );
    });

    test('offline hold does not override a manual pause', () async {
      await relayServer.close();
      relayServer = CdnRelayServer(
        connectivityProbe: () async => false,
        unreachableSwitchDelay: const Duration(milliseconds: 20),
      );
      final session = await relayServer.createSession(
        videoCandidates: const [
          'https://first.example/video.m4s',
          'https://second.example/video.m4s',
        ],
        videoIndex: 0,
        cooldown: Duration.zero,
        maxSwitches: 3,
      );

      final switchFuture = session.switchVideo(reason: 'test');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      session.setPlaybackPaused(true);

      expect(await switchFuture, isFalse);
      expect(session.currentVideoSource, contains('first.example'));
    });

    test('switch guard cancels a transition after the network probe', () async {
      await relayServer.close();
      relayServer = CdnRelayServer(
        connectivityProbe: () async => false,
        unreachableSwitchDelay: const Duration(milliseconds: 20),
      );
      final session = await relayServer.createSession(
        videoCandidates: const [
          'https://first.example/video.m4s',
          'https://second.example/video.m4s',
        ],
        videoIndex: 0,
        cooldown: Duration.zero,
        maxSwitches: 3,
      );
      var allowSwitch = true;

      final switchFuture = session.switchVideo(
        reason: 'test',
        canSwitch: () => allowSwitch,
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));
      allowSwitch = false;

      expect(await switchFuture, isFalse);
      expect(session.currentVideoSource, contains('first.example'));
    });

    test(
      'pauses CDN switching when the whole network looks impaired',
      () async {
        final payload = List<int>.generate(32, (index) => index);
        final first = await _startUpstream(
          payload,
          disconnectAfterBytes: 0,
        );
        final second = await _startUpstream(
          payload,
          disconnectAfterBytes: 0,
        );
        upstreamServers.addAll([first, second]);

        final switches = <(String, String)>[];
        final session = await relayServer.createSession(
          videoCandidates: [
            'http://127.0.0.1:${first.port}/video.m4s',
            'http://localhost:${second.port}/video.m4s',
          ],
          videoIndex: 0,
          cooldown: Duration.zero,
          maxSwitches: 3,
          onSwitch: (track, failed, next) {
            if (track == CdnRelayTrack.video) switches.add((failed, next));
          },
        );

        final firstClient = HttpClient();
        final firstRequest = await firstClient.getUrl(
          Uri.parse(session.videoUrl),
        );
        final firstResponse = await firstRequest.close();
        await _readBytesAllowingPrematureClose(firstResponse);
        firstClient.close(force: true);

        expect(switches, hasLength(1));
        expect(
          session.currentVideoSource,
          contains('localhost:${second.port}'),
        );
        expect(session.isNetworkSwitchPaused, isFalse);

        final secondClient = HttpClient();
        final secondRequest = await secondClient.getUrl(
          Uri.parse(session.videoUrl),
        );
        final secondResponse = await secondRequest.close();
        await _readBytesAllowingPrematureClose(secondResponse);
        secondClient.close(force: true);

        expect(switches, hasLength(1));
        expect(
          session.currentVideoSource,
          contains('localhost:${second.port}'),
        );
        expect(session.isNetworkSwitchPaused, isFalse);

        final thirdClient = HttpClient();
        final thirdRequest = await thirdClient.getUrl(
          Uri.parse(session.videoUrl),
        );
        final thirdResponse = await thirdRequest.close();
        await _readBytesAllowingPrematureClose(thirdResponse);
        thirdClient.close(force: true);

        expect(session.isNetworkSwitchPaused, isTrue);
      },
    );

    test(
      'manual pause resumes the same CDN without a failure penalty',
      () async {
        final payload = List<int>.generate(32, (index) => index);
        final upstreamStalled = Completer<void>();
        final releaseUpstream = Completer<void>();
        final first = await _startUpstream(
          payload,
          stallAfterBytes: 8,
          stallUntil: releaseUpstream.future,
          onStallStarted: () {
            if (!upstreamStalled.isCompleted) upstreamStalled.complete();
          },
        );
        final second = await _startUpstream(payload);
        upstreamServers.addAll([first, second]);

        final firstUrl = 'http://127.0.0.1:${first.port}/video.m4s';
        final switches = <(String, String)>[];
        final session = await relayServer.createSession(
          videoCandidates: [
            firstUrl,
            'http://localhost:${second.port}/video.m4s',
          ],
          videoIndex: 0,
          cooldown: Duration.zero,
          maxSwitches: 3,
          onSwitch: (track, failed, next) {
            if (track == CdnRelayTrack.video) switches.add((failed, next));
          },
        );

        final client = HttpClient();
        final request = await client.getUrl(Uri.parse(session.videoUrl));
        final responseFuture = request.close();

        await upstreamStalled.future.timeout(const Duration(seconds: 1));
        session.setPlaybackPaused(true);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        releaseUpstream.complete();

        expect(switches, isEmpty);
        expect(session.currentVideoSource, firstUrl);

        session.setPlaybackPaused(false);
        final response = await responseFuture;
        final bytes = await _readBytesAllowingPrematureClose(response);

        expect(bytes.length, lessThanOrEqualTo(payload.length));
        expect(bytes, payload.sublist(0, bytes.length));
        expect(switches, isEmpty);
        expect(session.currentVideoSource, firstUrl);
        expect(CdnScoreService.entryForUrl(firstUrl).failures, 0);

        var resumedBytes = <int>[];
        if (bytes.length < payload.length) {
          final resumedRequest = await client.getUrl(
            Uri.parse(session.videoUrl),
          );
          resumedRequest.headers.set(
            HttpHeaders.rangeHeader,
            'bytes=${bytes.length}-',
          );
          resumedBytes = await (await resumedRequest.close()).fold<List<int>>(
            <int>[],
            (buffer, chunk) => buffer..addAll(chunk),
          );
        }
        client.close(force: true);
        expect(resumedBytes, payload.sublist(bytes.length));
      },
    );

    test('forwards byte ranges without changing the player URL', () async {
      final payload = List<int>.generate(32, (index) => index);
      final upstream = await _startUpstream(payload);
      upstreamServers.add(upstream);
      final session = await relayServer.createSession(
        videoCandidates: ['http://127.0.0.1:${upstream.port}/video.m4s'],
        videoIndex: 0,
        cooldown: Duration.zero,
        maxSwitches: 3,
      );

      final stableUrl = session.videoUrl;
      final client = HttpClient();
      final request = await client.getUrl(Uri.parse(stableUrl));
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=10-19');
      final response = await request.close();
      final bytes = await response.fold<List<int>>(
        <int>[],
        (buffer, chunk) => buffer..addAll(chunk),
      );
      client.close(force: true);

      expect(response.statusCode, HttpStatus.partialContent);
      expect(bytes, payload.sublist(10, 20));
      expect(session.videoUrl, stableUrl);
    });

    test('source updates do not reset the switch budget', () async {
      final session = await relayServer.createSession(
        videoCandidates: const [
          'https://cdn-a.invalid/video.m4s',
          'https://cdn-b.invalid/video.m4s',
          'https://cdn-c.invalid/video.m4s',
        ],
        videoIndex: 0,
        cooldown: Duration.zero,
        maxSwitches: 1,
      );

      expect(await session.switchVideo(reason: 'test'), isTrue);
      session.updateSources(
        videoCandidates: const [
          'https://cdn-b.invalid/video.m4s',
          'https://cdn-c.invalid/video.m4s',
        ],
        videoIndex: 0,
        audioCandidates: const [],
        audioIndex: 0,
      );
      expect(await session.switchVideo(reason: 'test'), isFalse);
    });

    test('a rebuilt relay inherits the shared switch budget', () async {
      final session = await relayServer.createSession(
        videoCandidates: const [
          'https://cdn-a.invalid/video.m4s',
          'https://cdn-b.invalid/video.m4s',
        ],
        videoIndex: 0,
        cooldown: Duration.zero,
        maxSwitches: 1,
        initialSwitchCount: 1,
      );

      expect(session.remainingSwitches, 0);
      expect(await session.switchVideo(reason: 'test'), isFalse);
    });

    test('a retired relay remains readable during handoff', () async {
      final payload = List<int>.generate(64, (index) => index);
      final upstream = await _startUpstream(payload);
      upstreamServers.add(upstream);
      final session = await relayServer.createSession(
        videoCandidates: ['http://127.0.0.1:${upstream.port}/video.m4s'],
        videoIndex: 0,
        cooldown: Duration.zero,
        maxSwitches: 1,
      );

      session.retire();
      final client = HttpClient();
      final response = await (await client.getUrl(
        Uri.parse(session.videoUrl),
      )).close();
      final bytes = await response.fold<List<int>>(
        <int>[],
        (buffer, chunk) => buffer..addAll(chunk),
      );
      client.close(force: true);

      expect(response.statusCode, HttpStatus.ok);
      expect(bytes, payload);
      expect(await session.switchVideo(reason: 'test'), isFalse);
    });
  });
}

Future<HttpServer> _startUpstream(
  List<int> payload, {
  int? stallAfterBytes,
  int? disconnectAfterBytes,
  Duration responseDelay = Duration.zero,
  Duration stallFor = Duration.zero,
  Future<void>? stallUntil,
  void Function()? onRequest,
  void Function()? onStallStarted,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    onRequest?.call();
    if (responseDelay > Duration.zero) {
      await Future<void>.delayed(responseDelay);
    }
    final range = request.headers.value(HttpHeaders.rangeHeader);
    final match = range == null
        ? null
        : RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
    final start = match == null ? 0 : int.parse(match.group(1)!);
    final requestedEnd = match == null || match.group(2)!.isEmpty
        ? payload.length - 1
        : int.parse(match.group(2)!);
    final end = requestedEnd.clamp(start, payload.length - 1);
    final response = request.response
      ..statusCode = range == null ? HttpStatus.ok : HttpStatus.partialContent
      ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..headers.contentType = ContentType.binary;
    if (range != null) {
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/${payload.length}',
      );
    }
    response.contentLength = end - start + 1;

    final body = payload.sublist(start, end + 1);
    final firstLength = stallAfterBytes == null
        ? (disconnectAfterBytes ?? body.length).clamp(0, body.length)
        : stallAfterBytes.clamp(0, body.length);
    try {
      response.add(body.sublist(0, firstLength));
      await response.flush();
      if (disconnectAfterBytes != null) {
        final socket = await response.detachSocket();
        socket.destroy();
        return;
      }
      if (firstLength < body.length) {
        onStallStarted?.call();
        if (stallUntil case final wait?) {
          await wait;
        } else {
          await Future<void>.delayed(stallFor);
        }
        response.add(body.sublist(firstLength));
      }
      await response.close();
    } catch (_) {
      // The relay intentionally cancels a stalled upstream request.
    }
  });
  return server;
}

Future<List<int>> _readBytesAllowingPrematureClose(
  HttpClientResponse response, {
  void Function(List<int> bytes)? onBytes,
}) async {
  final bytes = <int>[];
  final completer = Completer<List<int>>();
  late final StreamSubscription<List<int>> subscription;
  subscription = response.listen(
    (chunk) {
      bytes.addAll(chunk);
      onBytes?.call(bytes);
    },
    onError: (Object _, StackTrace _) {
      if (!completer.isCompleted) completer.complete(bytes);
    },
    onDone: () {
      if (!completer.isCompleted) completer.complete(bytes);
    },
    cancelOnError: true,
  );
  try {
    return await completer.future;
  } finally {
    await subscription.cancel();
  }
}
