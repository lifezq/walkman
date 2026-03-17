import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'settings_store.dart';

typedef AsyncVoidCallback = Future<void> Function();

class SettingsPage extends StatefulWidget {
  final AsyncVoidCallback? onScanLocalMusic;
  final AsyncVoidCallback? onUpload;
  const SettingsPage({super.key, this.onScanLocalMusic, this.onUpload});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final store = context.read<SettingsStore>();
      await store.load();
      setState(() {
        _loading = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.onScanLocalMusic != null || widget.onUpload != null) ...[
                    const Text('本地操作', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (widget.onScanLocalMusic != null)
                          FilledButton.tonalIcon(
                            onPressed: () => widget.onScanLocalMusic!.call(),
                            icon: const Icon(Icons.library_music),
                            label: const Text('扫描本地音乐'),
                          ),
                        if (widget.onUpload != null)
                          FilledButton.icon(
                            onPressed: () => widget.onUpload!.call(),
                            icon: const Icon(Icons.upload_file),
                            label: const Text('上传'),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
    );
  }
}
