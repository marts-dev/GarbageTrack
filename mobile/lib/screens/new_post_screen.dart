import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/auth_provider.dart';
import '../utils/country_viewports.dart';
import '../widgets/async_view.dart';
import '../widgets/inputs.dart';
import '../widgets/location_picker.dart';

class NewPostScreen extends StatefulWidget {
  const NewPostScreen({super.key, this.tileProvider});

  /// Overrides tile loading (e.g. an offline stub in widget tests).
  final TileProvider? tileProvider;

  @override
  State<NewPostScreen> createState() => _NewPostScreenState();
}

class _NewPostScreenState extends State<NewPostScreen> {
  final _description = TextEditingController();
  final _district = TextEditingController();
  final _types = <String>{};
  GeoPoint? _point;
  Uint8List? _imageBytes;
  String? _imageMime;
  bool _busy = false;

  @override
  void dispose() {
    _description.dispose();
    _district.dispose();
    super.dispose();
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final picked = await ImagePicker().pickImage(source: source, maxWidth: 1600);
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      if (bytes.lengthInBytes > 5 * 1024 * 1024) {
        if (mounted) showError(context, 'Image is larger than 5 MB');
        return;
      }
      setState(() {
        _imageBytes = bytes;
        _imageMime = picked.mimeType ?? 'image/jpeg';
      });
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _submit() async {
    final point = _point;
    if (point == null || _types.isEmpty) return;
    final auth = context.read<AuthProvider>();
    if (auth.user?.isResident != true) {
      if (mounted) showError(context, 'Only residents can report garbage');
      return;
    }
    setState(() => _busy = true);
    try {
      await auth.garbage.createPost(
        userId: auth.user!.id,
        longitude: point.longitude,
        latitude: point.latitude,
        types: _types.toList(),
        description: _description.text.trim().isEmpty ? null : _description.text.trim(),
        district: _district.text.trim().isEmpty ? null : _district.text.trim(),
        imageBase64: _imageBytes == null ? null : base64Encode(_imageBytes!),
        imageContentType: _imageBytes == null ? null : _imageMime,
      );
      if (mounted) {
        showOk(context, 'Report submitted');
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
    final auth = context.watch<AuthProvider>();
    if (auth.user?.isResident != true) {
      return Scaffold(
        appBar: AppBar(title: const Text('Report garbage')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(32),
            child: Text('Only residents can report garbage.'),
          ),
        ),
      );
    }
    final viewport = viewportFor(auth.country);
    final canSubmit = _point != null && _types.isNotEmpty && !_busy;
    return Scaffold(
      appBar: AppBar(title: const Text('Report garbage')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Where is it?', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  LocationMapPicker(
                    onChanged: (point) => setState(() => _point = point),
                    fallbackCenter: viewport.center,
                    fallbackZoom: viewport.zoom,
                    tileProvider: widget.tileProvider,
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
                  Text('What kind of waste?',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  GarbageTypePicker(
                      selected: _types,
                      onChanged: (next) => setState(() => _types
                        ..clear()
                        ..addAll(next))),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _district,
                    maxLength: 120,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'District / region (optional)',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _description,
                    maxLines: 3,
                    maxLength: 2000,
                    decoration: const InputDecoration(
                      labelText: 'Description (optional)',
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          if (_imageBytes != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.memory(_imageBytes!, height: 180, fit: BoxFit.cover),
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
          const SizedBox(height: 16),
          FilledButton(
            onPressed: canSubmit ? _submit : null,
            child: _busy
                ? const SizedBox(
                    width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Submit report'),
          ),
        ],
      ),
    );
  }
}
