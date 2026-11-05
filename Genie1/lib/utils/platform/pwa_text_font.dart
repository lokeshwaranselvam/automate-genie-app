import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Keep normal text from falling back to icon glyphs after a failed font fetch.
Future<void> loadPwaTextFont() async {
  if (!kIsWeb) return;
  for (var attempt = 0; attempt < 3; attempt++) {
    try {
      final loader = FontLoader('Roboto');
      for (final weight in ['Regular', 'Medium', 'Bold']) {
        loader.addFont(rootBundle.load('fonts/Roboto-$weight.ttf'));
      }
      await loader.load();
      return;
    } catch (_) {
      if (attempt == 2) {
        debugPrint('PWA text font could not load. Check the connection and refresh.');
      } else {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
  }
}
