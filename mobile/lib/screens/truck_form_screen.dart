import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/auth_provider.dart';
import '../widgets/async_view.dart';
import '../widgets/inputs.dart';

/// Create/edit form for trucks (logistics/admin), mirroring the facility
/// form. Operator binding is 1:1: picking a collector already assigned to
/// another truck fails with the server's 409 detail.
class TruckFormScreen extends StatefulWidget {
  const TruckFormScreen({super.key, this.existing});

  final Truck? existing;

  @override
  State<TruckFormScreen> createState() => _TruckFormScreenState();
}

class _TruckFormScreenState extends State<TruckFormScreen> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _plate;
  late final TextEditingController _capacity;
  late String _status;
  final _types = <String>{};
  String? _operatorId;
  bool _busy = false;
  late Future<List<User>> _collectors;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _plate = TextEditingController(text: existing?.plateNumber ?? '');
    _capacity = TextEditingController(
      text: existing?.capacity == null ? '' : '${existing!.capacity}',
    );
    _status = existing?.status ?? truckStatuses.first;
    if (!_statusIsKnown(_status)) _status = truckStatuses.first;
    if (existing != null) {
      _types.addAll(existing.garbageTypes);
      _operatorId = existing.operatorId;
    }
    _collectors = context.read<AuthProvider>().auth.listUsers(role: 'collector');
  }

  void _reloadCollectors() => setState(() {
        _collectors =
            context.read<AuthProvider>().auth.listUsers(role: 'collector');
      });

  bool _statusIsKnown(String status) => truckStatuses.contains(status);

  @override
  void dispose() {
    _plate.dispose();
    _capacity.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate() || _types.isEmpty) {
      if (_types.isEmpty) {
        showError(context, 'Pick at least one garbage type');
      }
      return;
    }
    final capacityText = _capacity.text.trim();
    int? capacity;
    if (capacityText.isNotEmpty) {
      capacity = int.tryParse(capacityText);
      if (capacity == null || capacity < 1) {
        showError(context, 'Capacity must be a positive number');
        return;
      }
    }
    setState(() => _busy = true);
    try {
      final api = context.read<AuthProvider>().trucks;
      final existing = widget.existing;
      if (existing == null) {
        final created = await api.createSchedule(
          plateNumber: _plate.text.trim(),
          garbageTypes: _types.toList(),
          status: _status,
          capacity: capacity,
        );
        // The create endpoint takes no operator; bind one right after when
        // the picker selected a collector.
        if (_operatorId != null) {
          await api.updateTruck(
            created.id,
            operatorId: _operatorId,
            operatorIdSet: true,
          );
        }
      } else {
        await api.updateTruck(
          existing.id,
          plateNumber: _plate.text.trim(),
          capacity: capacity,
          garbageTypes: _types.toList(),
          status: _status,
          operatorId: _operatorId,
          // Always send so clearing the picker unassigns (explicit null).
          operatorIdSet: true,
        );
      }
      if (mounted) {
        showOk(context, existing == null ? 'Truck registered' : 'Truck updated');
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.existing != null;
    return Scaffold(
      appBar: AppBar(title: Text(editing ? 'Edit truck' : 'New truck')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Details', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _plate,
                      decoration: const InputDecoration(labelText: 'Plate number'),
                      validator: (v) => v != null && v.trim().isNotEmpty
                          ? null
                          : 'Plate number is required',
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _capacity,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Capacity (optional)',
                      ),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: _status,
                      decoration: const InputDecoration(labelText: 'Status'),
                      items: [
                        for (final status in truckStatuses)
                          DropdownMenuItem(
                            value: status,
                            child: Text(pretty(status)),
                          ),
                      ],
                      onChanged: (v) => v == null ? null : setState(() => _status = v),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Garbage types',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    GarbageTypePicker(
                      selected: _types,
                      onChanged: (next) => setState(() => _types
                        ..clear()
                        ..addAll(next)),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Assigned operator',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    FutureBuilder(
                      future: _collectors,
                      builder: (context, snapshot) => AsyncView<List<User>>(
                        snapshot: snapshot,
                        onRetry: _reloadCollectors,
                        builder: (context, users) {
                          final collectors = users
                              .where((u) => u.role == 'collector')
                              .toList();
                          final ids = {
                            for (final c in collectors) c.id,
                          };
                          // Keep a pre-selected operator visible even if the
                          // listing no longer includes them.
                          final selected = _operatorId;
                          return DropdownButtonFormField<String?>(
                            key: ValueKey(selected),
                            initialValue: selected,
                            decoration: const InputDecoration(
                              labelText: 'Operator',
                            ),
                            items: [
                              const DropdownMenuItem<String?>(
                                value: null,
                                child: Text('Unassigned'),
                              ),
                              for (final collector in collectors)
                                DropdownMenuItem<String?>(
                                  value: collector.id,
                                  child: Text(
                                    '${collector.displayName} · ${collector.email}',
                                  ),
                                ),
                              if (selected != null && !ids.contains(selected))
                                DropdownMenuItem<String?>(
                                  value: selected,
                                  child: Text('Assigned · $selected'),
                                ),
                            ],
                            onChanged: (v) => setState(() => _operatorId = v),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(
                      width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(editing ? 'Save changes' : 'Register truck'),
            ),
          ],
        ),
      ),
    );
  }
}
