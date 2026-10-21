/// Distances recorded by the existing Event checkout API, in metres or km.
abstract final class SiteVisitDistance {
  static double? meters(dynamic value) {
    if (value is! String) return null;
    final match = RegExp(
      r'^(\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?)\s*(km|m)$',
    ).firstMatch(value.trim().toLowerCase());
    if (match == null) return null;
    final number = double.tryParse(match.group(1)!.replaceAll(',', ''));
    if (number == null || !number.isFinite) return null;
    final meters = match.group(2) == 'km' ? number * 1000 : number;
    return meters.isFinite ? meters : null;
  }

  static String format(double meters) =>
      meters >= 1000
          ? '${(meters / 1000).toStringAsFixed(2)} km'
          : '${meters.toStringAsFixed(2)} m';
}
