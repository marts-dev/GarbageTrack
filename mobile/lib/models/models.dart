// API data models. Enums are kept as validated strings to match the API.

const garbageTypes = [
  'plastic',
  'organic',
  'paper',
  'glass',
  'metal',
  'electronic',
  'hazardous',
  'textile',
  'general',
];

const userRoles = ['resident', 'collector', 'logistics', 'admin'];

const facilityKinds = ['dump_site', 'recycling', 'waste_center'];

const truckStatuses = ['scheduled', 'enroute', 'done'];
const truckAvailabilities = ['available', 'working', 'full'];
const garbageStatuses = ['posted', 'scheduled', 'collected'];
const routeStatuses = ['assigned', 'in_progress', 'done', 'cancelled'];

String pretty(String value) => value
    .split('_')
    .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
    .join(' ');

class GeoPoint {
  final double longitude;
  final double latitude;

  GeoPoint({required this.longitude, required this.latitude});

  factory GeoPoint.fromJson(Map<String, dynamic> json) {
    final coords = (json['coordinates'] as List)
        .map((e) => (e as num).toDouble())
        .toList();
    return GeoPoint(longitude: coords[0], latitude: coords[1]);
  }

  Map<String, dynamic> toJson() => {
        'type': 'Point',
        'coordinates': [longitude, latitude],
      };

  String get short => '${latitude.toStringAsFixed(4)}, ${longitude.toStringAsFixed(4)}';
}

class User {
  final String id;
  final String email;
  final String? fullName;
  final String role;
  final bool isActive;

  User({
    required this.id,
    required this.email,
    required this.role,
    required this.isActive,
    this.fullName,
  });

  factory User.fromJson(Map<String, dynamic> json) => User(
        id: json['id'] as String,
        email: json['email'] as String,
        fullName: json['full_name'] as String?,
        role: json['role'] as String,
        isActive: json['is_active'] as bool? ?? true,
      );

  bool get isAdmin => role == 'admin';
  bool get isCollector => isAdmin || role == 'collector';
  bool get isLogistics => isAdmin || role == 'logistics';

  /// Greeting name: the user's fullName, or the capitalized role when empty.
  String get displayName {
    final name = fullName?.trim();
    if (name != null && name.isNotEmpty) return name;
    return pretty(role);
  }
}

class Tokens {
  final String accessToken;
  final String refreshToken;

  Tokens({required this.accessToken, required this.refreshToken});

  factory Tokens.fromJson(Map<String, dynamic> json) => Tokens(
        accessToken: json['access_token'] as String,
        refreshToken: json['refresh_token'] as String,
      );
}

class UserLocation {
  final String userId;
  final GeoPoint location;
  final DateTime updatedAt;

  UserLocation({required this.userId, required this.location, required this.updatedAt});

  factory UserLocation.fromJson(Map<String, dynamic> json) => UserLocation(
        userId: json['user_id'] as String,
        location: GeoPoint.fromJson(json['location'] as Map<String, dynamic>),
        updatedAt: DateTime.parse(json['updated_at'] as String),
      );
}

class GarbagePost {
  final String id;
  final String userId;
  final GeoPoint location;
  final List<String> types;
  final String? description;
  final bool hasImage;
  final String? imageContentType;
  final String status;
  final DateTime createdAt;
  final DateTime? collectedAt;

  GarbagePost({
    required this.id,
    required this.userId,
    required this.location,
    required this.types,
    required this.status,
    required this.createdAt,
    this.description,
    required this.hasImage,
    this.imageContentType,
    this.collectedAt,
  });

  factory GarbagePost.fromJson(Map<String, dynamic> json) => GarbagePost(
        id: json['id'] as String,
        userId: json['user_id'] as String,
        location: GeoPoint.fromJson(json['location'] as Map<String, dynamic>),
        types: (json['types'] as List).map((e) => e as String).toList(),
        description: json['description'] as String?,
        hasImage: json['has_image'] as bool? ?? false,
        imageContentType: json['image_content_type'] as String?,
        status: json['status'] as String,
        createdAt: DateTime.parse(json['created_at'] as String),
        collectedAt: json['collected_at'] == null
            ? null
            : DateTime.parse(json['collected_at'] as String),
      );
}

class Truck {
  final String id;
  final String plateNumber;
  final String status;
  final String availability;
  final List<String> garbageTypes;
  final GeoPoint? currentLocation;
  final int? etaMinutes;
  final int? capacity;
  final int load;

  Truck({
    required this.id,
    required this.plateNumber,
    required this.status,
    required this.availability,
    required this.garbageTypes,
    required this.load,
    this.currentLocation,
    this.etaMinutes,
    this.capacity,
  });

  factory Truck.fromJson(Map<String, dynamic> json) => Truck(
        id: json['id'] as String,
        plateNumber: json['plate_number'] as String,
        status: json['status'] as String,
        availability: json['availability'] as String? ?? 'available',
        garbageTypes:
            (json['garbage_types'] as List).map((e) => e as String).toList(),
        currentLocation: json['current_location'] == null
            ? null
            : GeoPoint.fromJson(json['current_location'] as Map<String, dynamic>),
        etaMinutes: (json['eta_minutes'] as num?)?.toInt(),
        capacity: (json['capacity'] as num?)?.toInt(),
        load: (json['load'] as num?)?.toInt() ?? 0,
      );

  int? get remainingCapacity => capacity == null ? null : capacity! - load;
}

class RouteStop {
  final String postId;
  final GeoPoint location;
  final List<String> types;
  final String status;
  final double? distanceMeters;

  RouteStop({
    required this.postId,
    required this.location,
    required this.types,
    required this.status,
    this.distanceMeters,
  });

  factory RouteStop.fromJson(Map<String, dynamic> json) => RouteStop(
        postId: json['post_id'] as String,
        location: GeoPoint.fromJson(json['location'] as Map<String, dynamic>),
        types: (json['types'] as List).map((e) => e as String).toList(),
        status: json['status'] as String,
        distanceMeters: (json['distance_meters'] as num?)?.toDouble(),
      );
}

class CollectionRoute {
  final String truckId;
  final GeoPoint origin;
  final int? remainingCapacity;
  final List<RouteStop> stops;

  CollectionRoute({
    required this.truckId,
    required this.origin,
    required this.stops,
    this.remainingCapacity,
  });

  factory CollectionRoute.fromJson(Map<String, dynamic> json) => CollectionRoute(
        truckId: json['truck_id'] as String,
        origin: GeoPoint.fromJson(json['origin'] as Map<String, dynamic>),
        remainingCapacity: (json['remaining_capacity'] as num?)?.toInt(),
        stops: (json['stops'] as List)
            .map((e) => RouteStop.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class CollectResult {
  final String truckId;
  final int collectedCount;
  final List<String> postIds;
  final int load;
  final int? capacity;
  final String availability;

  CollectResult({
    required this.truckId,
    required this.collectedCount,
    required this.postIds,
    required this.load,
    required this.availability,
    this.capacity,
  });

  factory CollectResult.fromJson(Map<String, dynamic> json) => CollectResult(
        truckId: json['truck_id'] as String,
        collectedCount: (json['collected_count'] as num).toInt(),
        postIds: (json['post_ids'] as List).map((e) => e as String).toList(),
        load: (json['load'] as num).toInt(),
        capacity: (json['capacity'] as num?)?.toInt(),
        availability: json['availability'] as String,
      );
}

class Facility {
  final String id;
  final String name;
  final String kind;
  final GeoPoint location;
  final List<String> acceptedTypes;
  final String? address;

  Facility({
    required this.id,
    required this.name,
    required this.kind,
    required this.location,
    required this.acceptedTypes,
    this.address,
  });

  factory Facility.fromJson(Map<String, dynamic> json) => Facility(
        id: json['id'] as String,
        name: json['name'] as String,
        kind: json['kind'] as String,
        location: GeoPoint.fromJson(json['location'] as Map<String, dynamic>),
        acceptedTypes:
            (json['accepted_types'] as List).map((e) => e as String).toList(),
        address: json['address'] as String?,
      );
}

class PlannedStop {
  final String postId;
  final GeoPoint location;
  final List<String> types;
  final double? distanceMeters;

  PlannedStop({
    required this.postId,
    required this.location,
    required this.types,
    this.distanceMeters,
  });

  factory PlannedStop.fromJson(Map<String, dynamic> json) => PlannedStop(
        postId: json['post_id'] as String,
        location: GeoPoint.fromJson(json['location'] as Map<String, dynamic>),
        types: (json['types'] as List).map((e) => e as String).toList(),
        distanceMeters: (json['distance_meters'] as num?)?.toDouble(),
      );
}

class PlannedRoute {
  final String id;
  final String truckId;
  final String? name;
  final GeoPoint origin;
  final List<PlannedStop> stops;
  final String status;

  PlannedRoute({
    required this.id,
    required this.truckId,
    required this.origin,
    required this.stops,
    required this.status,
    this.name,
  });

  factory PlannedRoute.fromJson(Map<String, dynamic> json) => PlannedRoute(
        id: json['id'] as String,
        truckId: json['truck_id'] as String,
        name: json['name'] as String?,
        origin: GeoPoint.fromJson(json['origin'] as Map<String, dynamic>),
        stops: (json['stops'] as List)
            .map((e) => PlannedStop.fromJson(e as Map<String, dynamic>))
            .toList(),
        status: json['status'] as String,
      );
}

class GarbageSummary {
  final int total;
  final Map<String, int> byStatus;
  final Map<String, int> byType;

  GarbageSummary({required this.total, required this.byStatus, required this.byType});

  factory GarbageSummary.fromJson(Map<String, dynamic> json) => GarbageSummary(
        total: (json['total'] as num).toInt(),
        byStatus: (json['by_status'] as Map).map((k, v) => MapEntry(k as String, (v as num).toInt())),
        byType: (json['by_type'] as Map).map((k, v) => MapEntry(k as String, (v as num).toInt())),
      );
}

class ClassifyResult {
  final List<String> suggestedTypes;
  final double confidence;
  final bool placeholder;
  final String message;

  ClassifyResult({
    required this.suggestedTypes,
    required this.confidence,
    required this.placeholder,
    required this.message,
  });

  factory ClassifyResult.fromJson(Map<String, dynamic> json) => ClassifyResult(
        suggestedTypes:
            (json['suggested_types'] as List).map((e) => e as String).toList(),
        confidence: (json['confidence'] as num).toDouble(),
        placeholder: json['placeholder'] as bool? ?? false,
        message: json['message'] as String? ?? '',
      );
}
