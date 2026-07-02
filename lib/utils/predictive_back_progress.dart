import 'package:flutter/foundation.dart';

abstract final class PredictiveBackProgress {
  static final active = ValueNotifier<bool>(false);
  static final progress = ValueNotifier<double>(0);

  static void start(double value) {
    active.value = true;
    update(value);
  }

  static void update(double value) {
    progress.value = value.clamp(0, 1);
  }

  static void reset() {
    progress.value = 0;
    active.value = false;
  }
}
