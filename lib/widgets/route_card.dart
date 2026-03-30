import 'package:flutter/material.dart';
import 'package:gtfs_realtime_bindings/gtfs_realtime_bindings.dart';
import 'package:latlong2/latlong.dart';
import '../models/app_models.dart';
import '../theme/app_colors.dart';
import '../widgets/trip_route_sheet.dart';

/// Poistaa namespace-etuliitteen ("waltti:", "HSL:" jne.) ja
/// päivämääräsuffiksin ("_20240330") trip ID:stä vertailua varten.
/// Estää osittaiset osumat, esim. "100123456" ei osu "1001234567":ään.
String _tripCore(String tripId) {
  String id = tripId.contains(':') ? tripId.split(':').last : tripId;
  if (id.contains('_')) id = id.split('_').first;
  return id;
}

bool _tripIdMatches(String feedTripId, String legTripId) {
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

    if (!_tripIdMatches(tripId, leg.tripId)) continue;

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

String _getStopTime(
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

  if (count <= 0) {
    return fmt(leg.realtimeDeparture);
  }

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

    if (!_tripIdMatches(tripId, leg.tripId)) continue;

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

int _transferLatenessMinutes(
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

// --- PÄÄKORTTI ---
class RouteCard extends StatefulWidget {
  final RouteOption option;
  final bool isSelected;
  final bool isFavorite;
  final bool isOfflineData;
  final String Function(DateTime) formatTime;
  final VoidCallback onTap;
  final VoidCallback onToggleFavorite;
  final VoidCallback onShare;
  final FeedMessage? liveFeed;
  final FeedMessage? tripUpdateFeed;

  const RouteCard({
    super.key,
    required this.option,
    required this.isSelected,
    required this.isFavorite,
    required this.isOfflineData,
    required this.formatTime,
    required this.onTap,
    required this.onToggleFavorite,
    required this.onShare,
    this.liveFeed,
    this.tripUpdateFeed,
  });

  @override
  State<RouteCard> createState() => _RouteCardState();
}

class _RouteCardState extends State<RouteCard> {
  bool _isExpanded = false;

  Widget _buildGraphicalTimeline() {
    List<Widget> items = [];

    if (widget.option.busLegs.isEmpty) {
      items.add(const Icon(Icons.directions_walk, size: 18, color: kWalk));
      items.add(const SizedBox(width: 6));
      items.add(
        const Icon(Icons.arrow_right_alt_rounded, size: 20, color: Colors.grey),
      );
      items.add(const SizedBox(width: 6));
      items.add(const Icon(Icons.flag_rounded, size: 18, color: kPrimary));
      return Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        runSpacing: 8,
        children: items,
      );
    }

    for (int i = 0; i < widget.option.busLegs.length; i++) {
      if (widget.option.walkDistances[i] > 0) {
        items.add(const Icon(Icons.directions_walk, size: 16, color: kWalk));
        items.add(const SizedBox(width: 4));
        items.add(
          const Icon(
            Icons.arrow_right_alt_rounded,
            size: 18,
            color: Colors.grey,
          ),
        );
        items.add(const SizedBox(width: 4));
      }

      items.add(
        BusNumberBadge(
          leg: widget.option.busLegs[i],
          formatTime: widget.formatTime,
        ),
      );

      if (i < widget.option.busLegs.length - 1 ||
          (i + 1 < widget.option.walkDistances.length &&
              widget.option.walkDistances[i + 1] > 0)) {
        items.add(const SizedBox(width: 4));
        items.add(
          const Icon(
            Icons.arrow_right_alt_rounded,
            size: 18,
            color: Colors.grey,
          ),
        );
        items.add(const SizedBox(width: 4));
      }
    }

    if (widget.option.walkDistances.last > 0) {
      items.add(const Icon(Icons.directions_walk, size: 16, color: kWalk));
      items.add(const SizedBox(width: 4));
      items.add(
        const Icon(Icons.arrow_right_alt_rounded, size: 18, color: Colors.grey),
      );
      items.add(const SizedBox(width: 4));
    }
    items.add(const Icon(Icons.flag_rounded, size: 18, color: kPrimary));

    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      runSpacing: 8,
      children: items,
    );
  }

  @override
  Widget build(BuildContext context) {
    final allAlerts = widget.option.busLegs
        .expand((leg) => leg.alerts)
        .toList();

    DateTime realArrivalTime = widget.option.arrivalTime;
    if (widget.option.busLegs.isNotEmpty) {
      final lastLeg = widget.option.busLegs.last;
      final Duration walkAfterBus = widget.option.arrivalTime.difference(
        lastLeg.arrivalTime,
      );

      DateTime lastLegRealArrival = lastLeg.arrivalTime.add(
        lastLeg.isRealtime
            ? lastLeg.realtimeDeparture.difference(lastLeg.departureTime)
            : Duration.zero,
      );

      if (widget.tripUpdateFeed != null && lastLeg.toStopId.isNotEmpty) {
        final exactTime = getRealtimeArrivalTime(
          widget.tripUpdateFeed,
          lastLeg,
          lastLeg.toStopId,
        );
        if (exactTime != null) {
          lastLegRealArrival = exactTime;
        }
      }
      realArrivalTime = lastLegRealArrival.add(walkAfterBus);
    }

    final totalMinutes = realArrivalTime
        .difference(widget.option.leaveHomeTime)
        .inMinutes;

    List<Widget> timelineWidgets = [];
    timelineWidgets.add(
      TimelineRow(
        icon: Icons.directions_walk,
        iconColor: kWalk,
        label: 'Lähde klo ${widget.formatTime(widget.option.leaveHomeTime)}',
        labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
      ),
    );

    if (widget.option.walkDistances.isNotEmpty &&
        widget.option.walkDistances[0] > 0) {
      timelineWidgets.add(const TimelineDivider());
      timelineWidgets.add(
        Padding(
          padding: const EdgeInsets.only(left: 28, bottom: 4),
          child: Text(
            'Kävele ${widget.option.walkDistances[0].round()} m',
            style: TextStyle(color: Colors.grey[600], fontSize: 12),
          ),
        ),
      );
    }

    for (int i = 0; i < widget.option.busLegs.length; i++) {
      timelineWidgets.add(const TimelineDivider());
      final leg = widget.option.busLegs[i];
      timelineWidgets.add(
        BusLegSection(
          leg: leg,
          formatTime: widget.formatTime,
          tripUpdateFeed: widget.tripUpdateFeed,
        ),
      );

      if (i + 1 < widget.option.busLegs.length &&
          widget.option.busLegs[i + 1].stayOnBus) {
        timelineWidgets.add(const TimelineDivider());
        timelineWidgets.add(
          const Padding(
            padding: EdgeInsets.only(left: 28, bottom: 4),
            child: Row(
              children: [
                Icon(
                  Icons.airline_seat_recline_normal,
                  size: 14,
                  color: Colors.orange,
                ),
                SizedBox(width: 6),
                Text(
                  'Pysy bussissa, linja vaihtuu',
                  style: TextStyle(
                    color: Colors.orange,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        );
      } else if (i + 1 < widget.option.busLegs.length) {
        final nextLeg = widget.option.busLegs[i + 1];
        final int lateness = _transferLatenessMinutes(
          leg,
          nextLeg,
          widget.tripUpdateFeed,
        );

        if (lateness > 0) {
          timelineWidgets.add(const TimelineDivider());
          timelineWidgets.add(
            Padding(
              padding: const EdgeInsets.only(left: 28, bottom: 4),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: kDelayed.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: kDelayed.withValues(alpha: 0.35)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.warning_amber_rounded,
                      size: 14,
                      color: kDelayed,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        'Vaihto linja ${nextLeg.busNumber} voi jäädä – $lateness min myöhässä',
                        style: const TextStyle(
                          color: kDelayed,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        } else if (lateness > -3) {
          timelineWidgets.add(const TimelineDivider());
          timelineWidgets.add(
            Padding(
              padding: const EdgeInsets.only(left: 28, bottom: 4),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: Colors.orange.withValues(alpha: 0.35),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.schedule, size: 14, color: Colors.orange),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        'Vaihto linja ${nextLeg.busNumber} tiukka – alle 3 min',
                        style: const TextStyle(
                          color: Colors.orange,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        if (i + 1 < widget.option.walkDistances.length) {
          double nextWalk = widget.option.walkDistances[i + 1];
          if (nextWalk > 0) {
            timelineWidgets.add(const TimelineDivider());
            timelineWidgets.add(
              Padding(
                padding: const EdgeInsets.only(left: 28, bottom: 4),
                child: Text(
                  'Kävele ${nextWalk.round()} m',
                  style: TextStyle(color: Colors.grey[600], fontSize: 12),
                ),
              ),
            );
          }
        }
      }

      // Kävely viimeisen bussivaiheen jälkeen
      if (i + 1 == widget.option.busLegs.length &&
          i + 1 < widget.option.walkDistances.length) {
        final lastWalk = widget.option.walkDistances[i + 1];
        if (lastWalk > 0) {
          timelineWidgets.add(const TimelineDivider());
          timelineWidgets.add(
            Padding(
              padding: const EdgeInsets.only(left: 28, bottom: 4),
              child: Text(
                'Kävele ${lastWalk.round()} m',
                style: TextStyle(color: Colors.grey[600], fontSize: 12),
              ),
            ),
          );
        }
      }
    }

    return GestureDetector(
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          gradient: widget.isSelected
              ? const LinearGradient(
                  colors: [Color(0xFFEEF2FF), Colors.white],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                )
              : null,
          color: widget.isSelected ? null : Colors.white,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: widget.isSelected
                ? kBus.withValues(alpha: 0.35)
                : Colors.grey.withValues(alpha: 0.15),
            width: widget.isSelected ? 2 : 1,
          ),
          boxShadow: [
            BoxShadow(
              color: widget.isSelected
                  ? kBus.withValues(alpha: 0.1)
                  : Colors.black.withValues(alpha: 0.05),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.isOfflineData)
                Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: Colors.orange.withValues(alpha: 0.4),
                    ),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.wifi_off, size: 14, color: Colors.orange),
                      SizedBox(width: 6),
                      Text(
                        'Tallennettu reitti – ei reaaliaikainen',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.orange,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),

              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    widget.formatTime(widget.option.leaveHomeTime),
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF222222),
                      letterSpacing: -0.5,
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.only(bottom: 6, left: 8, right: 8),
                    child: Icon(
                      Icons.arrow_forward_rounded,
                      color: Colors.grey,
                      size: 20,
                    ),
                  ),
                  Text(
                    widget.formatTime(realArrivalTime),
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF222222),
                      letterSpacing: -0.5,
                    ),
                  ),
                  const Spacer(),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: widget.isSelected
                              ? kBus.withValues(alpha: 0.15)
                              : kSurface,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '$totalMinutes min',
                          style: TextStyle(
                            color: widget.isSelected ? kBus : Colors.grey[700],
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 16),

              _buildGraphicalTimeline(),

              const SizedBox(height: 4),

              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton.icon(
                    onPressed: () {
                      setState(() {
                        _isExpanded = !_isExpanded;
                      });
                    },
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    icon: Icon(
                      _isExpanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      color: kPrimary,
                      size: 20,
                    ),
                    label: Text(
                      _isExpanded ? 'Piilota tiedot' : 'Näytä tiedot',
                      style: const TextStyle(
                        color: kPrimary,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      IconButton(
                        onPressed: widget.onShare,
                        icon: Icon(
                          Icons.share_outlined,
                          size: 20,
                          color: Colors.grey[500],
                        ),
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 36,
                          minHeight: 36,
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        onPressed: widget.onToggleFavorite,
                        icon: Icon(
                          widget.isFavorite
                              ? Icons.star_rounded
                              : Icons.star_border_rounded,
                          size: 24,
                          color: widget.isFavorite ? kAccent : Colors.grey[400],
                        ),
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 36,
                          minHeight: 36,
                        ),
                      ),
                    ],
                  ),
                ],
              ),

              AnimatedSize(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
                child: _isExpanded
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 12),
                          const Divider(height: 1, color: Color(0xFFEEEEEE)),
                          const SizedBox(height: 16),
                          ...timelineWidgets,
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              const Icon(
                                Icons.flag_rounded,
                                color: kPrimary,
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Perillä klo ${widget.formatTime(realArrivalTime)}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 14,
                                  color: kPrimaryDark,
                                ),
                              ),
                            ],
                          ),
                          if (allAlerts.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 16),
                              child: Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: kAlert.withValues(alpha: 0.08),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: kAlert.withValues(alpha: 0.3),
                                  ),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        const Icon(
                                          Icons.warning_amber_rounded,
                                          color: kAlert,
                                          size: 18,
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          'Häiriötiedote${allAlerts.length > 1 ? 't' : ''}',
                                          style: const TextStyle(
                                            color: kAlert,
                                            fontWeight: FontWeight.w800,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ],
                                    ),
                                    for (final alert in allAlerts)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 6),
                                        child: Text(
                                          alert.text,
                                          style: TextStyle(
                                            color: Colors.grey[800],
                                            fontSize: 12,
                                            height: 1.4,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class TimelineRow extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final TextStyle? labelStyle;
  const TimelineRow({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.label,
    this.labelStyle,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: iconColor, size: 16),
        const SizedBox(width: 8),
        Text(label, style: labelStyle ?? const TextStyle(fontSize: 13)),
      ],
    );
  }
}

class TimelineDivider extends StatelessWidget {
  const TimelineDivider({super.key});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 7, top: 4, bottom: 4),
      child: Container(width: 2, height: 14, color: const Color(0xFFDDDDDD)),
    );
  }
}

class BusLegSection extends StatefulWidget {
  final BusLeg leg;
  final String Function(DateTime) formatTime;
  final FeedMessage? tripUpdateFeed;

  const BusLegSection({
    super.key,
    required this.leg,
    required this.formatTime,
    this.tripUpdateFeed,
  });

  @override
  State<BusLegSection> createState() => _BusLegSectionState();
}

class _BusLegSectionState extends State<BusLegSection> {
  bool _showStops = false;

  @override
  Widget build(BuildContext context) {
    final BusLeg leg = widget.leg;
    final bool isCanceled = leg.realtimeState == 'CANCELED';
    final bool hasIntermediateStops = leg.intermediateStops.isNotEmpty;

    DateTime realtimeDep = leg.realtimeDeparture;
    if (widget.tripUpdateFeed != null && leg.fromStopId.isNotEmpty) {
      final exactDep = getRealtimeStopTime(
        widget.tripUpdateFeed,
        leg,
        leg.fromStopId,
      );
      if (exactDep != null) {
        realtimeDep = exactDep;
      }
    }

    final bool hasDelay =
        leg.isRealtime &&
        realtimeDep.difference(leg.departureTime).inMinutes != 0;
    final int delayMin = realtimeDep.difference(leg.departureTime).inMinutes;

    DateTime finalBusArrivalTime = leg.arrivalTime.add(
      leg.isRealtime
          ? leg.realtimeDeparture.difference(leg.departureTime)
          : Duration.zero,
    );
    if (widget.tripUpdateFeed != null && leg.toStopId.isNotEmpty) {
      final exactTime = getRealtimeArrivalTime(
        widget.tripUpdateFeed,
        leg,
        leg.toStopId,
      );
      if (exactTime != null) {
        finalBusArrivalTime = exactTime;
      }
    }

    Widget cancelOrDelayWidget = const SizedBox.shrink();

    if (isCanceled) {
      cancelOrDelayWidget = const Text(
        'PERUTTU',
        style: TextStyle(
          color: kDelayed,
          fontWeight: FontWeight.bold,
          fontSize: 13,
        ),
      );
    } else if (hasDelay) {
      cancelOrDelayWidget = Row(
        children: [
          Text(
            widget.formatTime(leg.departureTime),
            style: const TextStyle(color: Colors.grey, fontSize: 12),
          ),
          const SizedBox(width: 5),
          Text(
            widget.formatTime(realtimeDep),
            style: TextStyle(
              color: delayMin > 0 ? kDelayed : kOnTime,
              fontWeight: FontWeight.bold,
              fontSize: 13,
            ),
          ),
          const SizedBox(width: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: (delayMin > 0 ? kDelayed : kOnTime).withValues(
                alpha: 0.12,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '${delayMin > 0 ? '+' : ''}$delayMin min',
              style: TextStyle(
                fontSize: 11,
                color: delayMin > 0 ? kDelayed : kOnTime,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      );
    } else {
      cancelOrDelayWidget = Text(
        widget.formatTime(leg.departureTime),
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: kBusLight,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.directions_bus, color: kBus, size: 15),
                    const SizedBox(width: 6),
                    Text(
                      'Linja ${leg.busNumber}',
                      style: const TextStyle(
                        color: kBus,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                    if (hasIntermediateStops)
                      Expanded(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            GestureDetector(
                              onTap: () {
                                setState(() {
                                  _showStops = !_showStops;
                                });
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: kBus.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      '${leg.intermediateStops.length} pysäkkiä',
                                      style: const TextStyle(
                                        color: kBus,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(width: 2),
                                    Icon(
                                      _showStops
                                          ? Icons.expand_less
                                          : Icons.expand_more,
                                      size: 14,
                                      color: kBus,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    cancelOrDelayWidget,
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        '· ${leg.fromStop}',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.grey[600], fontSize: 12),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),

                if (hasIntermediateStops && _showStops)
                  Column(
                    children: [
                      Container(
                        margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.65),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          children: [
                            for (
                              int i = 0;
                              i < leg.intermediateStops.length;
                              i++
                            )
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 5,
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 7,
                                      height: 7,
                                      decoration: const BoxDecoration(
                                        color: kBus,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceBetween,
                                        children: [
                                          Expanded(
                                            child: Text(
                                              leg.intermediateStops[i].name,
                                              style: const TextStyle(
                                                fontSize: 12,
                                                color: Color(0xFF333333),
                                              ),
                                            ),
                                          ),
                                          Text(
                                            _getStopTime(
                                              i,
                                              leg,
                                              widget.tripUpdateFeed,
                                              widget.formatTime,
                                            ),
                                            style: const TextStyle(
                                              fontSize: 12,
                                              color: Colors.grey,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                      const Divider(height: 1, color: Color(0xFFEEEEEE)),
                      const SizedBox(height: 4),
                    ],
                  ),

                Row(
                  children: [
                    Text(
                      widget.formatTime(finalBusArrivalTime),
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        '· ${leg.toStop}',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.grey[600], fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class BusNumberBadge extends StatelessWidget {
  final BusLeg leg;
  final String Function(DateTime) formatTime;

  const BusNumberBadge({
    super.key,
    required this.leg,
    required this.formatTime,
  });

  void _showTripRoute(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        minChildSize: 0.4,
        maxChildSize: 0.9,
        builder: (context, scrollController) {
          return TripRouteSheet(leg: leg, formatTime: formatTime);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _showTripRoute(context),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: kBus,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: kBus.withValues(alpha: 0.35),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              leg.busNumber,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 14,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.info_outline, color: Colors.white, size: 12),
          ],
        ),
      ),
    );
  }
}
