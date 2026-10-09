import 'dart:math' as math;

/// Detects real movement of an accepted, assigned vehicle over repeated polls.
/// A crew assignment alone never means the driver is on the way.
class DriverMovementEvidence {
  int? _orderId;
  int? _crewId;
  double? _anchorLat;
  double? _anchorLon;
  int _validLocationSamples = 0;
  int _consecutiveSpeedSamples = 0;
  bool _moving = false;

  void reset() {
    _orderId = null;
    _crewId = null;
    _anchorLat = null;
    _anchorLon = null;
    _validLocationSamples = 0;
    _consecutiveSpeedSamples = 0;
    _moving = false;
  }

  bool update({
    required int orderId,
    required int crewId,
    required String stateKind,
    required bool confirmedAssignment,
    double? latitude,
    double? longitude,
    double? speed,
  }) {
    if (orderId <= 0 ||
        crewId <= 0 ||
        stateKind.trim().toLowerCase() != 'driver_assigned' ||
        !confirmedAssignment) {
      reset();
      return false;
    }
    if (_orderId != orderId || _crewId != crewId) {
      reset();
      _orderId = orderId;
      _crewId = crewId;
    }
    if (_moving) return true; // Do not regress when the car stops at a light.

    // Speed is telemetry, unlike assignment or elapsed booking time.
    // Require repeat evidence for low speeds; a clearly moving vehicle
    // can be shown immediately. Missing speed alone proves nothing.
    final currentSpeed = speed != null && speed.isFinite && speed > 0
        ? speed
        : 0.0;
    if (currentSpeed > 12) {
      _moving = true;
      return true;
    }
    if (currentSpeed > 3) {
      _consecutiveSpeedSamples++;
      if (_consecutiveSpeedSamples >= 2) {
        _moving = true;
        return true;
      }
    } else {
      _consecutiveSpeedSamples = 0;
    }

    if (latitude == null ||
        longitude == null ||
        !latitude.isFinite ||
        !longitude.isFinite ||
        latitude.abs() > 90 ||
        longitude.abs() > 180 ||
        (latitude == 0 && longitude == 0)) {
      return false; // Preserve GPS anchor across missing polls.
    }

    final lat = latitude;
    final lon = longitude;
    if (_anchorLat == null || _anchorLon == null) {
      _anchorLat = lat;
      _anchorLon = lon;
      _validLocationSamples = 1;
      return false;
    }

    final meters = _distanceMeters(_anchorLat!, _anchorLon!, lat, lon);
    if (meters > 1500) {
      // Reject a GPS teleport rather than claiming movement.
      _anchorLat = lat;
      _anchorLon = lon;
      _validLocationSamples = 1;
      return false;
    }
    _validLocationSamples++;
    // Previous code required >60 m *between adjacent 4-second polls*.
    // Accumulate displacement from the first reliable point instead.
    if (_validLocationSamples >= 3 && meters >= 25) {
      _moving = true;
    }
    return _moving;
  }

  static double _distanceMeters(double lat1, double lon1, double lat2, double lon2) {
    const earthRadiusMeters = 6371000.0;
    final dLat = (lat2 - lat1) * math.pi / 180;
    final dLon = (lon2 - lon1) * math.pi / 180;
    final latitude1 = lat1 * math.pi / 180;
    final latitude2 = lat2 * math.pi / 180;
    final sinLat = math.sin(dLat / 2);
    final sinLon = math.sin(dLon / 2);
    final h = sinLat * sinLat +
        math.cos(latitude1) * math.cos(latitude2) * sinLon * sinLon;
    return 2 * earthRadiusMeters * math.asin(math.sqrt(h.clamp(0.0, 1.0)));
  }
}
