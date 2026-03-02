import 'dart:async';
import 'package:flutter/material.dart';
import 'package:gtfs_realtime_bindings/gtfs_realtime_bindings.dart';
import 'package:latlong2/latlong.dart';
import '../models/app_models.dart';
import '../theme/app_colors.dart';

/// Returns the exact realtime arrival/departure for a specific stop from TripUpdate feed
DateTime? getRealtimeStopTime(
  FeedMessage? tripUpdateFeed,
  BusLeg leg,
  String stopId,
) {
  if (tripUpdateFeed == null || leg.tripId.isEmpty) {
    return null;
  }

  for (final entity in tripUpdateFeed.entity) {
    if (!entity.hasTripUpdate()) {
      continue;
    }

    final tripUpdate = entity.tripUpdate;
    final trip = tripUpdate.trip;
    final tripId = trip.tripId;

    if (tripId.isEmpty) {
      continue;
    }

    bool tripMatches =
        (tripId == leg.tripId) ||
        leg.tripId.endsWith(':$tripId') ||
        leg.tripId.contains(tripId);

    if (tripMatches) {
      for (final stopTimeUpdate in tripUpdate.stopTimeUpdate) {
        if (stopTimeUpdate.hasStopId()) {
          final updateStopId = stopTimeUpdate.stopId;
          bool stopMatches =
              (updateStopId == stopId) ||
              stopId.endsWith(':$updateStopId') ||
              stopId == updateStopId;

          if (stopMatches) {
            if (stopTimeUpdate.hasArrival() &&
                stopTimeUpdate.arrival.hasTime()) {
              return DateTime.fromMillisecondsSinceEpoch(
                stopTimeUpdate.arrival.time.toInt() * 1000,
              );
            } else if (stopTimeUpdate.hasDeparture() &&
                stopTimeUpdate.departure.hasTime()) {
              return DateTime.fromMillisecondsSinceEpoch(
                stopTimeUpdate.departure.time.toInt() * 1000,
              );
            }
          }
        }
      }
    }
  }
  return null;
}

// compute time for the i‑th intermediate stop using TripUpdate if available, else fallback to estimation
String _getStopTime(
  int index,
  BusLeg leg,
  FeedMessage? tripUpdateFeed,
  String Function(DateTime) fmt,
) {
  // 1. Try to get the exact time from the TripUpdate feed
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

  // 2. Fallback to the mathematical estimation
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

/// Returns the index in [leg].legStopIds of the vehicle's current/next stop, or null if no match.
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

    bool tripMatches =
        (tripId == leg.tripId) ||
        leg.tripId.endsWith(':$tripId') ||
        leg.tripId.contains(tripId);

    if (!tripMatches) {
      continue;
    }

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

            debugPrint(
              'Realtime heuristic for ${leg.busNumber}: closest=$closestIdx (${bestDist.toStringAsFixed(0)}m), assigned=$assignedIdx',
            );
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
      debugPrint(
        'Realtime match found! Bus ${leg.busNumber} is at stop index $idx (stopId: $stopId)',
      );
      return idx;
    }
  }
  return null;
}

class RouteCard extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final isWalkOnly = option.busLegs.isEmpty;
    final allAlerts = option.busLegs.expand((leg) => leg.alerts).toList();

    // --- LASKETAAN KOKO KORTIN TODELLINEN SAAPUMISAIKA ---
    DateTime realArrivalTime = option.arrivalTime;
    if (option.busLegs.isNotEmpty) {
      final lastLeg = option.busLegs.last;
      final Duration walkAfterBus = option.arrivalTime.difference(
        lastLeg.arrivalTime,
      );

      DateTime lastLegRealArrival = lastLeg.arrivalTime.add(
        lastLeg.isRealtime
            ? lastLeg.realtimeDeparture.difference(lastLeg.departureTime)
            : Duration.zero,
      );

      if (tripUpdateFeed != null && lastLeg.toStopId.isNotEmpty) {
        final exactTime = getRealtimeStopTime(
          tripUpdateFeed,
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
        .difference(option.leaveHomeTime)
        .inMinutes;
    // -------------------------------------------------------

    List<Widget> timelineWidgets = [];

    timelineWidgets.add(
      TimelineRow(
        icon: Icons.directions_walk,
        iconColor: kWalk,
        label: 'Lähde klo ${formatTime(option.leaveHomeTime)}',
        labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
      ),
    );

    if (option.walkDistances.isNotEmpty && option.walkDistances[0] > 0) {
      timelineWidgets.add(const TimelineDivider());
      timelineWidgets.add(
        Padding(
          padding: const EdgeInsets.only(left: 28, bottom: 4),
          child: Text(
            'Kävele ${option.walkDistances[0].round()} m',
            style: TextStyle(color: Colors.grey[600], fontSize: 12),
          ),
        ),
      );
    }

    for (int i = 0; i < option.busLegs.length; i++) {
      timelineWidgets.add(const TimelineDivider());
      final leg = option.busLegs[i];
      final realtimeCurrentStopIndex = getRealtimeCurrentStopIndex(
        liveFeed,
        leg,
      );
      timelineWidgets.add(
        BusLegSection(
          leg: leg,
          formatTime: formatTime,
          realtimeCurrentStopIndex: realtimeCurrentStopIndex,
          tripUpdateFeed: tripUpdateFeed,
        ),
      );

      if (i + 1 < option.busLegs.length && option.busLegs[i + 1].stayOnBus) {
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
      } else if (i + 1 < option.walkDistances.length) {
        double nextWalk = option.walkDistances[i + 1];

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

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFF0F4FF) : Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: isSelected ? kBus : Colors.transparent,
            width: 2,
          ),
          boxShadow: [
            BoxShadow(
              color: isSelected
                  ? kBus.withValues(alpha: 0.15)
                  : Colors.black.withValues(alpha: 0.07),
              blurRadius: isSelected ? 16 : 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (isOfflineData)
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
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
                      Icon(Icons.wifi_off, size: 12, color: Colors.orange),
                      SizedBox(width: 4),
                      Text(
                        'Tallennettu reitti – ei reaaliaikainen',
                        style: TextStyle(fontSize: 10, color: Colors.orange),
                      ),
                    ],
                  ),
                ),
              Row(
                children: [
                  if (isWalkOnly)
                    const WalkBadge()
                  else
                    Wrap(
                      spacing: 6,
                      children: [
                        for (int i = 0; i < option.busLegs.length; i++) ...[
                          if (i > 0)
                            const Icon(
                              Icons.arrow_forward,
                              size: 14,
                              color: Colors.grey,
                            ),
                          BusNumberBadge(option.busLegs[i].busNumber),
                        ],
                      ],
                    ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? kBus.withValues(alpha: 0.1)
                          : kSurface,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '$totalMinutes min',
                      style: TextStyle(
                        color: isSelected ? kBus : Colors.grey[600],
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  GestureDetector(
                    onTap: onShare,
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      child: Icon(
                        Icons.share,
                        size: 18,
                        color: Colors.grey[400],
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: onToggleFavorite,
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      child: Icon(
                        isFavorite
                            ? Icons.star_rounded
                            : Icons.star_border_rounded,
                        size: 20,
                        color: isFavorite ? kAccent : Colors.grey[400],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              ...timelineWidgets,
              const SizedBox(height: 8),
              const Divider(height: 1, color: Color(0xFFEEEEEE)),
              const SizedBox(height: 10),
              Row(
                children: [
                  const Icon(Icons.flag_rounded, color: kPrimary, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    'Perillä klo ${formatTime(realArrivalTime)}',
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
                  padding: const EdgeInsets.only(top: 10),
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: kAlert.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: kAlert.withValues(alpha: 0.3)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.warning_amber_rounded,
                              color: kAlert,
                              size: 16,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Häiriötiedote${allAlerts.length > 1 ? 't' : ''}',
                              style: const TextStyle(
                                color: kAlert,
                                fontWeight: FontWeight.w700,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                        for (final alert in allAlerts)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              alert.text,
                              style: TextStyle(
                                color: Colors.grey[800],
                                fontSize: 11,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class WalkBadge extends StatelessWidget {
  const WalkBadge({super.key});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: kWalk,
        borderRadius: BorderRadius.circular(20),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.directions_walk, color: Colors.white, size: 14),
          SizedBox(width: 4),
          Text(
            'Kävely',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 13,
            ),
          ),
        ],
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
  final int? realtimeCurrentStopIndex;
  final FeedMessage? tripUpdateFeed;

  const BusLegSection({
    super.key,
    required this.leg,
    required this.formatTime,
    this.realtimeCurrentStopIndex,
    this.tripUpdateFeed,
  });

  @override
  State<BusLegSection> createState() => _BusLegSectionState();
}

class _BusLegSectionState extends State<BusLegSection> {
  bool _showStops = false;
  Timer? _fallbackTimer;

  @override
  void initState() {
    super.initState();
    _fallbackTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _fallbackTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final BusLeg leg = widget.leg;
    final bool isCanceled = leg.realtimeState == 'CANCELED';
    final bool hasDelay =
        leg.isRealtime &&
        leg.realtimeDeparture.difference(leg.departureTime).inMinutes != 0;
    final int delayMin = leg.realtimeDeparture
        .difference(leg.departureTime)
        .inMinutes;
    final bool hasIntermediateStops = leg.intermediateStops.isNotEmpty;

    // --- LASKETAAN TÄMÄN BUSSIOSUUDEN PÄÄTEPYSÄKIN TODELLINEN AIKA ---
    DateTime finalBusArrivalTime = leg.arrivalTime.add(
      leg.isRealtime
          ? leg.realtimeDeparture.difference(leg.departureTime)
          : Duration.zero,
    );
    if (widget.tripUpdateFeed != null && leg.toStopId.isNotEmpty) {
      final exactTime = getRealtimeStopTime(
        widget.tripUpdateFeed,
        leg,
        leg.toStopId,
      );
      if (exactTime != null) {
        finalBusArrivalTime = exactTime;
      }
    }
    // -----------------------------------------------------------------

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
            widget.formatTime(leg.realtimeDeparture),
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

                // PÄÄTEPYSÄKKI - NYT KÄYTETÄÄN TODELLISTA AIKAA!
                Row(
                  children: [
                    Text(
                      widget.formatTime(
                        finalBusArrivalTime,
                      ), // PÄIVITETTY TÄHÄN
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
  final String busNumber;
  const BusNumberBadge(this.busNumber, {super.key});
  @override
  Widget build(BuildContext context) {
    return Container(
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
      child: Text(
        busNumber,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
          fontSize: 14,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
