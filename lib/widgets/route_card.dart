import 'package:flutter/material.dart';
import '../models/app_models.dart';
import '../theme/app_colors.dart';

class RouteCard extends StatelessWidget {
  final RouteOption option;
  final bool isSelected;
  final bool isFavorite;
  final bool isOfflineData;
  final String Function(DateTime) formatTime;
  final VoidCallback onTap;
  final VoidCallback onToggleFavorite;
  final VoidCallback onShare;

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
  });

  @override
  Widget build(BuildContext context) {
    final isWalkOnly = option.busLegs.isEmpty;
    final totalMinutes = option.arrivalTime
        .difference(option.leaveHomeTime)
        .inMinutes;
    final allAlerts = option.busLegs.expand((leg) => leg.alerts).toList();

    List<Widget> timelineWidgets = [];

    timelineWidgets.add(
      TimelineRow(
        icon: Icons.directions_walk,
        iconColor: kWalk,
        label: 'Lähde klo ${formatTime(option.leaveHomeTime)}',
        labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
      ),
    );

    // 1. Alkusijainnista kävely ensimmäiselle pysäkille (jos > 0m)
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

    // 2. Loopataan kaikki bussimatkat läpi
    for (int i = 0; i < option.busLegs.length; i++) {
      timelineWidgets.add(const TimelineDivider());
      timelineWidgets.add(
        BusLegSection(leg: option.busLegs[i], formatTime: formatTime),
      );

      // 3. Jokaisen bussimatkan JÄLKEEN tapahtuva asia:

      // Tarkistetaan ensin, jatkuuko matka SUORAAN samalla bussilla
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
      }
      // Jos ei pysytä bussissa, katsotaan onko normaalia kävelyä (vaihto tai loppukävely)
      else if (i + 1 < option.walkDistances.length) {
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
                    'Perillä klo ${formatTime(option.arrivalTime)}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      color: kPrimaryDark,
                    ),
                  ),
                ],
              ),
              if (allAlerts.isNotEmpty) ...[
                const SizedBox(height: 10),
                Container(
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
                      for (final alert in allAlerts) ...[
                        const SizedBox(height: 4),
                        Text(
                          alert.text,
                          style: TextStyle(
                            color: Colors.grey[800],
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
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
  const BusLegSection({super.key, required this.leg, required this.formatTime});

  @override
  State<BusLegSection> createState() => _BusLegSectionState();
}

class _BusLegSectionState extends State<BusLegSection> {
  bool _showStops = false;

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
                    if (hasIntermediateStops) ...[
                      const Spacer(),
                      GestureDetector(
                        onTap: () => setState(() => _showStops = !_showStops),
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
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    if (isCanceled)
                      const Text(
                        'PERUTTU',
                        style: TextStyle(
                          color: kDelayed,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      )
                    else if (hasDelay) ...[
                      Text(
                        widget.formatTime(leg.departureTime),
                        style: const TextStyle(
                          decoration: TextDecoration.lineThrough,
                          color: Colors.grey,
                          fontSize: 12,
                        ),
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
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
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
                    ] else
                      Text(
                        widget.formatTime(leg.departureTime),
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
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
                Row(
                  children: [
                    Text(
                      widget.formatTime(leg.arrivalTime),
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
          if (hasIntermediateStops && _showStops)
            Container(
              margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.65),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                children: [
                  for (int i = 0; i < leg.intermediateStops.length; i++)
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
                            decoration: BoxDecoration(
                              color: kBus.withValues(alpha: 0.45),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              leg.intermediateStops[i].name,
                              style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xFF333333),
                              ),
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
