/*
 * Copyright Haveno
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import 'dart:async';

/// Run a task in a fixed period loop.
class TaskLooper {
  final Future<void> Function() _fn;
  bool _isStarted = false;
  bool _isLooping = false;
  Timer? _timer;
  Completer<void>? _wake;

  /// Build the looper with a function to invoke on a fixed period loop.
  TaskLooper(this._fn);

  /// True while the loop is actively running tasks.
  bool get isStarted => _isStarted;
  bool get isLooping => _isLooping;

  /// Start the task loop with the given period.
  /// If [targetFixedPeriod] is true, run time is accounted for so the loop
  /// targets a fixed period.
  void start(int periodInMs, {bool targetFixedPeriod = false}) {
    if (periodInMs <= 0) throw ArgumentError('Looper period must be greater than 0 ms');
    if (_isStarted) return;
    _isStarted = true;
    _runLoop(periodInMs, targetFixedPeriod);
  }

  /// Stop the task loop.
  void stop() {
    if (!_isStarted) throw StateError("Cannot stop TaskLooper because it's not started");
    _isStarted = false;
    _timer?.cancel();
    _timer = null;
    _wake?.complete();
    _wake = null;
  }

  Future<void> _runLoop(int periodInMs, bool targetFixedPeriod) async {
    _isLooping = true;
    while (_isStarted) {
      final startTime = DateTime.now().millisecondsSinceEpoch;
      await _fn();
      if (!_isStarted) break;
      final elapsed = targetFixedPeriod ? DateTime.now().millisecondsSinceEpoch - startTime : 0;
      final waitMs = periodInMs - elapsed;
      if (waitMs <= 0) continue;
      _wake = Completer<void>();
      _timer = Timer(Duration(milliseconds: waitMs), () => _wake?.complete());
      await _wake!.future;
      _timer = null;
      _wake = null;
    }
    _isLooping = false;
  }
}
