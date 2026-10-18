enum VideoQuality {
  hdrVivid(129, 'HDR Vivid', 'HDR Vivid'),
  super8k(127, '8K 超高清', '8K'),
  dolbyVision(126, '杜比视界', '杜比'),
  hdr(125, 'HDR 真彩', 'HDR'),
  super4K(120, '4K 超高清', '4K'),
  high108060(116, '1080P 60帧', '1080P60'),
  high1080plus(112, '1080P 高码率', '1080P+'),
  superResolution(100, '智能修复', '智能修复'),
  high1080(80, '1080P 高清', '1080P'),
  high72060(74, '720P 60帧', '720P60'),
  high720(64, '720P 准高清', '720P'),
  clear480(32, '480P 标清', '480P'),
  fluent360(16, '360P 流畅', '360P'),
  speed240(6, '240P 极速', '240P'),
  ;

  final int code;
  final String desc;
  final String shortDesc;

  const VideoQuality(this.code, this.desc, this.shortDesc);

  static final _codeMap = {for (final i in values) i.code: i};

  // Bilibili adds new quality ids without notice (e.g. VIP-only bangumi
  // tiers). Unknown ids fall back to the nearest known tier at or below the
  // requested code instead of throwing.
  static VideoQuality fromCode(int code) {
    final exact = _codeMap[code];
    if (exact != null) return exact;
    VideoQuality fallback = speed240;
    for (final q in values) {
      if (q.code <= code && q.code > fallback.code) fallback = q;
    }
    return fallback;
  }
}
