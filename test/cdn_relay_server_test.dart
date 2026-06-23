import 'dart:io';

import 'package:PiliPlus/services/cdn_relay_server.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CdnRelayServer', () {
    late CdnRelayServer relayServer;
    final upstreamServers = <HttpServer>[];

    setUp(() {
      relayServer = CdnRelayServer();
    });

    tearDown(() async {
      await relayServer.close();
      for (final server in upstreamServers) {
        await server.close(force: true);
      }
      upstreamServers.clear();
    });

    test(
      'keeps one downstream response while changing CDN mid-range',
      () async {
        final payload = List<int>.generate(32, (index) => index);
        final first = await _startUpstream(
          payload,
          stallAfterBytes: 8,
          stallFor: const Duration(seconds: 2),
        );
        final second = await _startUpstream(payload);
        upstreamServers.addAll([first, second]);

        final switches = <(String, String)>[];
        final session = await relayServer.createSession(
          videoCandidates: [
            'http://127.0.0.1:${first.port}/video.m4s',
            'http://localhost:${second.port}/video.m4s',
          ],
          videoIndex: 0,
          stallTimeout: const Duration(milliseconds: 150),
          cooldown: const Duration(seconds: 30),
          maxSwitches: 3,
          onSwitch: (track, failed, next) {
            if (track == CdnRelayTrack.video) switches.add((failed, next));
          },
        );

        final client = HttpClient();
        final request = await client.getUrl(Uri.parse(session.videoUrl));
        final response = await request.close();
        final bytes = await response.fold<List<int>>(
          <int>[],
          (buffer, chunk) => buffer..addAll(chunk),
        );
        client.close(force: true);

        expect(bytes, payload);
        expect(switches, hasLength(1));
        expect(
          session.currentVideoSource,
          contains('localhost:${second.port}'),
        );
      },
    );

    test('forwards byte ranges without changing the player URL', () async {
      final payload = List<int>.generate(32, (index) => index);
      final upstream = await _startUpstream(payload);
      upstreamServers.add(upstream);
      final session = await relayServer.createSession(
        videoCandidates: ['http://127.0.0.1:${upstream.port}/video.m4s'],
        videoIndex: 0,
        stallTimeout: const Duration(seconds: 1),
        cooldown: const Duration(seconds: 30),
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
  });
}

Future<HttpServer> _startUpstream(
  List<int> payload, {
  int? stallAfterBytes,
  Duration stallFor = Duration.zero,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
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
        ? body.length
        : stallAfterBytes.clamp(0, body.length);
    try {
      response.add(body.sublist(0, firstLength));
      await response.flush();
      if (firstLength < body.length) {
        await Future<void>.delayed(stallFor);
        response.add(body.sublist(firstLength));
      }
      await response.close();
    } catch (_) {
      // The relay intentionally cancels a stalled upstream request.
    }
  });
  return server;
}
