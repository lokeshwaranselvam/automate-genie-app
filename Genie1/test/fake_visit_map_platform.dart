import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
// The installed Google Maps plugin exposes its test adapter through this
// existing transitive package; no production dependency is needed.
// ignore: depend_on_referenced_packages
import 'package:google_maps_flutter_platform_interface/google_maps_flutter_platform_interface.dart';

class FakeVisitMapPlatform extends MethodChannelGoogleMapsFlutter {
  final _createdMaps = <int>{};
  final calls = <MethodCall>[];

  @override
  Stream<GroundOverlayTapEvent> onGroundOverlayTap({required int mapId}) =>
      const Stream<GroundOverlayTapEvent>.empty();

  @override
  Future<void> updateGroundOverlays(
    GroundOverlayUpdates updates, {
    required int mapId,
  }) async {}

  @override
  Widget buildViewWithConfiguration(
    int creationId,
    PlatformViewCreatedCallback onPlatformViewCreated, {
    required MapWidgetConfiguration widgetConfiguration,
    MapConfiguration mapConfiguration = const MapConfiguration(),
    MapObjects mapObjects = const MapObjects(),
  }) {
    if (_createdMaps.add(creationId)) {
      final channel = ensureChannelInitialized(creationId);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return null;
          });
      onPlatformViewCreated(creationId);
    }
    return const SizedBox.expand();
  }
}
