/// Categories whose Events do not require a saved destination.
bool isLocationFreeEventCategory(Object? category) => const {
  'other',
  'others',
  'bank',
  'head office ch',
  'timbe / bioman office ch',
  'collection',
}.contains(category?.toString().trim().toLowerCase());

/// The API controls the requirement; older servers retain the category policy.
bool eventRequiresSavedLocation(Map details) {
  final required = details['requires_saved_location'];
  if (required is bool) return required;
  final event = details['event'];
  return !isLocationFreeEventCategory(
    event is Map
        ? event['event_category'] ?? event['custom_event_category']
        : null,
  );
}

bool eventRequiresGeofence(Map details) {
  final event = details['event'];
  if (event is Map &&
      isLocationFreeEventCategory(
        event['event_category'] ?? event['custom_event_category'],
      )) {
    return false;
  }
  // Preserve the server decision and older-server behavior for other categories.
  return details['requires_geofence'] != false;
}

double _positiveRadius(Object? value, double fallback) =>
    value is num && value.isFinite && value > 0 ? value.toDouble() : fallback;

double eventCheckInRadiusMeters(Map policy) =>
    _positiveRadius(policy['visit_checkin_radius_meters'], 100);

double eventMonitoringRadiusMeters(Map policy) =>
    _positiveRadius(policy['visit_monitoring_radius_meters'], 200);

bool eventMonitoringEnabled(Map policy) =>
    policy['visit_monitoring_enabled'] != false;

bool eventGeofencingEnabled(Map policy) =>
    policy['visit_geofencing_enabled'] != false;

bool eventRequiresCheckoutPhoto(Map policy) =>
    policy['requires_checkout_photo'] != false;

/// Older report APIs retain the existing checkout rule.
bool eventRequiresCheckoutLocation(
  Map policy, {
  required String category,
  required String visitType,
  required bool legacyRequired,
}) {
  final categories = policy['checkout_location_categories'];
  final visitTypes = policy['checkout_location_visit_types'];
  if (categories is! List ||
      visitTypes is! List ||
      categories.any((value) => value is! String) ||
      visitTypes.any((value) => value is! String)) {
    return legacyRequired;
  }
  return categories.contains(category) &&
      visitTypes.any((value) => value.toLowerCase() == visitType.toLowerCase());
}
