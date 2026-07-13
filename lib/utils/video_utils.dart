import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/models/common/video/video_decode_type.dart';
import 'package:PiliPlus/models_new/live/live_room_play_info/codec.dart';
import 'package:PiliPlus/utils/extension/iterable_ext.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;

abstract final class VideoUtils {
  static CDNService cdnService = Pref.defaultCDNService;
  static String? liveCdnUrl = Pref.liveCdnUrl;
  static bool disableAudioCDN = Pref.disableAudioCDN;

  static const _proxyTf = 'proxy-tf-all-ws.bilivideo.com';
  static final Map<String, DateTime> _cdnCooldownUntil = {};

  static final _mirrorRegex = RegExp(
    r'^https?://(?:upos-\w+-(?!302)\w+|(?:upos|proxy)-tf-[^/]+)\.(?:bilivideo|akamaized)\.(?:com|net)/upgcxcode',
  );

  static final _mCdnTfRegex = RegExp(
    r'^https?://(?:(?:(?:\d{1,3}\.){3}\d{1,3}|[^/]+\.mcdn\.bilivideo\.(?:com|cn|net))(?:\:\d{1,5})?/v\d/resource)',
  );

  static String getCdnUrl(
    Iterable<String> urls, {
    CDNService? defaultCDNService,
    bool isAudio = false,
    bool preferBackup = false,
  }) {
    defaultCDNService ??= cdnService;

    final candidates = urls.toList(growable: false);
    if (candidates.isEmpty) return '';

    if (defaultCDNService == CDNService.baseUrl) {
      return candidates.first;
    }

    // Adaptive mode follows PiliPala by preferring the first backup URL while
    // manual mode preserves PiliPlus's original API ordering.
    final orderedUrls = preferBackup && candidates.length > 1
        ? <String>[...candidates.skip(1), candidates.first]
        : candidates;

    String? mcdnTf;
    String? mcdnUpgcxcode;

    String last = '';
    for (final url in orderedUrls) {
      last = url;
      if (_mirrorRegex.hasMatch(url)) {
        final uri = Uri.parse(url);
        if (uri.queryParameters['os'] == 'mcdn') {
          // upos-sz-mirrorcoso1.bilivideo.com os=mcdn
          mcdnUpgcxcode = url;
        } else {
          if (defaultCDNService == CDNService.backupUrl ||
              (isAudio && disableAudioCDN)) {
            return url;
          }
          return uri.replace(host: defaultCDNService.host).toString();
        }
      }

      if (_mCdnTfRegex.hasMatch(url)) {
        mcdnTf = url;
        continue;
      }

      // upos-\w*-302.* & bcache & mcdn host but upgcxcode path
      if (url.contains('/upgcxcode/')) {
        mcdnUpgcxcode = url;
        continue;
      }

      // may be deprecated
      if (url.contains('szbdyd.com')) {
        final uri = Uri.parse(url);
        final hostname =
            uri.queryParameters['xy_usource'] ?? defaultCDNService.host;
        return uri
            .replace(scheme: 'https', host: hostname, port: 443)
            .toString();
      }

      if (kDebugMode) {
        debugPrint('unknown cdn type: $url');
      }
    }

    return mcdnUpgcxcode == null
        ? mcdnTf == null
              ? last
              : Uri(
                  scheme: 'https',
                  host: _proxyTf,
                  queryParameters: {'url': mcdnTf},
                ).toString()
        : Uri.parse(mcdnUpgcxcode)
              .replace(host: defaultCDNService.host ?? CDNService.ali.host)
              .toString();
  }

  static List<String> getCdnCandidates(
    Iterable<String> urls, {
    bool isAudio = false,
    CDNService? preferredService,
  }) {
    final sourceUrls = urls.toList(growable: false);
    if (sourceUrls.isEmpty) return const [];

    final services = <CDNService>[
      preferredService ?? cdnService,
      CDNService.backupUrl,
      CDNService.baseUrl,
      ...CDNService.values,
    ];
    final candidates = <String>{};
    for (final service in services) {
      final candidate = getCdnUrl(
        sourceUrls,
        defaultCDNService: service,
        isAudio: isAudio,
        preferBackup: true,
      );
      if (candidate.isNotEmpty) candidates.add(candidate);
    }
    return candidates.toList(growable: false);
  }

  static String? cdnHost(String? url) {
    if (url == null || url.isEmpty) return null;
    return Uri.tryParse(url)?.host.toLowerCase();
  }

  static void markCdnFailed(String? url, {Duration? cooldown}) {
    final host = cdnHost(url);
    if (host == null || host.isEmpty) return;
    _cdnCooldownUntil[host] = DateTime.now().add(
      cooldown ??
          Duration(
            milliseconds: (Pref.adaptiveCdnCooldownSec * 1000).round(),
          ),
    );
  }

  static bool isCdnCoolingDown(String url) {
    final host = cdnHost(url);
    if (host == null || host.isEmpty) return false;
    final until = _cdnCooldownUntil[host];
    if (until == null) return false;
    if (DateTime.now().isBefore(until)) return true;
    _cdnCooldownUntil.remove(host);
    return false;
  }

  static String getLiveCdnUrl(CodecItem e, {int index = 0}) {
    final urlInfo = e.urlInfo.getOrFirst(index);
    return (liveCdnUrl ?? urlInfo.host) + e.baseUrl + urlInfo.extra;
  }

  static VideoDecodeFormatType selectCodec(
    Iterable<String> codecs,
    List<VideoDecodeFormatType> preferCodecs,
  ) {
    if (preferCodecs.isNotEmpty) {
      int bestIndex = preferCodecs.length;
      for (final e in codecs) {
        for (int i = 0; i < bestIndex; i++) {
          if (preferCodecs[i].codes.any(e.startsWith)) {
            bestIndex = i;
            if (bestIndex == 0) {
              return preferCodecs[0];
            }
            break;
          }
        }
      }
      if (bestIndex < preferCodecs.length) {
        return preferCodecs[bestIndex];
      }
    }
    return VideoDecodeFormatType.fromString(codecs.first);
  }
}
