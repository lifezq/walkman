import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'settings_store.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _ctl = TextEditingController();
  final _lyricsCtl = TextEditingController();
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final store = context.read<SettingsStore>();
      await store.load();
      _ctl.text = store.endpoint ?? '';
      _lyricsCtl.text = store.lyricsEndpoint ?? '';
      setState(() {
        _loading = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<SettingsStore>();
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('上传服务器地址', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _ctl,
                    decoration: const InputDecoration(hintText: '例如：https://example.com/upload', border: OutlineInputBorder(), isDense: true),
                  ),
                  const SizedBox(height: 12),
                  const Text('歌词接口地址', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _lyricsCtl,
                    decoration: const InputDecoration(hintText: '例如：https://example.com/lyrics?title={title}&artist={artist}', border: OutlineInputBorder(), isDense: true),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      FilledButton(
                        onPressed: () async {
                          await store.setEndpoint(_ctl.text.trim());
                          await store.setLyricsEndpoint(_lyricsCtl.text.trim());
                          if (!mounted) return;
                          Navigator.pop(context);
                        },
                        child: const Text('保存'),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () {
                          _ctl.text = '';
                          _lyricsCtl.text = '';
                        },
                        child: const Text('清空'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text('上传：${store.endpoint ?? '未设置'}'),
                  const SizedBox(height: 4),
                  Text('歌词：${store.lyricsEndpoint ?? '未设置'}'),
                ],
              ),
            ),
    );
  }
}
