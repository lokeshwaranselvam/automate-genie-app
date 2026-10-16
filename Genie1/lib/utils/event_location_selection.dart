import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'api/location_api.dart';

String _text(dynamic value) => value?.toString().trim() ?? '';

/// Read the location child table even when the ERP table field was renamed.
List<Map<String, dynamic>> opportunityLocationRows(Map opportunity) {
  final result = <Map<String, dynamic>>[];
  for (final value in opportunity.values) {
    if (value is! List) continue;
    for (final row in value.whereType<Map>()) {
      if (row.containsKey('location_type') &&
          row.containsKey('location') &&
          row.containsKey('latitude') &&
          row.containsKey('longitude')) {
        result.add(Map<String, dynamic>.from(row));
      }
    }
  }
  return result;
}

/// Reference doctypes identify Opportunities; names have no required prefix.
String eventOpportunityName(Map details) {
  final references = details['reference_details'];
  if (references is List) {
    for (final row in references.whereType<Map>()) {
      if (_text(row['doctype'] ?? row['reference_doctype']) == 'Opportunity') {
        final name = _text(row['name'] ?? row['reference_docname']);
        if (name.isNotEmpty) return name;
      }
    }
  }
  final event = details['event'];
  if (event is Map) {
    for (final field in ['event_participants', 'participants']) {
      final participants = event[field];
      if (participants is! List) continue;
      for (final row in participants.whereType<Map>()) {
        if (_text(row['reference_doctype']) == 'Opportunity') {
          final name = _text(row['reference_docname']);
          if (name.isNotEmpty) return name;
        }
      }
    }
  }
  return '';
}

LatLng? eventLocationCoordinates(Map row) {
  final lat = double.tryParse(_text(row['latitude']));
  final lng = double.tryParse(_text(row['longitude']));
  if (lat != null &&
      lng != null &&
      lat.isFinite &&
      lng.isFinite &&
      lat >= -90 &&
      lat <= 90 &&
      lng >= -180 &&
      lng <= 180) {
    return LatLng(lat, lng);
  }
  return LocationHelper.tryCoordinatesFromMapLink(_text(row['location']));
}

/// Resolve the saved destination, never another customer location.
List<Map<String, dynamic>> eventSelectedLocations(
  Map event,
  List<Map<String, dynamic>> rows,
) {
  final references =
      [
        event['custom_validate'],
        event['location'],
        event['custom_location'],
      ].map(_text).where((v) => v.isNotEmpty).toList();
  final savedType = _text(event['custom_location_type']);
  final standardType = _text(event['location']);
  final type =
      savedType.isNotEmpty
          ? savedType
          : const [
            'home',
            'site',
            'office',
            'others',
          ].contains(standardType.toLowerCase())
          ? standardType
          : '';
  for (final field in ['name', 'location']) {
    for (final reference in references) {
      var matches =
          rows.where((row) => _text(row[field]) == reference).toList();
      if (matches.isEmpty) continue;
      if (type.isNotEmpty) {
        matches =
            matches
                .where((row) => _text(row['location_type']) == type)
                .toList();
      }
      if (matches.length == 1) return [matches.single];
      // Duplicate child rows must not erase the Event's own coordinate URL.
      // Continue resolving that destination without selecting an arbitrary row.
    }
  }
  for (final reference in references) {
    final point = LocationHelper.tryCoordinatesFromMapLink(reference);
    if (point == null) continue;
    var matches =
        rows.where((row) {
          final saved = eventLocationCoordinates(row);
          return saved != null &&
              (saved.latitude - point.latitude).abs() < 0.0000001 &&
              (saved.longitude - point.longitude).abs() < 0.0000001;
        }).toList();
    if (type.isNotEmpty) {
      matches =
          matches.where((row) => _text(row['location_type']) == type).toList();
    }
    if (matches.length == 1) return [matches.single];
  }
  // The Event itself retains its selected map URL. Its embedded coordinates
  // remain usable when child rows are missing or duplicated; no geocoding guess.
  for (final reference in references) {
    final point = LocationHelper.tryCoordinatesFromMapLink(reference);
    if (point == null) continue;
    final label =
        type.isNotEmpty
            ? type
            : references.firstWhere(
              (v) => const [
                'home',
                'site',
                'office',
                'others',
              ].contains(v.toLowerCase()),
              orElse: () => '',
            );

    return [
      {
        'location': reference,
        'location_type': label.isEmpty ? 'Selected location' : label,
        'latitude': point.latitude,
        'longitude': point.longitude,
      },
    ];
  }
  final typeReferences = type.isNotEmpty ? [type] : references;
  if (references.isEmpty ||
      references.every(
        (v) => rows.any((row) => _text(row['location_type']) == v),
      )) {
    final matches =
        rows
            .where(
              (row) => typeReferences.contains(_text(row['location_type'])),
            )
            .toList();
    if (matches.length == 1) return [matches.single];
  }
  return [];
}

/// The user-facing value is the selected type, never the map URL.
String eventLocationLabel(Map event, List<Map<String, dynamic>> selectedRows) {
  final candidates = [
    event['custom_location_type'],
    if (selectedRows.length == 1) selectedRows.single['location_type'],
    if (const [
      'home',
      'site',
      'office',
      'others',
    ].contains(_text(event['location']).toLowerCase()))
      event['location'],
  ];
  for (final value in candidates) {
    final label = _text(value);
    if (label.isNotEmpty &&
        label != 'Selected location' &&
        !label.contains('://') &&
        !label.contains('www.')) {
      return label;
    }
  }
  return 'Selected location';
}

/// A coordinate fallback can render a map but cannot invent a saved type.
String? eventSavedLocationType(Map event, List<Map<String, dynamic>> rows) {
  final label = eventLocationLabel(event, rows);
  return label == 'Selected location' ? null : label;
}

bool eventHasCheckInLocation(Map event, List<Map<String, dynamic>> rows) =>
    rows.length == 1 &&
    eventSavedLocationType(event, rows) != null &&
    eventLocationCoordinates(rows.single) != null;
