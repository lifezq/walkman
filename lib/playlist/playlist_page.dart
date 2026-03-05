import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:audio_service/audio_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../player/player_controller.dart';
import 'playlist_store.dart';

class PlaylistPage extends StatelessWidget {
  const PlaylistPage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<PlaylistStore>();
    return Column(
      children: [
        Row(
          children: [
            FilledButton.icon(
              onPressed: () => _create(context),
              icon: const Icon(Icons.add),
              label: const Text('新建歌单'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView.separated(
            itemCount: store.playlists.length + 1,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              if (index == 0) {
                return ListTile(
                  leading: const Icon(Icons.history),
                  title: const Text('最近播放'),
                  subtitle: Text('${store.recent.length} 首'),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RecentDetailPage())),
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) {
                      if (v == 'clear') context.read<PlaylistStore>().clearRecent();
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(value: 'clear', child: Text('清空最近播放')),
                    ],
                  ),
                );
              }
              final p = store.playlists[index - 1];
              return ListTile(
                title: Text(p.name),
                subtitle: Text('${p.items.length} 首'),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlaylistDetailPage(playlistId: p.id))),
                trailing: PopupMenuButton<String>(
                  onSelected: (v) {
                    if (v == 'rename') _rename(context, p.id, p.name);
                    if (v == 'delete') _delete(context, p.id);
                    if (v == 'play') _playAll(context, p.id);
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(value: 'play', child: Text('播放全部')),
                    const PopupMenuItem(value: 'rename', child: Text('重命名')),
                    const PopupMenuItem(value: 'delete', child: Text('删除')),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _create(BuildContext context) async {
    final controller = TextEditingController(text: '新歌单');
    final name = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('新建歌单'),
        content: TextField(controller: controller, decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('确定')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    await context.read<PlaylistStore>().create(name);
  }

  Future<void> _rename(BuildContext context, String id, String old) async {
    final controller = TextEditingController(text: old);
    final name = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('重命名歌单'),
        content: TextField(controller: controller, decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('确定')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    await context.read<PlaylistStore>().rename(id, name);
  }

  Future<void> _delete(BuildContext context, String id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('删除歌单'),
        content: const Text('删除后无法恢复，确认删除？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok == true) {
      await context.read<PlaylistStore>().delete(id);
    }
  }

  Future<void> _playAll(BuildContext context, String id) async {
    final store = context.read<PlaylistStore>();
    final p = store.playlists.firstWhere((e) => e.id == id);
    final uris = p.items.map((e) => Uri.parse(e.uri)).toList();
    final titles = p.items.map((e) => e.title).toList();
    await context.read<PlayerController>().setPlaylistFromUris(uris, titles: titles);
    await context.read<PlayerController>().play();
  }
}

class PlaylistDetailPage extends StatefulWidget {
  final String playlistId;
  final String? highlightUri;
  const PlaylistDetailPage({super.key, required this.playlistId, this.highlightUri});

  @override
  State<PlaylistDetailPage> createState() => _PlaylistDetailPageState();
}

class _PlaylistDetailPageState extends State<PlaylistDetailPage> {
  final Set<int> _selected = {};
  final Map<int, GlobalKey> _keys = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.highlightUri == null) return;
      final store = context.read<PlaylistStore>();
      final p = store.playlists.firstWhere((e) => e.id == widget.playlistId);
      final idx = p.items.indexWhere((e) => e.uri == widget.highlightUri);
      if (idx >= 0) {
        final key = _keys[idx];
        if (key != null && key.currentContext != null) {
          Scrollable.ensureVisible(key.currentContext!, duration: const Duration(milliseconds: 300));
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<PlaylistStore>();
    final p = store.playlists.firstWhere((e) => e.id == widget.playlistId);
    return Scaffold(
      appBar: AppBar(
        title: Text(p.name),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'titleAsc' || v == 'titleDesc' || v == 'artistAsc' || v == 'artistDesc' || v == 'durationAsc' || v == 'durationDesc') {
                await context.read<PlaylistStore>().sortItems(p.id, v);
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'titleAsc', child: Text('标题 ↑')),
              PopupMenuItem(value: 'titleDesc', child: Text('标题 ↓')),
              PopupMenuItem(value: 'artistAsc', child: Text('歌手 ↑')),
              PopupMenuItem(value: 'artistDesc', child: Text('歌手 ↓')),
              PopupMenuItem(value: 'durationAsc', child: Text('时长 ↑')),
              PopupMenuItem(value: 'durationDesc', child: Text('时长 ↓')),
            ],
          ),
          if (_selected.isNotEmpty)
            TextButton(
              onPressed: () => _removeSelected(context),
              child: const Text('删除所选'),
            ),
          if (_selected.isNotEmpty)
            TextButton(
              onPressed: () => _addSelectedToOtherPlaylists(context, p),
              child: const Text('添加到其他歌单'),
            ),
        ],
      ),
      body: Column(
        children: [
          Row(
            children: [
              FilledButton(
                onPressed: () => _play(context, 0),
                child: const Text('播放全部'),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => setState(() {
                  _selected
                    ..clear()
                    ..addAll(List<int>.generate(p.items.length, (i) => i));
                }),
                child: const Text('全选'),
              ),
              TextButton(
                onPressed: () => setState(() => _selected.clear()),
                child: const Text('清空'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ReorderableListView.builder(
              itemCount: p.items.length,
              onReorder: (oldIndex, newIndex) => context.read<PlaylistStore>().reorderItems(p.id, oldIndex, newIndex),
              itemBuilder: (context, index) {
                final item = p.items[index];
                return ListTile(
                  key: _keys.putIfAbsent(index, () => GlobalKey()),
                  selected: _selected.contains(index),
                  onLongPress: () => setState(() {
                    if (_selected.contains(index)) {
                      _selected.remove(index);
                    } else {
                      _selected.add(index);
                    }
                  }),
                  onTap: () => _play(context, index),
                  leading: _thumb(item),
                  title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(_subtitle(item), maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: const Icon(Icons.drag_handle),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _addSelectedToOtherPlaylists(BuildContext context, Playlist p) async {
    final names = await _choosePlaylistNames(context);
    if (names.isEmpty) return;
    final items = _selected.map((i) => p.items[i]).map((it) => PlaylistItem(uri: it.uri, title: it.title, artist: it.artist, artPath: it.artPath, durationMs: it.durationMs)).toList();
    final store = context.read<PlaylistStore>();
    for (final n in names) {
      await store.addOrCreate(n, items);
    }
  }

  Future<void> _removeSelected(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('删除歌曲'),
        content: Text('将从歌单中移除 ${_selected.length} 首，确定吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    await context.read<PlaylistStore>().removeItems(widget.playlistId, _selected);
    if (mounted) setState(() => _selected.clear());
  }

  Future<void> _play(BuildContext context, int startIndex) async {
    final store = context.read<PlaylistStore>();
    final p = store.playlists.firstWhere((e) => e.id == widget.playlistId);
    final uris = p.items.map((e) => Uri.parse(e.uri)).toList();
    final titles = p.items.map((e) => e.title).toList();
    await context.read<PlayerController>().setPlaylistFromUris(uris, titles: titles, startIndex: startIndex);
    await context.read<PlayerController>().play();
  }

  Widget _thumb(PlaylistItem item) {
    if (item.artPath != null && item.artPath!.isNotEmpty) {
      final f = File(item.artPath!);
      if (f.existsSync()) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Image.file(
            f,
            width: 40,
            height: 40,
            fit: BoxFit.cover,
          ),
        );
      }
    }
    return const _PlaceholderArt();
  }

  String _subtitle(PlaylistItem item) {
    final parts = <String>[];
    parts.add(item.artist ?? '本地文件');
    if (item.durationMs != null && item.durationMs! > 0) {
      final d = Duration(milliseconds: item.durationMs!);
      parts.add(_fmt(d));
    }
    return parts.join(' · ');
  }
}

String _fmt(Duration d) {
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  final h = d.inHours;
  if (h > 0) {
    return '${h.toString().padLeft(2, '0')}:$m:$s';
  }
  return '$m:$s';
}

class _PlaceholderArt extends StatelessWidget {
  const _PlaceholderArt();
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        color: Theme.of(context).colorScheme.surfaceVariant,
      ),
      child: const Icon(Icons.music_note),
    );
  }
}

Future<List<String>> _choosePlaylistNames(BuildContext context) async {
  final store = context.read<PlaylistStore>();
  final prefs = await SharedPreferences.getInstance();
  final lastList = prefs.getStringList('recent_playlist_names') ?? [];
  final names = store.playlists.map((e) => e.name).toList();
  final recent = lastList.where((n) => names.contains(n)).toList();
  final other = names.where((n) => !recent.contains(n)).toList();
  final ordered = [...recent, ...other];
  final selected = <String>{...recent};
  final controller = TextEditingController();
  return showDialog<List<String>>(
    context: context,
    builder: (_) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('添加到歌单（可多选）'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (ordered.isNotEmpty)
              SizedBox(
                height: 200,
                width: double.maxFinite,
                child: ListView.builder(
                  itemCount: ordered.length,
                  itemBuilder: (context, index) {
                    final n = ordered[index];
                    return CheckboxListTile(
                      value: selected.contains(n),
                      title: Text(n),
                      onChanged: (v) => setState(() {
                        if (v == true) {
                          selected.add(n);
                        } else {
                          selected.remove(n);
                        }
                      }),
                    );
                  },
                ),
              ),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                hintText: '或输入新歌单名称',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await prefs.remove('recent_playlist_names');
              if (context.mounted) Navigator.pop(context, <String>[]);
            },
            child: const Text('清空最近'),
          ),
          TextButton(onPressed: () => Navigator.pop(context, <String>[]), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              final newName = controller.text.trim();
              if (newName.isNotEmpty) selected.add(newName);
              final list = selected.toList();
              await prefs.setStringList('recent_playlist_names', list);
              if (context.mounted) Navigator.pop(context, list);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    ),
  ).then((value) => value ?? <String>[]);
}

class RecentDetailPage extends StatefulWidget {
  const RecentDetailPage({super.key});
  @override
  State<RecentDetailPage> createState() => _RecentDetailPageState();
}

class _RecentDetailPageState extends State<RecentDetailPage> {
  final Set<int> _selected = {};
  Widget _thumb(PlaylistItem item) {
    if (item.artPath != null && item.artPath!.isNotEmpty) {
      final f = File(item.artPath!);
      if (f.existsSync()) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Image.file(
            f,
            width: 40,
            height: 40,
            fit: BoxFit.cover,
          ),
        );
      }
    }
    return const _PlaceholderArt();
  }

  String _subtitle(PlaylistItem item) {
    final parts = <String>[];
    parts.add(item.artist ?? '本地文件');
    if (item.durationMs != null && item.durationMs! > 0) {
      final d = Duration(milliseconds: item.durationMs!);
      parts.add(_fmt(d));
    }
    return parts.join(' · ');
  }
  @override
  Widget build(BuildContext context) {
    final store = context.watch<PlaylistStore>();
    final items = store.recent;
    return Scaffold(
      appBar: AppBar(
        title: const Text('最近播放'),
        actions: [
          if (_selected.isNotEmpty)
            TextButton(
              onPressed: () async {
                await context.read<PlaylistStore>().removeRecent(_selected);
                if (mounted) setState(() => _selected.clear());
              },
              child: const Text('删除所选'),
            ),
          TextButton(
            onPressed: () async => context.read<PlaylistStore>().clearRecent(),
            child: const Text('清空'),
          ),
        ],
      ),
      body: ListView.separated(
        itemCount: items.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final item = items[index];
          return ListTile(
            selected: _selected.contains(index),
            onLongPress: () => setState(() {
              if (_selected.contains(index)) {
                _selected.remove(index);
              } else {
                _selected.add(index);
              }
            }),
            onTap: () async {
              final uris = items.map((e) => Uri.parse(e.uri)).toList();
              final titles = items.map((e) => e.title).toList();
              await context.read<PlayerController>().setPlaylistFromUris(uris, titles: titles, startIndex: index);
              await context.read<PlayerController>().play();
            },
            leading: _thumb(item),
            title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(_subtitle(item), maxLines: 1, overflow: TextOverflow.ellipsis),
          );
        },
      ),
    );
  }
}
