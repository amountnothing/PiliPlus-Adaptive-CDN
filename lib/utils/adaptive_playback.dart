import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/foundation.dart';

abstract final class AdaptivePlayback {
  static final ValueNotifier<bool> enabled = ValueNotifier(
    Pref.adaptivePlayback,
  );
  static final ValueNotifier<bool> manualControlsEnabled = ValueNotifier(
    !Pref.adaptivePlayback,
  );

  static void setEnabled(bool value) {
    enabled.value = value;
    manualControlsEnabled.value = !value;
  }
}
