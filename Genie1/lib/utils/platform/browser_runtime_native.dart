import 'dart:async';

void runBrowserApp(Future<void> Function() start) {
  unawaited(start());
}
