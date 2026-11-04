import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/auth_provider.dart';
import '../utils/dates.dart';
import '../widgets/async_view.dart';
import '../widgets/cards.dart';
import '../widgets/type_dots.dart';
import '../widgets/geo_map.dart';

class PostDetailScreen extends StatefulWidget {
  const PostDetailScreen({super.key, required this.postId, this.tileProvider});

  final String postId;

  /// Overrides map tile loading (offline stub in widget tests).
  final TileProvider? tileProvider;

  @override
  State<PostDetailScreen> createState() => _PostDetailScreenState();
}

class _PostDetailScreenState extends State<PostDetailScreen> {
  int _reload = 0;
  bool _busy = false;

  Future<void> _confirm() async {
    setState(() => _busy = true);
    try {
      await context
          .read<AuthProvider>()
          .garbage
          .confirmCollected(widget.postId);
      if (mounted) {
        showOk(context, 'Marked as collected');
        setState(() => _reload++);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _dispute() async {
    setState(() => _busy = true);
    try {
      await context
          .read<AuthProvider>()
          .garbage
          .disputeCollected(widget.postId);
      if (mounted) {
        showOk(context, 'Collection disputed');
        setState(() => _reload++);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    return Scaffold(
      appBar: AppBar(title: const Text('Report')),
      body: FutureBuilder(
        key: ValueKey(_reload),
        future: auth.garbage.getPost(widget.postId),
        builder: (context, snapshot) => AsyncView<GarbagePost>(
          snapshot: snapshot,
          onRetry: () => setState(() => _reload++),
          builder: (context, post) => ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  post.types.map(pretty).join(', '),
                                  style: Theme.of(context).textTheme.titleLarge,
                                ),
                                const SizedBox(height: 4),
                                TypeDots(post.types, size: 12),
                              ],
                            ),
                          ),
                          StatusPill(
                            label: pretty(post.status),
                            status: post.status,
                          ),
                        ],
                      ),
                      if (post.hasImage)
                        const ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: CardIcon(icon: Icons.image_outlined),
                          title: Text('Photo attached'),
                        ),
                      const SizedBox(height: 8),
                      InfoRow(label: 'Position', value: post.location.short),
                      if (post.district != null &&
                          post.district!.trim().isNotEmpty)
                        InfoRow(
                            label: 'District', value: post.district!.trim()),
                      if (post.description != null &&
                          post.description!.isNotEmpty)
                        InfoRow(label: 'Notes', value: post.description!),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _PickupTimeline(
                post: post,
                busy: _busy,
                onConfirm: _confirm,
                onDispute: _dispute,
              ),
              const SizedBox(height: 12),
              GarbageMapView(
                markers: [MapMarkerData(point: post.location)],
                tileProvider: widget.tileProvider,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _StepState { done, current, upcoming }

class _TimelineStep {
  const _TimelineStep({
    required this.title,
    this.subtitle,
    required this.state,
  });

  final String title;
  final String? subtitle;
  final _StepState state;
}

/// Pickup journey for a post: reported → scheduled → picked up → confirmed.
///
/// Assignment data (truck, route, day) enriches the scheduled step when the
/// post is on a route; without it (still loading, forbidden, or 404) the
/// timeline degrades to plain status-driven steps. Only a
/// collector-swept (pending) post can be confirmed or disputed; posted and
/// scheduled have nothing to confirm yet and collected is final.
class _PickupTimeline extends StatelessWidget {
  const _PickupTimeline({
    required this.post,
    required this.busy,
    required this.onConfirm,
    required this.onDispute,
  });

  final GarbagePost post;
  final bool busy;
  final VoidCallback onConfirm;
  final VoidCallback onDispute;

  List<_TimelineStep> _steps(CollectionAssignment? assignment) {
    final status = post.status;
    final scheduledDone = status == 'scheduled' ||
        status == 'pending_confirmation' ||
        status == 'collected';
    final pickedDone = post.collectedAt != null || status == 'collected';
    final confirmedDone = status == 'collected';
    // The run started but this post isn't swept yet: pickup is underway.
    final rolling = assignment?.routeStatus == 'in_progress';
    return [
      _TimelineStep(
        title: 'Reported',
        subtitle: formatDay(post.createdAt.toLocal()),
        state: _StepState.done,
      ),
      _TimelineStep(
        title: 'Scheduled',
        subtitle: _scheduledDetail(scheduledDone, assignment),
        state: scheduledDone ? _StepState.done : _StepState.current,
      ),
      _TimelineStep(
        title: 'Picked up',
        subtitle: pickedDone
            ? (post.collectedAt != null
                ? formatDay(post.collectedAt!.toLocal())
                : 'Collected')
            : (rolling && scheduledDone ? 'Collection underway' : null),
        state: pickedDone
            ? _StepState.done
            : (rolling && scheduledDone
                ? _StepState.current
                : _StepState.upcoming),
      ),
      _TimelineStep(
        title: 'Confirmed',
        subtitle: confirmedDone
            ? null
            : (status == 'pending_confirmation'
                ? 'Was it really collected?'
                : null),
        state: confirmedDone
            ? _StepState.done
            : (status == 'pending_confirmation'
                ? _StepState.current
                : _StepState.upcoming),
      ),
    ];
  }

  String _scheduledDetail(
      bool scheduledDone, CollectionAssignment? assignment) {
    if (!scheduledDone) return 'Not on a run yet';
    if (assignment == null) return 'On a run';
    return [
      if (assignment.scheduledFor != null) formatDay(assignment.scheduledFor!),
      assignment.routeName ?? assignment.routeId,
      'Truck ${assignment.plateNumber}',
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    return FutureBuilder(
      future: auth.garbage.getCollection(post.id),
      builder: (context, snapshot) {
        final steps = _steps(snapshot.data);
        return Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Pickup progress',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                for (var i = 0; i < steps.length; i++)
                  _TimelineRow(
                    last: i == steps.length - 1,
                    step: steps[i],
                    child: i == 3 && post.status == 'pending_confirmation'
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const SizedBox(height: 8),
                              FilledButton.icon(
                                onPressed: busy ? null : onConfirm,
                                icon: const Icon(Icons.check_circle_outline),
                                label: const Text('Confirm collected'),
                              ),
                              const SizedBox(height: 8),
                              OutlinedButton.icon(
                                onPressed: busy ? null : onDispute,
                                icon: const Icon(Icons.report_outlined),
                                label: const Text('Dispute collection'),
                              ),
                            ],
                          )
                        : null,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({
    required this.last,
    required this.step,
    this.child,
  });

  final bool last;
  final _TimelineStep step;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final done = step.state == _StepState.done;
    final current = step.state == _StepState.current;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Column(
            children: [
              Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: done ? scheme.primary : Colors.transparent,
                  border: done
                      ? null
                      : Border.all(
                          color:
                              current ? scheme.primary : scheme.outlineVariant,
                          width: 2,
                        ),
                ),
                child: done
                    ? Icon(Icons.check, size: 12, color: scheme.onPrimary)
                    : current
                        ? Center(
                            child: Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: scheme.primary,
                              ),
                            ),
                          )
                        : null,
              ),
              if (!last)
                Expanded(
                  child: Container(
                    width: 2,
                    color: done ? scheme.primary : scheme.outlineVariant,
                  ),
                ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: last ? 0 : 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    step.title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: step.state == _StepState.upcoming
                          ? scheme.onSurfaceVariant
                          : null,
                    ),
                  ),
                  if (step.subtitle != null)
                    Text(
                      step.subtitle!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  if (child != null) child!,
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
