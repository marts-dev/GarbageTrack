import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/auth_provider.dart';
import '../utils/dates.dart';
import '../widgets/async_view.dart';
import '../widgets/cards.dart';
import '../widgets/type_dots.dart';

/// Resident pickup calendar: scheduled and ongoing pickups grouped by day.
///
/// Active routes only (assigned/in_progress) — finished pickups live under
/// My reports. The month grid marks days that have pickups; tapping a day
/// lists what is collected, by which truck, on which route.
class PickupCalendarScreen extends StatefulWidget {
  const PickupCalendarScreen({super.key});

  @override
  State<PickupCalendarScreen> createState() => _PickupCalendarScreenState();
}

class _PickupCalendarScreenState extends State<PickupCalendarScreen> {
  late Future<List<ScheduledPickup>> _pickups;
  late DateTime _month;
  late DateTime _selected;

  @override
  void initState() {
    super.initState();
    final today = todayDay();
    _month = DateTime(today.year, today.month);
    _selected = today;
    _pickups = context.read<AuthProvider>().garbage.getMyPickups();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pickup calendar')),
      body: FutureBuilder(
        future: _pickups,
        builder: (context, snapshot) => AsyncView<List<ScheduledPickup>>(
          snapshot: snapshot,
          onRetry: () => setState(
            () => _pickups =
                context.read<AuthProvider>().garbage.getMyPickups(),
          ),
          builder: (context, pickups) {
            final byDay = <DateTime, List<ScheduledPickup>>{};
            for (final pickup in pickups) {
              final day = pickup.scheduledFor;
              (byDay[DateTime(day.year, day.month, day.day)] ??= [])
                  .add(pickup);
            }
            final todaysPickups = byDay[_selected] ?? const [];
            return Column(
              children: [
                _MonthNavigator(
                  month: _month,
                  onPrevious: () => setState(() =>
                      _month = DateTime(_month.year, _month.month - 1)),
                  onNext: () => setState(
                      () => _month = DateTime(_month.year, _month.month + 1)),
                ),
                _MonthGrid(
                  month: _month,
                  pickupsByDay: byDay,
                  selected: _selected,
                  onSelect: (day) => setState(() => _selected = day),
                ),
                const Divider(height: 1),
                Expanded(
                  child: todaysPickups.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              'No pickups on ${formatDay(_selected)}.',
                              style: Theme.of(context).textTheme.bodyMedium,
                              textAlign: TextAlign.center,
                            ),
                          ),
                        )
                      : ListView(
                          padding: const EdgeInsets.all(16),
                          children: [
                            Text(
                              formatDay(_selected),
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 8),
                            for (final pickup in todaysPickups)
                              Card(
                                child: ListTile(
                                  leading: TypeDots(pickup.types),
                                  title: Text(pickup.types
                                      .map(pretty)
                                      .join(', ')),
                                  subtitle: Text(
                                    [
                                      pickup.routeName ?? pickup.routeId,
                                      pickup.plateNumber,
                                      if (pickup.district != null)
                                        pickup.district!,
                                    ].join(' · '),
                                  ),
                                  trailing: StatusPill(
                                    label: pretty(pickup.routeStatus),
                                    status: pickup.routeStatus,
                                  ),
                                ),
                              ),
                          ],
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _MonthNavigator extends StatelessWidget {
  const _MonthNavigator({
    required this.month,
    required this.onPrevious,
    required this.onNext,
  });

  final DateTime month;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Previous month',
            icon: const Icon(Icons.chevron_left),
            onPressed: onPrevious,
          ),
          Expanded(
            child: Text(
              formatMonthYear(month),
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
          ),
          IconButton(
            tooltip: 'Next month',
            icon: const Icon(Icons.chevron_right),
            onPressed: onNext,
          ),
        ],
      ),
    );
  }
}

class _MonthGrid extends StatelessWidget {
  const _MonthGrid({
    required this.month,
    required this.pickupsByDay,
    required this.selected,
    required this.onSelect,
  });

  final DateTime month;
  final Map<DateTime, List<ScheduledPickup>> pickupsByDay;
  final DateTime selected;
  final ValueChanged<DateTime> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    // Sunday-start column of the 1st: Monday=1..Sunday=7 -> 1..0 blanks.
    final leadingBlanks = DateTime(month.year, month.month).weekday % 7;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              for (final label in weekdayLabels)
                Expanded(
                  child: Center(
                    child: Text(
                      label,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          // Fixed-height cells: the grid must fit above the day list on
          // small screens, so cells never size from their width.
          GridView.count(
            crossAxisCount: 7,
            mainAxisExtent: 48,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 2,
            children: [
              for (var i = 0; i < leadingBlanks; i++)
                const SizedBox.shrink(),
              for (var day = 1; day <= daysInMonth; day++)
                _DayCell(
                  day: DateTime(month.year, month.month, day),
                  pickups:
                      pickupsByDay[DateTime(month.year, month.month, day)] ??
                          const [],
                  selected: sameDay(
                      DateTime(month.year, month.month, day), selected),
                  onSelect: onSelect,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.pickups,
    required this.selected,
    required this.onSelect,
  });

  final DateTime day;
  final List<ScheduledPickup> pickups;
  final bool selected;
  final ValueChanged<DateTime> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isToday = sameDay(day, todayDay());
    // Primary when anything is already rolling, tertiary when everything
    // is still scheduled.
    final dotColor =
        pickups.any((p) => p.routeStatus == 'in_progress')
            ? scheme.primary
            : scheme.tertiary;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => onSelect(day),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 4),
        decoration: selected
            ? BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              )
            : isToday
                ? BoxDecoration(
                    border: Border.all(color: scheme.primary),
                    borderRadius: BorderRadius.circular(8),
                  )
                : null,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${day.day}',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight:
                        selected || isToday ? FontWeight.bold : null,
                  ),
            ),
            // Fixed-height dot lane keeps every row aligned.
            SizedBox(
              height: 10,
              child: pickups.isEmpty
                  ? null
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (var i = 0;
                            i < pickups.length && i < 3;
                            i++)
                          Container(
                            width: 6,
                            height: 6,
                            margin: const EdgeInsets.symmetric(horizontal: 1),
                            decoration: BoxDecoration(
                              color: dotColor,
                              shape: BoxShape.circle,
                            ),
                          ),
                        if (pickups.length > 3)
                          Text(
                            '+${pickups.length - 3}',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(fontSize: 9),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
