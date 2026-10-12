import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:google_maps_flutter/google_maps_flutter.dart';

class LocationSuggestion {
  const LocationSuggestion({required this.address, required this.placeId});

  final String address;
  final String placeId;
}

class LocationSearchResult {
  const LocationSearchResult({
    required this.address,
    required this.coordinates,
  });

  final String address;
  final LatLng coordinates;
}

class LocationHelper {
  static const String _googleApiKey = 'AIzaSyCEkjoOnXRf6c9Xzml2QPNvZoq2LuG06JI';

  static Future<List<LatLng>> getTwoWheelerRoute({
    required LatLng origin,
    required LatLng destination,
  }) async {
    final response = await http.post(
      Uri.https('routes.googleapis.com', '/directions/v2:computeRoutes'),
      headers: {
        'Content-Type': 'application/json',
        'X-Goog-Api-Key': _googleApiKey,
        'X-Goog-FieldMask': 'routes.polyline.encodedPolyline',
      },
      body: jsonEncode({
        'origin': {
          'location': {
            'latLng': {
              'latitude': origin.latitude,
              'longitude': origin.longitude,
            },
          },
        },
        'destination': {
          'location': {
            'latLng': {
              'latitude': destination.latitude,
              'longitude': destination.longitude,
            },
          },
        },
        'travelMode': 'TWO_WHEELER',
        'polylineQuality': 'OVERVIEW',
      }),
    );

    final data = jsonDecode(response.body);
    if (response.statusCode != 200) {
      String? message;
      if (data is Map) {
        final errorData = data['error'];
        if (errorData is Map) message = errorData['message']?.toString();
      }
      throw Exception(message ?? 'Google Maps could not calculate this route.');
    }

    final routes = data is Map ? data['routes'] : null;
    final firstRoute =
        routes is List && routes.isNotEmpty ? routes.first : null;
    final polyline = firstRoute is Map ? firstRoute['polyline'] : null;
    final encodedPolyline =
        polyline is Map ? polyline['encodedPolyline'] : null;
    if (encodedPolyline is! String || encodedPolyline.isEmpty) {
      throw Exception('No two-wheeler route was returned for this location.');
    }

    return _decodePolyline(encodedPolyline);
  }

  static List<LatLng> _decodePolyline(String encoded) {
    final points = <LatLng>[];
    var index = 0;
    var latitude = 0;
    var longitude = 0;

    while (index < encoded.length) {
      var result = 0;
      var shift = 0;
      int chunk;
      do {
        chunk = encoded.codeUnitAt(index++) - 63;
        result |= (chunk & 0x1f) << shift;
        shift += 5;
      } while (chunk >= 0x20 && index < encoded.length);
      latitude += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);

      result = 0;
      shift = 0;
      do {
        chunk = encoded.codeUnitAt(index++) - 63;
        result |= (chunk & 0x1f) << shift;
        shift += 5;
      } while (chunk >= 0x20 && index < encoded.length);
      longitude += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);

      points.add(LatLng(latitude / 1e5, longitude / 1e5));
    }

    return points;
  }

  static Future<String> getAddressFromCoordinates(
    double lat,
    double lon,
  ) async {
    final url = Uri.parse(
      'https://maps.googleapis.com/maps/api/geocode/json?latlng=$lat,$lon&key=$_googleApiKey',
    );

    try {
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['status'] == 'OK' && data['results'].isNotEmpty) {
          return data['results'][0]['formatted_address'];
        } else {
          return "No address found";
        }
      } else {
        return "Error fetching address";
      }
    } catch (e) {
      print("Google API exception: $e");
      return "Error getting address";
    }
  }

  /// Resolves a Google Maps URL (including short links) to a map coordinate.
  static Future<LatLng> getCoordinatesFromMapLink(String mapLink) async {
    final raw = mapLink.trim();
    final normalized = raw.contains('://') ? raw : 'https://$raw';
    final inputUri = Uri.tryParse(normalized);
    if (raw.isEmpty || inputUri == null) {
      throw const FormatException('Enter a valid Google Maps link.');
    }

    if (!inputUri.hasScheme || inputUri.host.isEmpty) {
      throw const FormatException('Enter a valid Google Maps link.');
    }

    // http.get follows redirects automatically, but its Request URL may still
    // be the original maps.app.goo.gl link. Follow Location headers ourselves
    // so the expanded URL can be inspected for coordinates/place details.
    var resolvedUri = await _expandMapUrl(inputUri);

    final urls = <Uri>[resolvedUri, inputUri];
    for (final uri in urls) {
      final coordinate = _coordinatesFromMapUrl(uri);
      if (coordinate != null) return coordinate;
    }

    String? placeId;
    String? address;
    for (final uri in urls) {
      placeId ??=
          uri.queryParameters['query_place_id'] ??
          uri.queryParameters['place_id'];
      address ??=
          uri.queryParameters['q'] ??
          uri.queryParameters['query'] ??
          uri.queryParameters['destination'];
      if ((address == null || address.trim().isEmpty) &&
          uri.pathSegments.length > 1) {
        final placeIndex = uri.pathSegments.indexOf('place');
        if (placeIndex >= 0 && placeIndex + 1 < uri.pathSegments.length) {
          address = uri.pathSegments[placeIndex + 1].replaceAll('+', ' ');
        }
      }
    }

    // A short URL itself is not an address. If Google did not expand it and
    // there are no coordinates/place details in it, avoid geocoding the URL.
    final isShortMapsLink =
        inputUri.host == 'maps.app.goo.gl' ||
        inputUri.host.endsWith('.maps.app.goo.gl') ||
        inputUri.host == 'goo.gl';
    if ((address == null || address.trim().isEmpty) &&
        (placeId == null || placeId.trim().isEmpty)) {
      if (isShortMapsLink) {
        throw StateError(
          'Could not expand this shortened Google Maps link. Paste the full Maps URL and try again.',
        );
      }
      address = raw;
    }

    final query = <String, String>{'key': _googleApiKey};
    if (placeId != null && placeId.trim().isNotEmpty) {
      query['place_id'] = placeId.trim();
    } else {
      query['address'] = address?.trim() ?? '';
    }
    final response = await http
        .get(Uri.https('maps.googleapis.com', '/maps/api/geocode/json', query))
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw StateError('Google Maps could not resolve this link.');
    }

    final data = jsonDecode(response.body);
    final results = data is Map ? data['results'] : null;
    if (data is! Map ||
        data['status'] != 'OK' ||
        results is! List ||
        results.isEmpty) {
      throw StateError('This map link did not resolve to a location.');
    }
    final geometry = results.first is Map ? results.first['geometry'] : null;
    final location = geometry is Map ? geometry['location'] : null;
    if (location is! Map) {
      throw StateError('Google Maps returned no coordinates for this link.');
    }
    final latitude = double.tryParse(location['lat']?.toString() ?? '');
    final longitude = double.tryParse(location['lng']?.toString() ?? '');
    if (!_validCoordinates(latitude, longitude)) {
      throw StateError('Google Maps returned invalid coordinates.');
    }
    return LatLng(latitude!, longitude!);
  }

  static Future<Uri> _expandMapUrl(Uri initialUri) async {
    final client = http.Client();
    var currentUri = initialUri;
    try {
      for (var redirects = 0; redirects < 10; redirects++) {
        final request =
            http.Request('GET', currentUri)
              ..followRedirects = false
              ..headers['User-Agent'] =
                  'Mozilla/5.0 (Linux; Android 10) AppleWebKit/537.36 '
                  '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';
        final response = await client
            .send(request)
            .timeout(const Duration(seconds: 12));
        final location = response.headers['location'];
        if (response.statusCode >= 300 &&
            response.statusCode < 400 &&
            location != null &&
            location.trim().isNotEmpty) {
          await response.stream.drain<void>();
          currentUri = currentUri.resolve(location.trim());
          continue;
        }
        await response.stream.drain<void>();
        return currentUri;
      }
      return currentUri;
    } catch (_) {
      // If expansion is unavailable, the original URL may still contain
      // coordinates or a place query that can be resolved below.
      return currentUri;
    } finally {
      client.close();
    }
  }

  static String newLocationSearchSession() => base64UrlEncode(
    List<int>.generate(24, (_) => Random.secure().nextInt(256)),
  );

  static Map<String, dynamic> _placeResponse(http.Response response) {
    if (response.statusCode != 200) {
      throw StateError('Location search is unavailable. Please try again.');
    }
    dynamic data;
    try {
      data = jsonDecode(response.body);
    } catch (_) {
      throw StateError('Location search returned an invalid response.');
    }
    if (data is! Map || data.containsKey('error')) {
      throw StateError('Location search is unavailable. Please try again.');
    }
    return Map<String, dynamic>.from(data);
  }

  static Future<List<LocationSuggestion>> suggestLocations(
    String query, {
    required String sessionToken,
    required LatLng bias,
  }) async {
    if (query.trim().isEmpty) return [];
    final response = await http
        .post(
          Uri.https('places.googleapis.com', '/v1/places:autocomplete'),
          headers: {
            'Content-Type': 'application/json',
            'X-Goog-Api-Key': _googleApiKey,
            'X-Goog-FieldMask':
                'suggestions.placePrediction.placeId,suggestions.placePrediction.text.text',
          },
          body: jsonEncode({
            'input': query.trim(),
            'sessionToken': sessionToken,
            'regionCode': 'in',
            'locationBias': {
              'circle': {
                'center': {
                  'latitude': bias.latitude,
                  'longitude': bias.longitude,
                },
                'radius': 50000,
              },
            },
          }),
        )
        .timeout(const Duration(seconds: 15));
    final data = _placeResponse(response);
    final rows = data['suggestions'];
    if (rows == null) return [];
    if (rows is! List) {
      throw StateError('Location search returned an invalid response.');
    }
    final results = <LocationSuggestion>[];
    for (final row in rows) {
      if (row is! Map || row['placePrediction'] is! Map) continue;
      final prediction = row['placePrediction'] as Map;
      final placeId = prediction['placeId']?.toString().trim() ?? '';
      final text = prediction['text'];
      final address = text is Map ? text['text']?.toString().trim() ?? '' : '';
      if (placeId.isEmpty || address.isEmpty) continue;
      results.add(LocationSuggestion(address: address, placeId: placeId));
      if (results.length == 5) break;
    }
    return results;
  }

  static Future<LocationSearchResult> resolveLocationSuggestion(
    LocationSuggestion suggestion, {
    required String sessionToken,
  }) async {
    final response = await http
        .get(
          Uri(
            scheme: 'https',
            host: 'places.googleapis.com',
            pathSegments: ['v1', 'places', suggestion.placeId],
            queryParameters: {'sessionToken': sessionToken},
          ),
          headers: {
            'X-Goog-Api-Key': _googleApiKey,
            'X-Goog-FieldMask': 'location',
          },
        )
        .timeout(const Duration(seconds: 15));
    final data = _placeResponse(response);
    final location = data['location'];
    if (location is! Map) {
      throw StateError('Google Maps returned no coordinates for this place.');
    }
    final latitude = double.tryParse(location['latitude']?.toString() ?? '');
    final longitude = double.tryParse(location['longitude']?.toString() ?? '');
    if (!_validCoordinates(latitude, longitude)) {
      throw StateError(
        'Google Maps returned invalid coordinates for this place.',
      );
    }
    return LocationSearchResult(
      address: suggestion.address,
      coordinates: LatLng(latitude!, longitude!),
    );
  }

  static Future<List<LocationSearchResult>> searchLocations(
    String query,
  ) async {
    final address = query.trim();
    if (address.isEmpty) return [];
    final response = await http
        .get(
          Uri.https('maps.googleapis.com', '/maps/api/geocode/json', {
            'address': address,
            'region': 'in',
            'key': _googleApiKey,
          }),
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw StateError('Location search is unavailable. Please try again.');
    }
    dynamic data;
    try {
      data = jsonDecode(response.body);
    } catch (_) {
      throw StateError('Location search returned an invalid response.');
    }
    if (data is Map && data['status'] == 'ZERO_RESULTS') return [];
    if (data is! Map || data['status'] != 'OK' || data['results'] is! List) {
      throw StateError('Location search is unavailable. Please try again.');
    }
    final results = <LocationSearchResult>[];
    for (final row in data['results'] as List) {
      if (row is! Map || row['geometry'] is! Map) continue;
      final location = row['geometry']['location'];
      if (location is! Map) continue;
      final latitude = double.tryParse(location['lat']?.toString() ?? '');
      final longitude = double.tryParse(location['lng']?.toString() ?? '');
      final label = row['formatted_address']?.toString().trim() ?? '';
      if (!_validCoordinates(latitude, longitude) || label.isEmpty) continue;
      results.add(
        LocationSearchResult(
          address: label,
          coordinates: LatLng(latitude!, longitude!),
        ),
      );
      if (results.length == 5) break;
    }
    return results;
  }

  /// Reads coordinates already present in a URL without a network request.
  static LatLng? tryCoordinatesFromMapLink(String mapLink) {
    final raw = mapLink.trim();
    if (raw.isEmpty) return null;
    final uri = Uri.tryParse(raw.contains('://') ? raw : 'https://$raw');
    if (uri == null ||
        uri.host.isEmpty ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    return _coordinatesFromMapUrl(uri);
  }

  static LatLng? _coordinatesFromMapUrl(Uri uri) {
    final candidates = <String>[
      uri.queryParameters['q'] ?? '',
      uri.queryParameters['query'] ?? '',
      uri.queryParameters['ll'] ?? '',
      uri.path,
      uri.toString(),
    ];
    final patterns = <RegExp>[
      RegExp(r'@(-?\d+(?:\.\d+)?),\s*(-?\d+(?:\.\d+)?)'),
      RegExp(r'!3d(-?\d+(?:\.\d+)?)!4d(-?\d+(?:\.\d+)?)'),
      RegExp(r'(-?\d+(?:\.\d+)?),\s*(-?\d+(?:\.\d+)?)'),
    ];
    for (final candidate in candidates) {
      for (final pattern in patterns) {
        final match = pattern.firstMatch(candidate);
        if (match == null) continue;
        final latitude = double.tryParse(match.group(1) ?? '');
        final longitude = double.tryParse(match.group(2) ?? '');
        if (_validCoordinates(latitude, longitude)) {
          return LatLng(latitude!, longitude!);
        }
      }
    }
    return null;
  }

  static bool _validCoordinates(double? latitude, double? longitude) =>
      latitude != null &&
      longitude != null &&
      latitude.isFinite &&
      longitude.isFinite &&
      latitude >= -90 &&
      latitude <= 90 &&
      longitude >= -180 &&
      longitude <= 180;

  static Future<Uint8List?> getStaticMapImageBytes(
    double lat,
    double lon, {
    int width = 320,
    int height = 320,
    int zoom = 16,
  }) async {
    final url = Uri.parse(
      'https://maps.googleapis.com/maps/api/staticmap'
      '?center=$lat,$lon'
      '&zoom=$zoom'
      '&size=${width}x$height'
      '&maptype=roadmap'
      '&markers=color:red%7C$lat,$lon'
      '&key=$_googleApiKey',
    );

    try {
      final response = await http.get(url);
      if (response.statusCode == 200) {
        return response.bodyBytes;
      }
      return null;
    } catch (e) {
      print("Static map API exception: $e");
      return null;
    }
  }
}
