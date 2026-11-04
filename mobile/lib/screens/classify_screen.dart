import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/auth_provider.dart';
import '../widgets/async_view.dart';

class ClassifyScreen extends StatefulWidget {
  const ClassifyScreen({super.key, this.imageProvider});

  /// Overrides photo picking (e.g. a canned file in widget tests).
  final Future<XFile?> Function(ImageSource)? imageProvider;

  @override
  State<ClassifyScreen> createState() => _ClassifyScreenState();
}

class _ClassifyScreenState extends State<ClassifyScreen> {
  final _description = TextEditingController();
  Uint8List? _imageBytes;
  bool _busy = false;
  ClassifyResult? _result;

  @override
  void dispose() {
    _description.dispose();
    super.dispose();
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final provider = widget.imageProvider;
      final picked = provider != null
          ? await provider(source)
          : await ImagePicker().pickImage(source: source, maxWidth: 1600);
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      if (bytes.lengthInBytes > 5 * 1024 * 1024) {
        if (mounted) showError(context, 'Image is larger than 5 MB');
        return;
      }
      if (mounted) setState(() => _imageBytes = bytes);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _ask() async {
    final description = _description.text.trim();
    if (description.isEmpty && _imageBytes == null) return;
    setState(() {
      _busy = true;
      _result = null;
    });
    try {
      final result = await context.read<AuthProvider>().ai.classify(
            description: description.isEmpty ? null : description,
            imageBase64:
                _imageBytes == null ? null : base64Encode(_imageBytes!),
          );
      if (mounted) setState(() => _result = result);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final canAsk =
        !_busy && (_description.text.trim().isNotEmpty || _imageBytes != null);
    return Scaffold(
      appBar: AppBar(title: const Text('Classify waste')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Describe the item or attach a photo and the assistant will suggest a category.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _description,
                    maxLines: 3,
                    maxLength: 2000,
                    decoration: const InputDecoration(
                      labelText: 'e.g. old phone battery',
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 12),
                  if (_imageBytes != null) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.memory(_imageBytes!,
                          height: 180, fit: BoxFit.cover),
                    ),
                    TextButton.icon(
                      onPressed: () => setState(() => _imageBytes = null),
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Remove photo'),
                    ),
                  ] else
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => _pickImage(ImageSource.gallery),
                            icon: const Icon(Icons.photo_library_outlined),
                            label: const Text('Gallery'),
                          ),
                        ),
                        if (!kIsWeb) ...[
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => _pickImage(ImageSource.camera),
                              icon: const Icon(Icons.photo_camera_outlined),
                              label: const Text('Camera'),
                            ),
                          ),
                        ],
                      ],
                    ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: canAsk ? _ask : null,
                    child: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Ask'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (_busy)
            const Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: EdgeInsets.all(8),
                child: LoadingView(label: 'Asking assistant…'),
              ),
            )
          else if (result != null)
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
                          child: Text('Suggestion',
                              style: Theme.of(context).textTheme.titleMedium),
                        ),
                        Text(
                          '${(result.confidence * 100).round()}% confident',
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final t in result.suggestedTypes)
                          Chip(label: Text(pretty(t))),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(result.message),
                    if (result.placeholder)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.info_outline,
                              size: 16,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Placeholder answer — the AI agent is not wired up yet.',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                    ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            )
          else
            const EmptyState(
              icon: Icons.psychology_outlined,
              title: 'No suggestion yet',
              subtitle: 'Describe an item or attach a photo, then tap Ask.',
            ),
        ],
      ),
    );
  }
}
