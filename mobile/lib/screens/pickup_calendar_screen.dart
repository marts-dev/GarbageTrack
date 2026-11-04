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
  const PickupCalendarScreen({super.key, this.initialDay});

  /// Day to select on open (e.g. from the home strip). Defaults to today.
  final DateTime? initialDay;

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
    final anchor = widget.initialDay ?? todayDay();
    _month = DateTime(anchor.year, anchor.month);
    _selected = DateTime(anchor.year, anchor.month, anchor.day);
    _pickups = context.read<AuthProvider>().garbage.getMyPickups();
  }

  /// Pull-to-refresh: swaps in a completed future so the grid never
  /// flashes the loading state. Failures toast and keep the old data.
  Future<void> _refresh() async {
    try {
      final fresh = await context.read<AuthProvider>().garbage.getMyPickups();
      if (!mounted) return;
      setState(() => _pickups = Future.value(fresh));
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  void _jumpToToday() {
    final today = todayDay();
    setState(() {
      _month = DateTime(today.year, today.month);
      _selected = today;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pickup calendar'),
        actions: [
          IconButton(
            tooltip: 'Jump to today',
            icon: const Icon(Icons.today),
            onPressed: _jumpToToday,
          ),
        ],
      ),
      body: FutureBuilder(
        future: _pickups,
        builder: (context, snapshot) => AsyncView<List<ScheduledPickup>>(
          snapshot: snapshot,
          onRetry: () => setState(
            () =>
                _pickups = context.read<AuthProvider>().garbage.getMyPickups(),
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
                  onPrevious: () => setState(
                      () => _month = DateTime(_month.year, _month.month - 1)),
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
                      ? RefreshableEmpty(
                          onRefresh: _refresh,
                          empty: Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(
                                'No pickups on ${formatDay(_selected)}.',
                                style: Theme.of(context).textTheme.bodyMedium,
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ),
                        )
                      : RefreshIndicator(
                          onRefresh: _refresh,
                          child: ListView(
                            physics: const AlwaysScrollableScrollPhysics(),
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
                                    title: Text(
                                        pickup.types.map(pretty).join(', ')),
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
              for (var i = 0; i < leadingBlanks; i++) const SizedBox.shrink(),
              for (var day = 1; day <= daysInMonth; day++)
                _DayCell(
                  day: DateTime(month.year, month.month, day),
                  pickups:
                      pickupsByDay[DateTime(month.year, month.month, day)] ??
                          const [],
                  selected:
                      sameDay(DateTime(month.year, month.month, day), selected),
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
    // Past days dim but stay tappable: overdue in-progress pickups still
    // list here.
    final past = isPastDay(day);
    // Primary when anything is already rolling, tertiary when everything
    // is still scheduled.
    final badgeColor = (pickups.any((p) => p.routeStatus == 'in_progress')
            ? scheme.primary
            : scheme.tertiary)
        .withValues(alpha: past ? 0.5 : 1);
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
                    fontWeight: selected || isToday ? FontWeight.bold : null,
                    color: past
                        ? scheme.onSurfaceVariant.withValues(alpha: 0.55)
                        : null,
                  ),
            ),
            // Fixed-height badge lane keeps every row aligned.
            SizedBox(
              height: 16,
              child: pickups.isEmpty
                  ? null
                  : Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: badgeColor,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '${pickups.length}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
