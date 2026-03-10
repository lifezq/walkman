import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../player/player_controller.dart';

class LocalLibraryPage extends StatefulWidget {
  const LocalLibraryPage({super.key});
  @override
  State<LocalLibraryPage> createState() => _LocalLibraryPageState();
}

class _LocalLibraryPageState extends State<LocalLibraryPage> {
  List<FileSystemEntity> _files = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
    });
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/library');
      final exists = await dir.exists();
      if (exists) {
        final exts = ['.mp3', '.aac', '.m4a', '.wav', '.flac', '.ogg'];
        final list = await dir
            .list()
            .where((e) => e is File)
            .where((e) => exts.any((x) => e.path.toLowerCase().endsWith(x)))
            .toList();
        list.sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
        setState(() {
          _files = list;
        });
      } else {
        setState(() {
          _files = [];
        });
      }
    } catch (_) {
      setState(() {
        _files = [];
      });
    } finally {
      setState(() {
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('本地目录'),
        actions: [
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _files.isEmpty
              ? const Center(child: Text('暂无文件'))
              : ListView.separated(
                  itemCount: _files.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final f = _files[index] as File;
                    final name = f.uri.pathSegments.isNotEmpty ? f.uri.pathSegments.last : f.path;
                    return ListTile(
                      leading: const Icon(Icons.music_note),
                      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () async {
                        final uris = _files.cast<File>().map((e) => e.uri).toList();
                        final titles = _files.cast<File>().map((e) {
                          final n = e.uri.pathSegments.isNotEmpty ? e.uri.pathSegments.last : e.path;
                          return n;
                        }).toList();
                        await context.read<PlayerController>().setPlaylistFromUris(uris, titles: titles, startIndex: index);
                        await context.read<PlayerController>().play();
                      },
                      trailing: TextButton(
                        onPressed: () async {
                          if (!mounted) return;
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (_) => AlertDialog(
                              title: const Text('删除文件'),
                              content: Text('删除 $name ？'),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
                                FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
                              ],
                            ),
                          );
                          if (ok == true) {
                            try {
                              await f.delete();
                            } catch (_) {}
                            await _load();
                          }
                        },
                        child: const Text('删除'),
                      ),
                    );
                  },
                ),
    );
  }
}
