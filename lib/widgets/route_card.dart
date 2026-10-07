import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:gtfs_realtime_bindings/gtfs_realtime_bindings.dart';
import '../models/app_models.dart';
import '../services/realtime_utils.dart';
import '../theme/app_colors.dart';
import '../widgets/trip_route_sheet.dart';

/// Kävelyn kesto kokonaisina minuutteina (vähintään 1), tai null jos kestoa
/// ei tiedetä (vanha välimuisti).
int? _walkMinutes(List<Duration> durations, int index) {
  if (index >= durations.length) return null;
  return math.max(1, (durations[index].inSeconds / 60).ceil());
}

/// Kävelyrivin teksti: "Kävele 268 m · n. 4 min → Kauppakuja E".
String _walkLabel(double meters, int? minutes, String? target) {
  final buf = StringBuffer('Kävele ${meters.round()} m');
  if (minutes != null) buf.write(' · n. $minutes min');
  if (target != null && target.isNotEmpty) buf.write(' → $target');
  return buf.toString();
}

/// Pieni värillinen merkki (tila, viive).
class _Badge extends StatelessWidget {
  final String text;
  final Color color;
  final IconData? icon;
  final bool outlined;

  const _Badge(this.text, this.color, {this.icon, this.outlined = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: outlined ? null : color.withValues(alpha: 0.12),
        border: outlined
            ? Border.all(color: color.withValues(alpha: 0.5))
            : null,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 3),
          ],
          Flexible(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
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
  final Map<String, TripRealtime>? tripRealtime;

  /// Milloin live-seurannan viiveet viimeksi päivittyivät (null = ei
  /// tuoretta live-tietoa).
  final DateTime? realtimeUpdatedAt;

  /// Saman linjan seuraava lähtö samalta pysäkiltä, näytetään jos
  /// ensimmäinen vuoro on peruttu.
  final DateTime? nextLineDeparture;

  /// Nykyhetki testejä varten; null = kello.
  final DateTime? now;

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
    this.tripRealtime,
    this.realtimeUpdatedAt,
    this.nextLineDeparture,
    this.now,
  });

  @override
  State<RouteCard> createState() => _RouteCardState();
}

class _RouteCardState extends State<RouteCard> {
  bool _isExpanded = false;

  /// Kortti päivittää lähtölaskennan ja ohitetut pysäkit ajan kuluessa,
  /// myös ilman live-seurantaa.
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  Widget _walkIcon(int index) {
    final int? minutes = _walkMinutes(widget.option.walkDurations, index);
    return Semantics(
      label: minutes != null ? 'kävelyä $minutes min' : 'kävelyä',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.directions_walk, size: 16, color: kWalk),
          if (minutes != null)
            Text(
              '$minutes',
              style: const TextStyle(
                fontSize: 12,
                color: kWalk,
                fontWeight: FontWeight.w600,
              ),
            ),
        ],
      ),
    );
  }

  /// Viive tai peruutus bussitunnuksen vieressä suljetussa kortissa.
  Widget? _legDelayChip(BusLeg leg, LegCancellation cancellation) {
    if (cancellation == LegCancellation.canceled) {
      return const _Badge('peruttu', kDelayed);
    }
    final DateTime? realtimeDep = realtimeLegDeparture(
      leg,
      widget.tripRealtime,
    );
    if (realtimeDep == null) return null;
    final int delay = clockMinutesBetween(leg.departureTime, realtimeDep);
    if (delay > 0) return _Badge('+$delay', kDelayed);
    if (delay < 0) return _Badge('$delay', kEarly);
    return null;
  }

  Widget _buildGraphicalTimeline(
    List<LegCancellation> cancellations,
    List<bool> legHasAlerts,
  ) {
    List<Widget> items = [];
    const arrow = Icon(
      Icons.arrow_right_alt_rounded,
      size: 18,
      color: Colors.grey,
    );

    if (widget.option.busLegs.isEmpty) {
      items.add(_walkIcon(0));
      items.add(arrow);
      items.add(const Icon(Icons.flag_rounded, size: 18, color: kPrimary));
      return Wrap(
        spacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        runSpacing: 8,
        children: items,
      );
    }

    // Offline-välimuistista ladatulta reitiltä kävelymatkat voivat
    // puuttua kokonaan, joten indeksit on tarkistettava.
    final walkDistances = widget.option.walkDistances;

    for (int i = 0; i < widget.option.busLegs.length; i++) {
      final leg = widget.option.busLegs[i];
      if (i < walkDistances.length && walkDistances[i] > 0) {
        items.add(_walkIcon(i));
        items.add(arrow);
      }

      items.add(
        BusNumberBadge(
          leg: leg,
          formatTime: widget.formatTime,
          hasAlert: legHasAlerts[i],
        ),
      );
      final Widget? delayChip = _legDelayChip(leg, cancellations[i]);
      if (delayChip != null) items.add(delayChip);

      if (i < widget.option.busLegs.length - 1 ||
          (i + 1 < walkDistances.length && walkDistances[i + 1] > 0)) {
        items.add(arrow);
      }
    }

    if (walkDistances.isNotEmpty && walkDistances.last > 0) {
      items.add(_walkIcon(walkDistances.length - 1));
      items.add(arrow);
    }
    items.add(const Icon(Icons.flag_rounded, size: 18, color: kPrimary));

    return Wrap(
      spacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      runSpacing: 8,
      children: items,
    );
  }

  /// Lähtölaskenta: "Lähde 4 min päästä" / "Lähde nyt" / "Bussi lähti".
  Widget? _statusChip(TripStatus status) {
    final String Function(DateTime) fmt = widget.formatTime;
    switch (status.phase) {
      case TripPhase.leaveLater:
        // Yli tunnin päästä lähtevälle riittää otsikon kellonaika.
        if (status.minutesToLeave > 60) return null;
        return _Badge(
          'Lähde ${status.minutesToLeave} min päästä',
          kBus,
          icon: Icons.schedule,
        );
      case TripPhase.leaveSoon:
        return _Badge(
          'Lähde ${status.minutesToLeave} min päästä',
          kEarly,
          icon: Icons.schedule,
        );
      case TripPhase.leaveNow:
        final DateTime? bus = status.busDeparture;
        return _Badge(
          bus == null ? 'Lähde nyt' : 'Lähde nyt · bussi ${fmt(bus)}',
          kDelayed,
          icon: Icons.directions_run,
        );
      case TripPhase.departed:
        final DateTime? bus = status.busDeparture;
        return _Badge(
          bus == null ? 'Lähtöaika meni' : 'Bussi lähti ${fmt(bus)}',
          Colors.grey[700]!,
        );
    }
  }

  /// Kertoo, minkä hetken tietoa ensimmäisen bussin aika on.
  Widget? _freshnessLabel() {
    if (widget.option.busLegs.isEmpty) return null;
    final RealtimeSource source = legDepartureSource(
      widget.option.busLegs.first,
      widget.tripRealtime,
    );
    final DateTime? liveAt = widget.realtimeUpdatedAt;
    if (source == RealtimeSource.live && liveAt != null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.sensors, size: 14, color: kOnTime),
          const SizedBox(width: 3),
          Text(
            'Live ${widget.formatTime(liveAt)}',
            style: const TextStyle(fontSize: 12, color: kOnTime),
          ),
        ],
      );
    }
    final DateTime? fetchedAt = widget.option.fetchedAt;
    if (source == RealtimeSource.snapshot && fetchedAt != null) {
      return Text(
        'Ennuste klo ${widget.formatTime(fetchedAt)}',
        style: TextStyle(fontSize: 12, color: Colors.grey[700]),
      );
    }
    return null;
  }

  Widget _transferChip(String text, Color color, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(left: 28, bottom: 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                text,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _walkRow(String label) {
    return Padding(
      padding: const EdgeInsets.only(left: 28, bottom: 4),
      child: Text(
        label,
        style: TextStyle(color: Colors.grey[700], fontSize: 12),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final DateTime now = widget.now ?? DateTime.now();
    final List<BusLeg> legs = widget.option.busLegs;

    // Vaiheen aikana voimassa olevat tiedotteet näytetään vaiheen kohdalla;
    // sama tiedote (esim. pysäkkitiedote) vain ensimmäisen vaiheen kohdalla.
    final Set<String> seenAlertTexts = {};
    final List<List<AlertInfo>> legAlerts = [];
    final List<bool> legHasAlerts = [];
    for (final leg in legs) {
      final active = activeLegAlerts(leg, widget.tripRealtime);
      legHasAlerts.add(active.isNotEmpty);
      legAlerts.add([
        for (final alert in active)
          if (seenAlertTexts.add(alert.text)) alert,
      ]);
    }

    final List<LegCancellation> cancellations = [
      for (final leg in legs) legCancellation(leg, widget.tripRealtime),
    ];
    final bool hasCanceledLeg = cancellations.contains(
      LegCancellation.canceled,
    );
    final bool hasSkippedStop = cancellations.any(
      (c) =>
          c == LegCancellation.boardingSkipped ||
          c == LegCancellation.alightingSkipped,
    );

    final DateTime realArrival = realArrivalTime(
      widget.option,
      widget.tripRealtime,
    );
    // Lähtöaika seuraa ensimmäisen bussin viivettä kuten OTP:n
    // reittiehdotukset; aikataulun mukainen aika näytetään rinnalla.
    final DateTime leaveTime = displayedLeaveTime(
      widget.option,
      widget.tripRealtime,
    );
    final bool isLeaveShifted =
        clockMinutesBetween(widget.option.leaveHomeTime, leaveTime) != 0;

    final totalMinutes = clockMinutesBetween(leaveTime, realArrival);

    // Toisen päivän välimuistireitti: lähtölaskenta ja ohitetut pysäkit
    // kertoisivat tämän päivän bussista väärin ("Bussi lähti").
    final bool isOtherDay =
        widget.isOfflineData && !DateUtils.isSameDay(leaveTime, now);

    // Perutulle ensimmäiselle vuorolle ei näytetä lähtölaskentaa.
    final Widget? statusChip =
        isOtherDay ||
            (legs.isNotEmpty && cancellations.first != LegCancellation.none)
        ? null
        : _statusChip(tripStatus(widget.option, widget.tripRealtime, now));
    final Widget? freshness = _freshnessLabel();

    final walkDistances = widget.option.walkDistances;
    final walkDurations = widget.option.walkDurations;

    List<Widget> timelineWidgets = [];
    timelineWidgets.add(
      TimelineRow(
        icon: Icons.directions_walk,
        iconColor: kWalk,
        label: 'Lähde klo ${widget.formatTime(leaveTime)}',
        labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
        trailing: isLeaveShifted
            ? 'aikataulu ${widget.formatTime(widget.option.leaveHomeTime)}'
            : null,
      ),
    );

    if (walkDistances.isNotEmpty && walkDistances[0] > 0) {
      timelineWidgets.add(const TimelineDivider());
      timelineWidgets.add(
        _walkRow(
          _walkLabel(
            walkDistances[0],
            _walkMinutes(walkDurations, 0),
            legs.isNotEmpty ? legs.first.fromStop : null,
          ),
        ),
      );
    }

    for (int i = 0; i < legs.length; i++) {
      timelineWidgets.add(const TimelineDivider());
      final leg = legs[i];
      timelineWidgets.add(
        BusLegSection(
          leg: leg,
          formatTime: widget.formatTime,
          tripRealtime: widget.tripRealtime,
          now: now,
          showProgress: !isOtherDay,
          predictionTime: widget.option.fetchedAt,
          nextLineDeparture: i == 0 ? widget.nextLineDeparture : null,
          alerts: legAlerts[i],
        ),
      );

      if (i + 1 < legs.length && legs[i + 1].stayOnBus) {
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
      } else if (i + 1 < legs.length) {
        final nextLeg = legs[i + 1];
        // Vaihtokävely on indeksissä i + 1 (kävely ennen vaihetta i + 1).
        final int lateness = transferLatenessMinutes(
          leg,
          nextLeg,
          widget.tripRealtime,
          transferWalk: i + 1 < walkDurations.length
              ? walkDurations[i + 1]
              : Duration.zero,
        );
        // Perutun tai pysäkin ohittavan vaiheen vaihtoaika ei kerro mitään –
        // peruutus näkyy omana varoituksenaan.
        final bool isTransferMeaningful =
            cancellations[i] == LegCancellation.none &&
            cancellations[i + 1] == LegCancellation.none;

        if (isTransferMeaningful && lateness > 0) {
          timelineWidgets.add(const TimelineDivider());
          timelineWidgets.add(
            _transferChip(
              'Vaihto linja ${nextLeg.busNumber} voi jäädä – $lateness min myöhässä',
              kDelayed,
              Icons.warning_amber_rounded,
            ),
          );
        } else if (isTransferMeaningful && lateness > -3) {
          timelineWidgets.add(const TimelineDivider());
          timelineWidgets.add(
            _transferChip(
              'Vaihto linja ${nextLeg.busNumber} tiukka – alle 3 min',
              Colors.orange[800]!,
              Icons.schedule,
            ),
          );
        }

        if (i + 1 < walkDistances.length && walkDistances[i + 1] > 0) {
          timelineWidgets.add(const TimelineDivider());
          timelineWidgets.add(
            _walkRow(
              _walkLabel(
                walkDistances[i + 1],
                _walkMinutes(walkDurations, i + 1),
                nextLeg.fromStop,
              ),
            ),
          );
        }
      }

      // Kävely viimeisen bussivaiheen jälkeen
      if (i + 1 == legs.length && i + 1 < walkDistances.length) {
        final lastWalk = walkDistances[i + 1];
        if (lastWalk > 0) {
          timelineWidgets.add(const TimelineDivider());
          timelineWidgets.add(
            _walkRow(
              _walkLabel(lastWalk, _walkMinutes(walkDurations, i + 1), null),
            ),
          );
        }
      }
    }

    final String semanticSummary =
        'Reitti: lähde klo ${widget.formatTime(leaveTime)}, perillä klo '
        '${widget.formatTime(realArrival)}, $totalMinutes minuuttia'
        '${legs.isEmpty ? ', kävellen' : ', linjat ${legs.map((l) => l.busNumber).join(', ')}'}';

    return Semantics(
      container: true,
      label: semanticSummary,
      child: GestureDetector(
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
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.wifi_off,
                          size: 14,
                          color: Colors.orange[900],
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            'Tallennettu reitti – ei reaaliaikainen',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.orange[900],
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                if (hasCanceledLeg || hasSkippedStop)
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: kDelayed.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: kDelayed.withValues(alpha: 0.4),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.cancel_outlined,
                          size: 14,
                          color: kDelayed,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            hasCanceledLeg
                                ? 'Reitin bussivuoro on peruttu'
                                : 'Bussi ei pysähdy reitin pysäkillä',
                            style: const TextStyle(
                              fontSize: 12,
                              color: kDelayed,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                if (statusChip != null || freshness != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      children: [
                        // Merkki saa kaiken tilan, jota tuoreustieto ei vie,
                        // eikä rivity turhaan.
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: statusChip ?? const SizedBox.shrink(),
                          ),
                        ),
                        if (freshness != null) ...[
                          const SizedBox(width: 8),
                          freshness,
                        ],
                      ],
                    ),
                  ),

                // Ajat ja kesto sisältyvät kortin ruudunlukijakuvaukseen.
                ExcludeSemantics(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      // Suurella tekstikoolla ajat pienenevät rivin leveyteen
                      // sen sijaan, että rivi vuotaisi yli.
                      Expanded(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                widget.formatTime(leaveTime),
                                style: const TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF222222),
                                  letterSpacing: -0.5,
                                ),
                              ),
                              const Padding(
                                padding: EdgeInsets.only(
                                  bottom: 6,
                                  left: 8,
                                  right: 8,
                                ),
                                child: Icon(
                                  Icons.arrow_forward_rounded,
                                  color: Colors.grey,
                                  size: 20,
                                ),
                              ),
                              Text(
                                widget.formatTime(realArrival),
                                style: const TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF222222),
                                  letterSpacing: -0.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
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
                            color: widget.isSelected ? kBus : Colors.grey[800],
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                _buildGraphicalTimeline(cancellations, legHasAlerts),

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
                          vertical: 10,
                        ),
                        minimumSize: const Size(48, 44),
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
                          tooltip: 'Jaa reitti',
                          icon: Icon(
                            Icons.share_outlined,
                            size: 20,
                            color: Colors.grey[600],
                          ),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 44,
                            minHeight: 44,
                          ),
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          onPressed: widget.onToggleFavorite,
                          tooltip: widget.isFavorite
                              ? 'Poista suosikeista'
                              : 'Lisää suosikkeihin',
                          icon: Icon(
                            widget.isFavorite
                                ? Icons.star_rounded
                                : Icons.star_border_rounded,
                            size: 24,
                            color: widget.isFavorite
                                ? kAccent
                                : Colors.grey[500],
                          ),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 44,
                            minHeight: 44,
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
                                  'Perillä klo ${widget.formatTime(realArrival)}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 14,
                                    color: kPrimaryDark,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
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

  /// Pienempi lisäteksti otsikon perässä (esim. aikataulun mukainen aika).
  final String? trailing;

  const TimelineRow({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.label,
    this.labelStyle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: iconColor, size: 16),
        const SizedBox(width: 8),
        Flexible(
          child: Text.rich(
            TextSpan(
              text: label,
              style: labelStyle ?? const TextStyle(fontSize: 13),
              children: [
                if (trailing != null)
                  TextSpan(
                    text: '  $trailing',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.normal,
                      color: Colors.grey[700],
                    ),
                  ),
              ],
            ),
          ),
        ),
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
  final Map<String, TripRealtime>? tripRealtime;

  /// Nykyhetki: ohitetut pysäkit ja bussin sijainti lasketaan tästä.
  final DateTime? now;

  /// Näytetäänkö eteneminen (lähtenyt, ohitetut pysäkit). Pois toisen päivän
  /// välimuistireitiltä, jonka ajat eivät koske tätä päivää.
  final bool showProgress;

  /// Milloin hakuhetken ennuste haettiin ("ennuste klo 07:35").
  final DateTime? predictionTime;

  /// Saman linjan seuraava lähtö, jos tämä vuoro on peruttu.
  final DateTime? nextLineDeparture;

  /// Vaiheen aikana voimassa olevat tiedotteet.
  final List<AlertInfo> alerts;

  const BusLegSection({
    super.key,
    required this.leg,
    required this.formatTime,
    this.tripRealtime,
    this.now,
    this.showProgress = true,
    this.predictionTime,
    this.nextLineDeparture,
    this.alerts = const [],
  });

  @override
  State<BusLegSection> createState() => _BusLegSectionState();
}

/// Eteneminen, jossa mitään ei ole vielä ohitettu (perutut ja toisen päivän
/// vaiheet).
const LegProgress _notStarted = LegProgress(
  hasDeparted: false,
  passedStops: 0,
  hasArrived: false,
  isLive: false,
);

/// Pysäkkimäärän taivutus: "1 pysäkki" / "3 pysäkkiä".
String _stops(int count) => count == 1 ? '1 pysäkki' : '$count pysäkkiä';

class _BusLegSectionState extends State<BusLegSection> {
  /// Näytetäänkö kaikki välipysäkit vai tiivistetty lista.
  bool _showAllStops = false;

  void _toggleStops() => setState(() => _showAllStops = !_showAllStops);

  /// Lähtörivin aika ja tilamerkki.
  Widget _departureRow(LegCancellation cancellation, LegProgress progress) {
    final BusLeg leg = widget.leg;
    final String Function(DateTime) fmt = widget.formatTime;
    final DateTime? liveDep = realtimeLegDeparture(leg, widget.tripRealtime);
    final DateTime realtimeDep = liveDep ?? leg.departureTime;
    // Minuutit lasketaan näytetyistä kellonajoista, jotta merkki täsmää
    // niihin (07:46 → 07:54 on 8 min, vaikka sekunteina ero olisi 7:30).
    final int delayMin = clockMinutesBetween(leg.departureTime, realtimeDep);
    final Widget stopName = Text(
      '· ${leg.fromStop}',
      style: TextStyle(color: Colors.grey[700], fontSize: 12),
    );
    const struck = TextStyle(
      color: Colors.grey,
      fontSize: 13,
      decoration: TextDecoration.lineThrough,
    );

    final List<Widget> parts;
    if (cancellation == LegCancellation.canceled) {
      // Kortti voi olla auki pitkään: jo lähtenyttä vaihtoehtoa ei tarjota.
      final DateTime? candidate = widget.nextLineDeparture;
      final DateTime? next =
          candidate != null &&
              clockMinutesBetween(widget.now ?? DateTime.now(), candidate) >= 0
          ? candidate
          : null;
      parts = [
        Text(fmt(leg.departureTime), style: struck),
        _Badge(
          next == null ? 'peruttu' : 'peruttu · seuraava ${fmt(next)}',
          kDelayed,
          icon: Icons.block,
        ),
        stopName,
      ];
    } else if (cancellation == LegCancellation.boardingSkipped) {
      parts = [
        Text(fmt(leg.departureTime), style: struck),
        const _Badge('Ei pysähdy', kDelayed, icon: Icons.block),
        stopName,
      ];
    } else if (progress.hasDeparted) {
      // Lähtöaika ei voi olla tulevaisuudessa (ks. departedTime).
      final DateTime departed = departedTime(
        leg,
        widget.tripRealtime,
        widget.now ?? DateTime.now(),
      );
      parts = [
        Text('${fmt(departed)} · ${leg.fromStop}', style: struck),
        Text('lähti', style: TextStyle(color: Colors.grey[700], fontSize: 12)),
      ];
    } else {
      final Widget badge;
      if (liveDep != null && delayMin > 0) {
        badge = _Badge(
          '$delayMin min myöhässä',
          kDelayed,
          icon: Icons.schedule,
        );
      } else if (liveDep != null && delayMin < 0) {
        badge = _Badge(
          '${-delayMin} min etuajassa',
          kEarly,
          icon: Icons.warning_amber_rounded,
        );
      } else if (liveDep != null) {
        badge = const _Badge('ajallaan', kOnTime, icon: Icons.sensors);
      } else {
        badge = Text(
          'aikataulu',
          style: TextStyle(color: Colors.grey[700], fontSize: 12),
        );
      }
      final Color timeColor = liveDep == null
          ? const Color(0xFF222222)
          : delayMin > 0
          ? kDelayed
          : delayMin < 0
          ? kEarly
          : kOnTime;
      parts = [
        Text(
          fmt(realtimeDep),
          style: TextStyle(
            color: timeColor,
            fontWeight: FontWeight.bold,
            fontSize: 14,
          ),
        ),
        badge,
        stopName,
      ];
    }

    final bool isSnapshot =
        legDepartureSource(leg, widget.tripRealtime) == RealtimeSource.snapshot;
    final DateTime? predictionTime = widget.predictionTime;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: parts,
        ),
        // Hakuhetken ennuste voi olla vanha – kerrotaan sen ikä.
        if (isSnapshot &&
            predictionTime != null &&
            !progress.hasDeparted &&
            cancellation == LegCancellation.none)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: _Badge(
              'ennuste klo ${fmt(predictionTime)}',
              Colors.grey[700]!,
              outlined: true,
            ),
          ),
      ],
    );
  }

  Widget _stopRow({
    required String name,
    required StopTimeEstimate estimate,
    required bool isPassed,
  }) {
    final String time = widget.formatTime(estimate.time);
    final Color textColor = isPassed ? Colors.grey : const Color(0xFF333333);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: isPassed ? Colors.grey[400] : kBus,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(name, style: TextStyle(fontSize: 13, color: textColor)),
          ),
          if (estimate.isLive && !isPassed) ...[
            const Icon(Icons.sensors, size: 12, color: kOnTime),
            const SizedBox(width: 3),
            Text(time, style: const TextStyle(fontSize: 13, color: kOnTime)),
          ] else
            Text(
              // "~" = arvio (aikataulu viiveellä siirrettynä tai hakuhetken
              // ennuste); pelkkä aikataulu ja live-aika ilman merkkiä.
              estimate.kind == StopTimeKind.estimate ? '~$time' : time,
              style: TextStyle(
                fontSize: 13,
                color: isPassed ? Colors.grey : Colors.grey[700],
              ),
            ),
        ],
      ),
    );
  }

  Widget _busPositionRow(
    String stopName,
    StopTimeEstimate estimate,
    bool isLive,
  ) {
    // Ilman live-ennustetta aika on arvio; "aikataulun mukaan" vain, jos
    // siihen ei ole lisätty hakuhetken viivettä.
    final bool isScheduleOnly =
        legDepartureSource(widget.leg, widget.tripRealtime) ==
        RealtimeSource.schedule;
    final String label = isLive
        ? 'Bussi seuraavaksi · $stopName'
        : isScheduleOnly
        ? 'Aikataulun mukaan seuraavaksi · $stopName'
        : 'Arviolta seuraavaksi · $stopName';
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: kAccent.withValues(alpha: 0.30),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          const Icon(Icons.directions_bus, size: 16, color: kPrimaryDark),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: kPrimaryDark,
              ),
            ),
          ),
          Text(
            estimate.kind == StopTimeKind.estimate
                ? '~${widget.formatTime(estimate.time)}'
                : widget.formatTime(estimate.time),
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: kPrimaryDark,
            ),
          ),
        ],
      ),
    );
  }

  Widget _summaryRow(String text, {IconData? icon, VoidCallback? onTap}) {
    final Widget row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: onTap != null ? kBus : Colors.grey),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                color: onTap != null ? kBus : Colors.grey[700],
                fontWeight: onTap != null ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return row;
    // Oma Material-kerros, jotta painallus näkyy läpinäkymättömän taustan
    // päällä.
    return Semantics(
      button: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(onTap: onTap, child: row),
      ),
    );
  }

  /// Välipysäkit: tiivistettynä seuraavat pysäkit (ja bussissa ollessa
  /// bussin sijainti), kokonaan avattuna kaikki – ohitetut himmennettyinä.
  /// Perutun vuoron pysäkit ovat tiivistettynä piilossa avausrivin takana.
  Widget _stopList(LegProgress progress, {required bool isCanceled}) {
    final BusLeg leg = widget.leg;
    final int count = leg.intermediateStops.length;
    if (isCanceled && !_showAllStops) {
      return Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 8),
        child: _summaryRow(
          'Näytä ${_stops(count)}',
          icon: Icons.expand_more,
          onTap: _toggleStops,
        ),
      );
    }
    final List<StopTimeEstimate> estimates = [
      for (int i = 0; i < count; i++)
        intermediateStopTime(i, leg, widget.tripRealtime),
    ];
    final bool isOnTheWay = progress.hasDeparted && !progress.hasArrived;
    // Bussin seuraava pysäkki; count = poistumispysäkki.
    final int nextIndex = progress.passedStops;

    final List<Widget> rows = [];
    void addBusRow() {
      if (nextIndex < count) {
        rows.add(
          _busPositionRow(
            leg.intermediateStops[nextIndex].name,
            estimates[nextIndex],
            progress.isLive,
          ),
        );
      } else {
        rows.add(
          _busPositionRow(
            leg.toStop,
            displayedLegArrivalEstimate(leg, widget.tripRealtime),
            progress.isLive,
          ),
        );
      }
    }

    if (_showAllStops) {
      for (int i = 0; i < count; i++) {
        if (isOnTheWay && i == nextIndex) {
          addBusRow();
          continue;
        }
        rows.add(
          _stopRow(
            name: leg.intermediateStops[i].name,
            estimate: estimates[i],
            isPassed: progress.hasDeparted && i < progress.passedStops,
          ),
        );
      }
      if (isOnTheWay && nextIndex >= count) addBusRow();
      rows.add(
        _summaryRow(
          'Näytä vähemmän',
          icon: Icons.expand_less,
          onTap: _toggleStops,
        ),
      );
    } else if (progress.hasArrived) {
      // Piilotetut pysäkit saa aina auki: rivi toimii avausnappina.
      rows.add(
        _summaryRow(
          count == 1 ? 'Pysäkki ohitettu' : 'Kaikki $count pysäkkiä ohitettu',
          icon: Icons.expand_more,
          onTap: _toggleStops,
        ),
      );
    } else {
      int first;
      if (isOnTheWay) {
        // Viimeisin ohitettu pysäkki himmennettynä, sitten bussin sijainti.
        // Aiemmat ohitetut saa auki tästä rivistä.
        if (nextIndex > 1) {
          final int earlier = nextIndex - 1;
          rows.add(
            _summaryRow(
              earlier == 1
                  ? '… 1 ohitettu pysäkki'
                  : '… $earlier ohitettua pysäkkiä',
              icon: Icons.expand_more,
              onTap: _toggleStops,
            ),
          );
        }
        if (nextIndex > 0) {
          rows.add(
            _stopRow(
              name: leg.intermediateStops[nextIndex - 1].name,
              estimate: estimates[nextIndex - 1],
              isPassed: true,
            ),
          );
        }
        addBusRow();
        first = nextIndex + 1;
      } else {
        first = 0;
      }
      final int last = math.min(count, first + (isOnTheWay ? 2 : 3));
      for (int i = first; i < last; i++) {
        rows.add(
          _stopRow(
            name: leg.intermediateStops[i].name,
            estimate: estimates[i],
            isPassed: false,
          ),
        );
      }
      final int hidden = count - last;
      if (hidden > 0) {
        rows.add(
          _summaryRow(
            '${_stops(hidden)} lisää',
            icon: Icons.expand_more,
            onTap: _toggleStops,
          ),
        );
      }
    }

    return Container(
      margin: const EdgeInsets.only(top: 6, bottom: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: rows,
      ),
    );
  }

  Widget _alertBox(List<AlertInfo> alerts) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
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
              Icon(
                Icons.warning_amber_rounded,
                color: Colors.orange[900],
                size: 16,
              ),
              const SizedBox(width: 6),
              Text(
                alerts.length > 1 ? 'Häiriötiedotteet' : 'Häiriötiedote',
                style: TextStyle(
                  color: Colors.orange[900],
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                ),
              ),
            ],
          ),
          for (final alert in alerts)
            Padding(
              padding: const EdgeInsets.only(top: 4),
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
    );
  }

  @override
  Widget build(BuildContext context) {
    final BusLeg leg = widget.leg;
    final DateTime now = widget.now ?? DateTime.now();
    final bool hasIntermediateStops = leg.intermediateStops.isNotEmpty;

    // Peruutus voi näkyä hakuhetken tilassa tai tulla live-seurannasta
    // pysäkkikohtaisena tilana, ks. legCancellation.
    final LegCancellation cancellation = legCancellation(
      leg,
      widget.tripRealtime,
    );
    final bool isCanceled = cancellation == LegCancellation.canceled;
    final bool isAlightingStopCanceled =
        cancellation == LegCancellation.alightingSkipped;
    // Perutun vuoron "etenemistä" ei näytetä (ei bussin sijaintia).
    final LegProgress progress = widget.showProgress && !isCanceled
        ? legProgress(leg, widget.tripRealtime, now)
        : _notStarted;

    final DateTime finalBusArrivalTime = displayedLegArrival(
      leg,
      widget.tripRealtime,
    );

    return Container(
      decoration: BoxDecoration(
        color: kBusLight,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.directions_bus, color: kBus, size: 16),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Linja ${leg.busNumber}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: kBus,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _departureRow(cancellation, progress),

          // Pysäkkilistan ainoa avaus/sulku on listan oma rivi.
          if (hasIntermediateStops)
            _stopList(progress, isCanceled: isCanceled)
          else
            const SizedBox(height: 6),

          Wrap(
            spacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Icon(Icons.place, size: 15, color: kBus),
              Text(
                widget.formatTime(finalBusArrivalTime),
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  decoration: isAlightingStopCanceled || isCanceled
                      ? TextDecoration.lineThrough
                      : null,
                ),
              ),
              Text(
                // "Jää pois" vain, jos bussi oikeasti pysähtyy pysäkillä.
                cancellation == LegCancellation.none
                    ? '· ${leg.toStop} · jää pois'
                    : '· ${leg.toStop}',
                style: TextStyle(color: Colors.grey[700], fontSize: 12),
              ),
              if (isAlightingStopCanceled)
                const _Badge('Ei pysähdy', kDelayed, icon: Icons.block),
            ],
          ),
          if (widget.alerts.isNotEmpty) _alertBox(widget.alerts),
        ],
      ),
    );
  }
}

class BusNumberBadge extends StatelessWidget {
  final BusLeg leg;
  final String Function(DateTime) formatTime;

  /// Vaiheella on voimassa oleva häiriötiedote.
  final bool hasAlert;

  const BusNumberBadge({
    super.key,
    required this.leg,
    required this.formatTime,
    this.hasAlert = false,
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
    return Semantics(
      button: true,
      label:
          'Linja ${leg.busNumber}${hasAlert ? ', häiriötiedote' : ''}, '
          'näytä koko reitti',
      excludeSemantics: true,
      // Ruudunlukijan napautus; lapsen semantiikka on rajattu pois.
      onTap: () => _showTripRoute(context),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _showTripRoute(context),
        // Näkyvä merkki on pieni; reunus kasvattaa kosketusaluetta.
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
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
                Icon(
                  hasAlert ? Icons.warning_amber_rounded : Icons.info_outline,
                  color: hasAlert ? kAccent : Colors.white,
                  size: hasAlert ? 14 : 12,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
