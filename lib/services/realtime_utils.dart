import 'package:gtfs_realtime_bindings/gtfs_realtime_bindings.dart';
import 'package:latlong2/latlong.dart';
import '../models/app_models.dart';

/// Puhtaita apufunktioita GTFS-RT-feedien (TripUpdate/VehiclePosition)
/// yhdistämiseen reittisuunnittelun BusLeg-tietoihin.
///
/// Pidetään erillään widgeteistä, jotta logiikka on yksikkötestattavissa.

/// Poistaa namespace-etuliitteen ("waltti:", "HSL:" jne.) ja
/// päivämääräsuffiksin ("_20240330") trip ID:stä vertailua varten.
/// Estää osittaiset osumat, esim. "100123456" ei osu "1001234567":ään.
String _tripCore(String tripId) {
  String id = tripId.contains(':') ? tripId.split(':').last : tripId;
  if (id.contains('_')) id = id.split('_').first;
  return id;
}

bool tripIdMatches(String feedTripId, String legTripId) {
  if (feedTripId == legTripId) return true;
  return _tripCore(feedTripId) == _tripCore(legTripId);
}

DateTime? _findStopTime(
  FeedMessage? tripUpdateFeed,
  BusLeg leg,
  String stopId, {
  required bool preferDeparture,
}) {
  if (tripUpdateFeed == null || leg.tripId.isEmpty) return null;

  for (final entity in tripUpdateFeed.entity) {
    if (!entity.hasTripUpdate()) continue;
    final tripUpdate = entity.tripUpdate;
    final tripId = tripUpdate.trip.tripId;
    if (tripId.isEmpty) continue;

    if (!tripIdMatches(tripId, leg.tripId)) continue;

    for (final stu in tripUpdate.stopTimeUpdate) {
      if (!stu.hasStopId()) continue;
      final updateStopId = stu.stopId;
      final bool stopMatches =
          updateStopId == stopId ||
          stopId.endsWith(':$updateStopId') ||
          stopId == updateStopId;
      if (!stopMatches) continue;

      final first = preferDeparture
          ? (stu.hasDeparture() && stu.departure.hasTime()
              ? DateTime.fromMillisecondsSinceEpoch(stu.departure.time.toInt() * 1000)
              : null)
          : (stu.hasArrival() && stu.arrival.hasTime()
              ? DateTime.fromMillisecondsSinceEpoch(stu.arrival.time.toInt() * 1000)
              : null);
      if (first != null) return first;

      final second = preferDeparture
          ? (stu.hasArrival() && stu.arrival.hasTime()
              ? DateTime.fromMillisecondsSinceEpoch(stu.arrival.time.toInt() * 1000)
              : null)
          : (stu.hasDeparture() && stu.departure.hasTime()
              ? DateTime.fromMillisecondsSinceEpoch(stu.departure.time.toInt() * 1000)
              : null);
      if (second != null) return second;
    }
  }
  return null;
}

DateTime? getRealtimeStopTime(
  FeedMessage? tripUpdateFeed,
  BusLeg leg,
  String stopId,
) => _findStopTime(tripUpdateFeed, leg, stopId, preferDeparture: true);

DateTime? getRealtimeArrivalTime(
  FeedMessage? tripUpdateFeed,
  BusLeg leg,
  String stopId,
) => _findStopTime(tripUpdateFeed, leg, stopId, preferDeparture: false);

/// Reitin todellinen perilläoloaika: viimeisen bussivaiheen saapuminen
/// (reaaliaikainen jos tiedossa) + loppukävely.
///
/// [RouteOption.arrivalTime] on aikataulun mukainen, joten loppukävelyn
/// kesto saadaan puhtaana erotuksena eikä viive kertaudu kahdesti.
DateTime realArrivalTime(RouteOption option, FeedMessage? tripUpdateFeed) {
  if (option.busLegs.isEmpty) return option.arrivalTime;

  final BusLeg lastLeg = option.busLegs.last;
  final Duration walkAfterBus = option.arrivalTime.difference(
    lastLeg.arrivalTime,
  );

  DateTime lastLegArrival = lastLeg.arrivalTime.add(
    lastLeg.isRealtime
        ? lastLeg.realtimeDeparture.difference(lastLeg.departureTime)
        : Duration.zero,
  );
  if (tripUpdateFeed != null && lastLeg.toStopId.isNotEmpty) {
    final exact = getRealtimeArrivalTime(
      tripUpdateFeed,
      lastLeg,
      lastLeg.toStopId,
    );
    if (exact != null) {
      lastLegArrival = exact;
    }
  }
  return lastLegArrival.add(walkAfterBus);
}

/// Välipysäkin aikataulun näyttöteksti: tarkka aika TripUpdate-feedistä jos
/// saatavilla, muuten lineaarinen arvio matkavaiheen kokonaiskestosta.
String intermediateStopTimeLabel(
  int index,
  BusLeg leg,
  FeedMessage? tripUpdateFeed,
  String Function(DateTime) fmt,
) {
  if (tripUpdateFeed != null && leg.legStopIds.length > index + 1) {
    final String stopId = leg.legStopIds[index + 1];
    final DateTime? exactTime = getRealtimeStopTime(
      tripUpdateFeed,
      leg,
      stopId,
    );

    if (exactTime != null) {
      return fmt(exactTime);
    }
  }

  final Duration delay = leg.isRealtime
      ? leg.realtimeDeparture.difference(leg.departureTime)
      : Duration.zero;

  final Duration total = leg.arrivalTime.difference(leg.departureTime);
  final int count = leg.intermediateStops.length + 1;

  final int secs = ((index + 1) * total.inSeconds / count).round();
  final DateTime scheduledT = leg.departureTime.add(Duration(seconds: secs));
  final DateTime realtimeT = scheduledT.add(delay);

  return fmt(realtimeT);
}

int? getRealtimeCurrentStopIndex(FeedMessage? feed, BusLeg leg) {
  if (feed == null || leg.tripId.isEmpty || leg.legStopIds.isEmpty) {
    return null;
  }

  for (final entity in feed.entity) {
    if (!entity.hasVehicle()) {
      continue;
    }

    final vehicle = entity.vehicle;

    if (!vehicle.hasTrip()) {
      continue;
    }

    final trip = vehicle.trip;
    final tripId = trip.tripId;

    if (tripId.isEmpty) {
      continue;
    }

    if (!tripIdMatches(tripId, leg.tripId)) continue;

    final routeId = trip.routeId;
    final legRoute = leg.routeGtfsId;
    final routeMatches =
        legRoute.isEmpty ||
        routeId == legRoute ||
        routeId.endsWith(':${leg.busNumber}') ||
        routeId == leg.busNumber;

    if (!routeMatches) {
      continue;
    }

    if (!vehicle.hasStopId()) {
      if (vehicle.hasPosition()) {
        final posLat = vehicle.position.latitude.toDouble();
        final posLon = vehicle.position.longitude.toDouble();
        const distCalc = Distance();

        final List<LatLng> coords = [];

        if (leg.fromLat != null && leg.fromLon != null) {
          coords.add(LatLng(leg.fromLat!, leg.fromLon!));
        }

        for (var s in leg.intermediateStops) {
          coords.add(LatLng(s.lat, s.lon));
        }

        if (leg.toLat != null && leg.toLon != null) {
          coords.add(LatLng(leg.toLat!, leg.toLon!));
        }

        if (coords.isNotEmpty) {
          List<double> distances = [];
          double bestDist = double.infinity;
          int closestIdx = -1;

          for (int i = 0; i < coords.length; i++) {
            double d = distCalc.as(
              LengthUnit.Meter,
              coords[i],
              LatLng(posLat, posLon),
            );
            distances.add(d);

            if (d < bestDist) {
              bestDist = d;
              closestIdx = i;
            }
          }

          if (closestIdx >= 0 && bestDist < 1500) {
            int assignedIdx = closestIdx;

            if (bestDist > 75) {
              double distBefore = closestIdx > 0
                  ? distances[closestIdx - 1]
                  : double.infinity;
              double distAfter = closestIdx < distances.length - 1
                  ? distances[closestIdx + 1]
                  : double.infinity;

              if (distAfter < distBefore) {
                assignedIdx = closestIdx + 1;
              } else {
                assignedIdx = closestIdx;
              }
            }
            return assignedIdx;
          }
        }
      }
      return null;
    }

    final stopId = vehicle.stopId;
    int idx = leg.legStopIds.indexOf(stopId);

    if (idx == -1) {
      idx = leg.legStopIds.indexWhere((id) {
        return id.endsWith(':$stopId') || id == stopId;
      });
    }

    if (idx >= 0) {
      return idx;
    }
  }
  return null;
}

/// Montako minuuttia edellinen bussi on myöhässä suhteessa seuraavan
/// lähtöön vaihtopysäkillä. Positiivinen = vaihto voi jäädä välistä.
int transferLatenessMinutes(
  BusLeg prevLeg,
  BusLeg nextLeg,
  FeedMessage? tripUpdateFeed,
) {
  DateTime prevArrival = prevLeg.arrivalTime.add(
    prevLeg.isRealtime
        ? prevLeg.realtimeDeparture.difference(prevLeg.departureTime)
        : Duration.zero,
  );
  if (tripUpdateFeed != null && prevLeg.toStopId.isNotEmpty) {
    final exact = getRealtimeArrivalTime(
      tripUpdateFeed,
      prevLeg,
      prevLeg.toStopId,
    );
    if (exact != null) {
      prevArrival = exact;
    }
  }

  DateTime nextDeparture = nextLeg.realtimeDeparture;
  if (tripUpdateFeed != null && nextLeg.fromStopId.isNotEmpty) {
    final exact = getRealtimeStopTime(
      tripUpdateFeed,
      nextLeg,
      nextLeg.fromStopId,
    );
    if (exact != null) {
      nextDeparture = exact;
    }
  }

  return prevArrival.difference(nextDeparture).inMinutes;
}
