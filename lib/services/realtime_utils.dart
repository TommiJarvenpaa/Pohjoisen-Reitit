import 'package:gtfs_realtime_bindings/gtfs_realtime_bindings.dart';
import 'package:latlong2/latlong.dart';
import '../models/app_models.dart';

/// Apufunktiot reaaliaikatietojen yhdistämiseen reittisuunnittelun
/// BusLeg-tietoihin.
///
/// Pysäkkikohtaiset viiveet tulevat reititys-API:sta
/// (`Map<String, TripRealtime>`, avaimena vuoron gtfsId), jolloin id:t
/// ovat samasta järjestelmästä kuin reittiehdotukset ja vertailu on
/// eksaktia. Raakaa GTFS-RT-feediä (FeedMessage) käytetään enää bussien
/// sijainteihin, joiden trip-id:t vaativat sumeampaa vertailua.

/// Sama trip-gtfsId tarkoittaa vuoroa, ei päivättyä lähtöä: reititys-API:n
/// stoptimes koskee kuluvaa liikennöintipäivää, mutta käyttäjän katsoma
/// vaihe voi olla esim. huomisen sama vuoro. Tuntien kokoluokan poikkeama
/// aikataulusta tarkoittaa eri liikennöintipäivän lähtöä – oikean vuoron
/// viive ei koskaan ole näin suuri.
const Duration _serviceDayGuard = Duration(hours: 3);

DateTime? _plausible(DateTime? time, DateTime near) {
  if (time == null) return null;
  return time.difference(near).abs() <= _serviceDayGuard ? time : null;
}

StopRealtime? _stopRealtime(
  Map<String, TripRealtime>? tripRealtime,
  BusLeg leg,
  String stopId,
) {
  if (tripRealtime == null || leg.tripId.isEmpty || stopId.isEmpty) {
    return null;
  }
  return tripRealtime[leg.tripId]?.byStopId[stopId];
}

/// Pysäkin reaaliaikainen lähtöaika (tai saapuminen, jos lähtöä ei ole).
/// [near] = pysäkin aikataulun mukainen aika, oletuksena vaiheen lähtöaika.
DateTime? getRealtimeStopTime(
  Map<String, TripRealtime>? tripRealtime,
  BusLeg leg,
  String stopId, {
  DateTime? near,
}) {
  final rt = _stopRealtime(tripRealtime, leg, stopId);
  if (rt == null) return null;
  final DateTime reference = near ?? leg.departureTime;
  return _plausible(rt.departure, reference) ??
      _plausible(rt.arrival, reference);
}

/// Pysäkin reaaliaikainen saapumisaika (tai lähtö, jos saapumista ei ole).
/// [near] = pysäkin aikataulun mukainen aika, oletuksena vaiheen saapumisaika.
DateTime? getRealtimeArrivalTime(
  Map<String, TripRealtime>? tripRealtime,
  BusLeg leg,
  String stopId, {
  DateTime? near,
}) {
  final rt = _stopRealtime(tripRealtime, leg, stopId);
  if (rt == null) return null;
  final DateTime reference = near ?? leg.arrivalTime;
  return _plausible(rt.arrival, reference) ??
      _plausible(rt.departure, reference);
}

/// Reitin todellinen perilläoloaika: viimeisen bussivaiheen saapuminen
/// (reaaliaikainen jos tiedossa) + loppukävely.
///
/// [RouteOption.arrivalTime] on aikataulun mukainen, joten loppukävelyn
/// kesto saadaan puhtaana erotuksena eikä viive kertaudu kahdesti.
DateTime realArrivalTime(
  RouteOption option,
  Map<String, TripRealtime>? tripRealtime,
) {
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
  final exact = getRealtimeArrivalTime(
    tripRealtime,
    lastLeg,
    lastLeg.toStopId,
  );
  if (exact != null) {
    lastLegArrival = exact;
  }
  return lastLegArrival.add(walkAfterBus);
}

/// Välipysäkin aikataulun näyttöteksti: tarkka aika reaaliaikatiedoista jos
/// saatavilla, muuten lineaarinen arvio matkavaiheen kokonaiskestosta.
String intermediateStopTimeLabel(
  int index,
  BusLeg leg,
  Map<String, TripRealtime>? tripRealtime,
  String Function(DateTime) fmt,
) {
  final Duration total = leg.arrivalTime.difference(leg.departureTime);
  final int count = leg.intermediateStops.length + 1;
  final int secs = ((index + 1) * total.inSeconds / count).round();
  final DateTime scheduledT = leg.departureTime.add(Duration(seconds: secs));

  if (tripRealtime != null && leg.legStopIds.length > index + 1) {
    final String stopId = leg.legStopIds[index + 1];
    final DateTime? exactTime = getRealtimeStopTime(
      tripRealtime,
      leg,
      stopId,
      near: scheduledT,
    );

    if (exactTime != null) {
      return fmt(exactTime);
    }
  }

  final Duration delay = leg.isRealtime
      ? leg.realtimeDeparture.difference(leg.departureTime)
      : Duration.zero;

  return fmt(scheduledT.add(delay));
}

/// Montako minuuttia edellinen bussi on myöhässä suhteessa seuraavan
/// lähtöön vaihtopysäkillä. Positiivinen = vaihto voi jäädä välistä.
int transferLatenessMinutes(
  BusLeg prevLeg,
  BusLeg nextLeg,
  Map<String, TripRealtime>? tripRealtime,
) {
  DateTime prevArrival = prevLeg.arrivalTime.add(
    prevLeg.isRealtime
        ? prevLeg.realtimeDeparture.difference(prevLeg.departureTime)
        : Duration.zero,
  );
  final exactArrival = getRealtimeArrivalTime(
    tripRealtime,
    prevLeg,
    prevLeg.toStopId,
  );
  if (exactArrival != null) {
    prevArrival = exactArrival;
  }

  DateTime nextDeparture = nextLeg.realtimeDeparture;
  final exactDeparture = getRealtimeStopTime(
    tripRealtime,
    nextLeg,
    nextLeg.fromStopId,
  );
  if (exactDeparture != null) {
    nextDeparture = exactDeparture;
  }

  return prevArrival.difference(nextDeparture).inMinutes;
}

/// Poistaa namespace-etuliitteen ("waltti:", "HSL:" jne.) ja
/// alaviivasuffiksin trip ID:stä vertailua varten. Tarvitaan vain
/// sijaintifeedin (VehiclePosition) ja OTP:n id-muotojen siltaamiseen –
/// sumea vertailu ei kelpaa aikatauluihin, koska se ei erota saman
/// linjan eri lähtöjä.
String _tripCore(String tripId) {
  String id = tripId.contains(':') ? tripId.split(':').last : tripId;
  if (id.contains('_')) id = id.split('_').first;
  return id;
}

bool tripIdMatches(String feedTripId, String legTripId) {
  if (feedTripId == legTripId) return true;
  return _tripCore(feedTripId) == _tripCore(legTripId);
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
