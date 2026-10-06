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

/// Sama trip-gtfsId tarkoittaa vuoroa, ei päivättyä lähtöä. Viiveet haetaan
/// vaiheen liikennöintipäivälle, mutta päivä voi puuttua (vanha välimuisti,
/// jolloin OTP käyttää kuluvaa päivää). Tuntien kokoluokan poikkeama
/// aikataulusta tarkoittaa eri liikennöintipäivän lähtöä – oikean vuoron
/// viive ei koskaan ole näin suuri.
const Duration _serviceDayGuard = Duration(hours: 3);

DateTime? _plausible(DateTime? time, DateTime near) {
  if (time == null) return null;
  return time.difference(near).abs() <= _serviceDayGuard ? time : null;
}

/// Pysäkin reaaliaikatieto vaiheen vuorolla. Jos vuoro käy pysäkillä
/// useasti (rengasreitti), valitaan käynti, jonka aikataulu on lähimpänä
/// [near]:ia – muuten paluukäynnin aika näkyisi lähdön "viiveenä".
StopRealtime? _stopRealtime(
  Map<String, TripRealtime>? tripRealtime,
  BusLeg leg,
  String stopId,
  DateTime near,
) {
  if (tripRealtime == null || leg.tripId.isEmpty || stopId.isEmpty) {
    return null;
  }
  return tripRealtime[leg.tripId]?.visitNear(stopId, near);
}

bool _isCanceled(StopRealtime? rt) => rt?.realtimeState == 'CANCELED';

/// Pysäkin reaaliaikainen lähtöaika (tai saapuminen, jos lähtöä ei ole).
/// [near] = pysäkin aikataulun mukainen aika, oletuksena vaiheen lähtöaika.
///
/// Perutulle pysäkille palautuu null: OTP antaa perutun pysäkin ajaksi
/// aikataulun ajan, joka näyttäisi muuten "ajallaan"-tiedolta.
DateTime? getRealtimeStopTime(
  Map<String, TripRealtime>? tripRealtime,
  BusLeg leg,
  String stopId, {
  DateTime? near,
}) {
  final DateTime reference = near ?? leg.departureTime;
  final rt = _stopRealtime(tripRealtime, leg, stopId, reference);
  if (rt == null || _isCanceled(rt)) return null;
  return _plausible(rt.departure, reference) ??
      _plausible(rt.arrival, reference);
}

/// Pysäkin reaaliaikainen saapumisaika (tai lähtö, jos saapumista ei ole).
/// [near] = pysäkin aikataulun mukainen aika, oletuksena vaiheen saapumisaika.
/// Perutulle pysäkille null, ks. [getRealtimeStopTime].
DateTime? getRealtimeArrivalTime(
  Map<String, TripRealtime>? tripRealtime,
  BusLeg leg,
  String stopId, {
  DateTime? near,
}) {
  final DateTime reference = near ?? leg.arrivalTime;
  final rt = _stopRealtime(tripRealtime, leg, stopId, reference);
  if (rt == null || _isCanceled(rt)) return null;
  return _plausible(rt.arrival, reference) ??
      _plausible(rt.departure, reference);
}

/// Ohittaako vuoro pysäkin live-tiedon mukaan (peruttu vuoro tai pysäkki,
/// esim. poikkeusreitti). [near] = pysäkin aikataulun mukainen aika.
bool isStopCanceled(
  Map<String, TripRealtime>? tripRealtime,
  BusLeg leg,
  String stopId, {
  DateTime? near,
}) => _isCanceled(
  _stopRealtime(tripRealtime, leg, stopId, near ?? leg.departureTime),
);

/// Vaiheen peruutustila käyttäjän kannalta.
enum LegCancellation {
  none,

  /// Vuoro on peruttu (tai bussi ei pysähdy nousu- eikä poistumispysäkillä).
  canceled,

  /// Bussi ei pysähdy nousupysäkillä.
  boardingSkipped,

  /// Bussi ei pysähdy poistumispysäkillä.
  alightingSkipped,
}

/// Vaiheen peruutustila hakuhetken tilasta ja live-seurannan
/// pysäkkikohtaisista tiloista. Sama päättely kortissa ja jakotekstissä.
LegCancellation legCancellation(
  BusLeg leg,
  Map<String, TripRealtime>? tripRealtime,
) {
  if (leg.realtimeState == 'CANCELED') return LegCancellation.canceled;
  final bool boarding = isStopCanceled(tripRealtime, leg, leg.fromStopId);
  final bool alighting = isStopCanceled(
    tripRealtime,
    leg,
    leg.toStopId,
    near: leg.arrivalTime,
  );
  if (boarding && alighting) return LegCancellation.canceled;
  if (boarding) return LegCancellation.boardingSkipped;
  if (alighting) return LegCancellation.alightingSkipped;
  return LegCancellation.none;
}

/// Vaiheen reaaliaikainen lähtöaika: live-seurannan tarkka aika, muuten
/// hakuhetken tilannekuva. Null = reaaliaikatietoa ei ole.
DateTime? realtimeLegDeparture(
  BusLeg leg,
  Map<String, TripRealtime>? tripRealtime,
) {
  final exact = getRealtimeStopTime(tripRealtime, leg, leg.fromStopId);
  if (exact != null) return exact;
  return leg.isRealtime ? leg.realtimeDeparture : null;
}

/// Vaiheen saapumisaika näyttöön, tarkimmasta lähteestä alkaen:
/// live-seurannan saapuminen, live-lähdön viiveellä siirretty aikataulu,
/// hakuhetken ennuste (OTP:n saapumisviive voi poiketa lähdön viiveestä) ja
/// lopuksi aikataulu.
DateTime displayedLegArrival(
  BusLeg leg,
  Map<String, TripRealtime>? tripRealtime,
) {
  final exact = getRealtimeArrivalTime(tripRealtime, leg, leg.toStopId);
  if (exact != null) return exact;

  final exactDep = getRealtimeStopTime(tripRealtime, leg, leg.fromStopId);
  if (exactDep != null) {
    return leg.arrivalTime.add(exactDep.difference(leg.departureTime));
  }
  if (!leg.isRealtime) return leg.arrivalTime;
  return leg.realtimeArrival ??
      leg.arrivalTime.add(leg.realtimeDeparture.difference(leg.departureTime));
}

/// Milloin kotoa pitää lähteä: aikataulun mukainen lähtöaika siirrettynä
/// ensimmäisen bussin viiveellä, kuten OTP:n omissa reittiehdotuksissa.
/// Etuajassa kulkeva bussi aikaistaa lähtöä, myöhässä oleva myöhentää.
DateTime displayedLeaveTime(
  RouteOption option,
  Map<String, TripRealtime>? tripRealtime,
) {
  if (option.busLegs.isEmpty) return option.leaveHomeTime;
  final BusLeg first = option.busLegs.first;
  final DateTime? realtimeDep = realtimeLegDeparture(first, tripRealtime);
  if (realtimeDep == null) return option.leaveHomeTime;
  return option.leaveHomeTime.add(realtimeDep.difference(first.departureTime));
}

/// Vaiheen aikana voimassa olevat tiedotteet, sama teksti kerran.
/// Voimassaolo tarkistetaan vasta näytettäessä, jotta aikataulusta
/// kopioitu lähtö saa omaan aikaansa osuvat tiedotteet.
List<AlertInfo> activeLegAlerts(
  BusLeg leg,
  Map<String, TripRealtime>? tripRealtime,
) {
  final DateTime start =
      realtimeLegDeparture(leg, tripRealtime) ?? leg.departureTime;
  final DateTime end = displayedLegArrival(leg, tripRealtime);
  final DateTime from = start.isBefore(leg.departureTime)
      ? start
      : leg.departureTime;
  final DateTime to = end.isAfter(leg.arrivalTime) ? end : leg.arrivalTime;

  final Set<String> seenTexts = {};
  return [
    for (final alert in leg.alerts)
      if (alert.isActiveBetween(from, to) && seenTexts.add(alert.text)) alert,
  ];
}

/// Kellonaikojen ero minuutteina sellaisina kuin ne näytetään (HH:mm ilman
/// sekunteja). Näin "+N min" ja kesto täsmäävät näkyviin aikoihin:
/// 07:46:40 → 07:54:10 näkyy 07:46 → 07:54 eli +8 min, ei +7.
int clockMinutesBetween(DateTime from, DateTime to) {
  DateTime floorToMinute(DateTime t) => t.subtract(
    Duration(
      seconds: t.second,
      milliseconds: t.millisecond,
      microseconds: t.microsecond,
    ),
  );
  return floorToMinute(to).difference(floorToMinute(from)).inMinutes;
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
  return displayedLegArrival(lastLeg, tripRealtime).add(walkAfterBus);
}

/// Mistä välipysäkin näytetty aika on peräisin.
enum StopTimeKind {
  /// Live-seurannan pysäkkikohtainen ennuste.
  live,

  /// Pysäkin oma aikataulu sellaisenaan (reaaliaikatietoa ei ole).
  schedule,

  /// Arvio: aikataulu viiveellä siirrettynä, hakuhetken ennuste tai vanhan
  /// välimuistin lineaarinen arvio (näytetään "~"-merkillä).
  estimate,
}

/// Pysäkin aika näyttöön ja sen lähde.
class StopTimeEstimate {
  final DateTime time;
  final StopTimeKind kind;

  const StopTimeEstimate(this.time, this.kind);

  bool get isLive => kind == StopTimeKind.live;
}

/// Välipysäkin gtfsId. intermediateStops sisältää myös pysäkit ilman id:tä,
/// legStopIds ei, joten id luetaan ensisijaisesti pysäkiltä itseltään.
String? _intermediateStopId(BusLeg leg, int index) {
  final String? own = leg.intermediateStops[index].gtfsId;
  if (own != null && own.isNotEmpty) return own;
  // Vanha välimuisti: id:t vain legStopIds-listassa (alku, välit, loppu).
  if (leg.legStopIds.length == leg.intermediateStops.length + 2) {
    return leg.legStopIds[index + 1];
  }
  return null;
}

/// Välipysäkin aika tarkimmasta saatavilla olevasta lähteestä:
/// 1. live-seurannan pysäkkikohtainen ennuste,
/// 2. pysäkin aikataulu siirrettynä live-seurannan lähtöviiveellä,
/// 3. hakuhetken pysäkkikohtainen ennuste,
/// 4. pysäkin aikataulu siirrettynä hakuhetken lähtöviiveellä,
/// 5. pysäkin aikataulu sellaisenaan.
/// Jos pysäkin aikataulu puuttuu (vanha välimuisti), sen tilalla käytetään
/// lineaarista arviota vaiheen kestosta.
StopTimeEstimate intermediateStopTime(
  int index,
  BusLeg leg,
  Map<String, TripRealtime>? tripRealtime,
) {
  final IntermediateStop stop = leg.intermediateStops[index];
  final DateTime? scheduled = stop.scheduledTime;
  final DateTime planned = scheduled ?? _linearStopTime(index, leg);

  final String? stopId = _intermediateStopId(leg, index);
  if (tripRealtime != null && stopId != null) {
    final DateTime? exactTime = getRealtimeStopTime(
      tripRealtime,
      leg,
      stopId,
      near: planned,
    );
    if (exactTime != null) {
      return StopTimeEstimate(exactTime, StopTimeKind.live);
    }
  }

  // Sama viivelähde kuin vaiheen lähtörivillä, jotta arviot eivät poikkea
  // otsikossa näkyvästä viiveestä: live-lähtö ennen hakuhetken ennustetta.
  final DateTime? liveDep = getRealtimeStopTime(
    tripRealtime,
    leg,
    leg.fromStopId,
  );
  if (liveDep != null) {
    return StopTimeEstimate(
      planned.add(liveDep.difference(leg.departureTime)),
      StopTimeKind.estimate,
    );
  }
  if (leg.isRealtime) {
    final DateTime? estimated = stop.estimatedTime;
    return StopTimeEstimate(
      estimated ??
          planned.add(leg.realtimeDeparture.difference(leg.departureTime)),
      StopTimeKind.estimate,
    );
  }
  return scheduled != null
      ? StopTimeEstimate(scheduled, StopTimeKind.schedule)
      : StopTimeEstimate(planned, StopTimeKind.estimate);
}

/// Vaiheen saapumisaika ([displayedLegArrival]) ja sen lähde samalla
/// jaottelulla kuin välipysäkeillä: live, pelkkä aikataulu tai arvio.
StopTimeEstimate displayedLegArrivalEstimate(
  BusLeg leg,
  Map<String, TripRealtime>? tripRealtime,
) {
  final DateTime time = displayedLegArrival(leg, tripRealtime);
  if (getRealtimeArrivalTime(tripRealtime, leg, leg.toStopId) != null) {
    return StopTimeEstimate(time, StopTimeKind.live);
  }
  final bool isScheduleOnly =
      getRealtimeStopTime(tripRealtime, leg, leg.fromStopId) == null &&
      !leg.isRealtime;
  return StopTimeEstimate(
    time,
    isScheduleOnly ? StopTimeKind.schedule : StopTimeKind.estimate,
  );
}

/// Vanhan välimuistin varalla: tasavälinen arvio vaiheen kestosta.
DateTime _linearStopTime(int index, BusLeg leg) {
  final Duration total = leg.arrivalTime.difference(leg.departureTime);
  final int count = leg.intermediateStops.length + 1;
  final int secs = ((index + 1) * total.inSeconds / count).round();
  return leg.departureTime.add(Duration(seconds: secs));
}

/// Onko kellonaika jo mennyt minuuttitarkkuudella (sama minuutti = ei vielä).
bool _isPast(DateTime time, DateTime now) => clockMinutesBetween(time, now) > 0;

/// Vaiheen eteneminen nykyhetkellä näytettyjen (live- tai arvio)aikojen
/// perusteella.
class LegProgress {
  /// Bussi on lähtenyt nousupysäkiltä.
  final bool hasDeparted;

  /// Montako välipysäkkiä on ohitettu (alusta lukien yhtenäisesti).
  final int passedStops;

  /// Bussi on ohittanut poistumispysäkin.
  final bool hasArrived;

  /// Perustuuko seuraavan pysäkin aika live-ennusteeseen.
  final bool isLive;

  const LegProgress({
    required this.hasDeparted,
    required this.passedStops,
    required this.hasArrived,
    required this.isLive,
  });
}

LegProgress legProgress(
  BusLeg leg,
  Map<String, TripRealtime>? tripRealtime,
  DateTime now,
) {
  final DateTime departure =
      realtimeLegDeparture(leg, tripRealtime) ?? leg.departureTime;
  if (!_isPast(departure, now)) {
    return LegProgress(
      hasDeparted: false,
      passedStops: 0,
      hasArrived: false,
      isLive: legDepartureSource(leg, tripRealtime) == RealtimeSource.live,
    );
  }

  int passed = 0;
  bool nextIsLive = false;
  for (int i = 0; i < leg.intermediateStops.length; i++) {
    final StopTimeEstimate estimate = intermediateStopTime(
      i,
      leg,
      tripRealtime,
    );
    if (!_isPast(estimate.time, now)) {
      nextIsLive = estimate.isLive;
      break;
    }
    passed++;
  }

  final bool allPassed = passed == leg.intermediateStops.length;
  final bool hasArrived =
      allPassed && _isPast(displayedLegArrival(leg, tripRealtime), now);
  if (allPassed) {
    nextIsLive =
        getRealtimeArrivalTime(tripRealtime, leg, leg.toStopId) != null;
  }
  return LegProgress(
    hasDeparted: true,
    passedStops: passed,
    hasArrived: hasArrived,
    isLive: nextIsLive,
  );
}

/// Mistä vaiheen lähtöaika on peräisin.
enum RealtimeSource {
  /// Live-seurannan tuore pysäkkikohtainen ennuste.
  live,

  /// Hakuhetken ennuste (reittiehdotuksen tilannekuva).
  snapshot,

  /// Pelkkä aikataulu.
  schedule,
}

RealtimeSource legDepartureSource(
  BusLeg leg,
  Map<String, TripRealtime>? tripRealtime,
) {
  if (getRealtimeStopTime(tripRealtime, leg, leg.fromStopId) != null) {
    return RealtimeSource.live;
  }
  return leg.isRealtime ? RealtimeSource.snapshot : RealtimeSource.schedule;
}

/// Reittikortin tilamerkinnän vaihe.
enum TripPhase {
  /// Lähtöön yli 5 min.
  leaveLater,

  /// Lähtöön 1–5 min.
  leaveSoon,

  /// Lähtöaika on nyt tai mennyt, mutta bussi ei ole vielä lähtenyt.
  leaveNow,

  /// Ensimmäinen bussi on lähtenyt (tai kävelyreitin lähtöaika mennyt).
  departed,
}

class TripStatus {
  final TripPhase phase;

  /// Minuutteja lähtöön (vaiheissa leaveLater/leaveSoon).
  final int minutesToLeave;

  /// Ensimmäisen bussin näytetty lähtöaika (null kävelyreitillä).
  final DateTime? busDeparture;

  const TripStatus(this.phase, {this.minutesToLeave = 0, this.busDeparture});
}

/// Reitin tila nykyhetkellä: kauanko lähtöön, pitääkö lähteä nyt vai onko
/// bussi jo lähtenyt. Minuutit lasketaan näytetyistä kellonajoista.
TripStatus tripStatus(
  RouteOption option,
  Map<String, TripRealtime>? tripRealtime,
  DateTime now,
) {
  final DateTime leave = displayedLeaveTime(option, tripRealtime);
  final int minutesToLeave = clockMinutesBetween(now, leave);

  DateTime? busDeparture;
  if (option.busLegs.isNotEmpty) {
    final BusLeg first = option.busLegs.first;
    busDeparture =
        realtimeLegDeparture(first, tripRealtime) ?? first.departureTime;
    if (_isPast(busDeparture, now)) {
      return TripStatus(TripPhase.departed, busDeparture: busDeparture);
    }
  } else if (minutesToLeave < 0) {
    return const TripStatus(TripPhase.departed);
  }

  if (minutesToLeave > 5) {
    return TripStatus(
      TripPhase.leaveLater,
      minutesToLeave: minutesToLeave,
      busDeparture: busDeparture,
    );
  }
  if (minutesToLeave > 0) {
    return TripStatus(
      TripPhase.leaveSoon,
      minutesToLeave: minutesToLeave,
      busDeparture: busDeparture,
    );
  }
  return TripStatus(TripPhase.leaveNow, busDeparture: busDeparture);
}

/// Saman linjan seuraava lähtö samalta pysäkiltä muiden reittiehdotusten
/// joukosta – näytetään perutun vuoron kohdalla. Jo lähteneitä ei tarjota.
/// Null, jos sellaista ei ole.
DateTime? nextSameLineDeparture(
  List<RouteOption> options,
  int index,
  Map<String, TripRealtime>? tripRealtime,
  DateTime now,
) {
  if (index < 0 || index >= options.length) return null;
  if (options[index].busLegs.isEmpty) return null;
  final BusLeg leg = options[index].busLegs.first;
  final DateTime own =
      realtimeLegDeparture(leg, tripRealtime) ?? leg.departureTime;

  DateTime? best;
  for (int i = 0; i < options.length; i++) {
    if (i == index || options[i].busLegs.isEmpty) continue;
    final BusLeg other = options[i].busLegs.first;
    if (other.busNumber != leg.busNumber ||
        other.fromStopId != leg.fromStopId) {
      continue;
    }
    if (legCancellation(other, tripRealtime) != LegCancellation.none) continue;
    final DateTime dep =
        realtimeLegDeparture(other, tripRealtime) ?? other.departureTime;
    if (!dep.isAfter(own) || _isPast(dep, now)) continue;
    if (best == null || dep.isBefore(best)) best = dep;
  }
  return best;
}

/// Montako minuuttia edellinen bussi on myöhässä suhteessa seuraavan
/// lähtöön vaihtopysäkillä, kun pysäkkien välinen kävely [transferWalk]
/// on otettu huomioon. Positiivinen = vaihto voi jäädä välistä (pienikin
/// myöhästyminen pyöristyy ylöspäin 1 minuutiksi), nolla tai negatiivinen =
/// vaihtoon jäävä aika kokonaisina minuutteina miinusmerkkisenä.
int transferLatenessMinutes(
  BusLeg prevLeg,
  BusLeg nextLeg,
  Map<String, TripRealtime>? tripRealtime, {
  Duration transferWalk = Duration.zero,
}) {
  final DateTime prevArrival = displayedLegArrival(prevLeg, tripRealtime);
  final DateTime nextDeparture =
      realtimeLegDeparture(nextLeg, tripRealtime) ?? nextLeg.departureTime;

  final int slackSec =
      nextDeparture.difference(prevArrival).inSeconds - transferWalk.inSeconds;
  if (slackSec < 0) return (-slackSec / 60).ceil();
  return -(slackSec ~/ 60);
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
