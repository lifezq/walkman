import 'dart:ui';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:audio_service/audio_service.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:on_audio_query/on_audio_query.dart';
import '../settings/settings_store.dart';
import '../player/player_controller.dart';
import 'play_mode.dart';

class FullPlayerPage extends StatelessWidget {
  static bool _openingOrOpened = false;
  const FullPlayerPage({super.key});

  static Future<void> open(BuildContext context) async {
    if (_openingOrOpened) return;
    _openingOrOpened = true;
    try {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const FullPlayerPage()),
      );
    } finally {
      _openingOrOpened = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final handler = context.watch<AudioHandler>();
    final controller = context.read<PlayerController>();
    return StreamBuilder<MediaItem?>(
      stream: handler.mediaItem,
      builder: (context, snapItem) {
        final item = snapItem.data;
        final artUri = item?.artUri;
        return Scaffold(
          appBar: AppBar(title: const Text('正在播放')),
          body: Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(child: _Background(artUri: artUri)),
              Positioned.fill(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                  child: Container(
                    color: Theme.of(context).colorScheme.surface.withOpacity(0.6),
                  ),
                ),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: SizedBox.expand(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                      Align(
                        alignment: Alignment.topCenter,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(height: 12),
                            Stack(
                              alignment: Alignment.center,
                              children: [
                                AspectRatio(
                                  aspectRatio: 1,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(16),
                                      color: Theme.of(context).colorScheme.surface,
                                    ),
                                    clipBehavior: Clip.antiAlias,
                                    child: _MainArtwork(item: item),
                                  ),
                                ),
                                SizedBox(
                                  width: double.infinity,
                                  height: 220,
                                  child: LyricsView(handler: handler, mediaItem: item, transparent: true),
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            Text(
                              item?.title ?? '未播放',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              item?.artist ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                            const SizedBox(height: 12),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                _LikeFavoriteBar(item: item),
                              ],
                            ),
                          ],
                        ),
                      ),
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _PositionBar(handler: handler, mediaItem: item),
                            const SizedBox(height: 8),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                IconButton(
                                  tooltip: '播放模式',
                                  onPressed: () => controller.cyclePlayMode(),
                                  icon: Selector<PlayerController, PlayMode>(
                                    selector: (_, c) => c.mode,
                                    builder: (_, mode, __) => Icon(_modeIcon(mode)),
                                  ),
                                ),
                                IconButton(
                                  iconSize: 36,
                                  icon: const Icon(Icons.skip_previous),
                                  onPressed: () => controller.previous(),
                                ),
                                StreamBuilder<PlaybackState>(
                                  stream: handler.playbackState,
                                  builder: (context, snap) {
                                    final playing = snap.data?.playing ?? false;
                                    return FilledButton(
                                      onPressed: () => playing ? controller.pause() : controller.play(),
                                      child: Icon(playing ? Icons.pause : Icons.play_arrow, size: 36),
                                    );
                                  },
                                ),
                                IconButton(
                                  iconSize: 36,
                                  icon: const Icon(Icons.skip_next),
                                  onPressed: () => controller.next(),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.queue_music),
                                  onPressed: () => _openQueue(context, handler),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                          ],
                        ),
                      ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Background extends StatelessWidget {
  final Uri? artUri;
  const _Background({required this.artUri});
  @override
  Widget build(BuildContext context) {
    if (artUri != null && (artUri!.scheme == 'file' || artUri!.scheme == 'http' || artUri!.scheme == 'https')) {
      final provider = _imageProviderFromUri(artUri!);
      return Image(
        image: provider,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _fallbackBg(context),
      );
    }
    return _fallbackBg(context);
  }

  Widget _fallbackBg(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            c.primary.withOpacity(0.25),
            c.secondary.withOpacity(0.25),
            c.surfaceContainerHighest.withOpacity(0.25),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
    );
  }
}

class _MainArtwork extends StatelessWidget {
  final MediaItem? item;
  const _MainArtwork({required this.item});
  @override
  Widget build(BuildContext context) {
    final artUri = item?.artUri;
    if (artUri != null && (artUri.scheme == 'file' || artUri.scheme == 'http' || artUri.scheme == 'https')) {
      return Image(
        image: _imageProviderFromUri(artUri),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _placeholder(context),
      );
    }
    final extras = item?.extras;
    if (Platform.isAndroid && extras != null && extras['songId'] != null) {
      final int songId = (extras['songId'] as num).toInt();
      return QueryArtworkWidget(
        id: songId,
        type: ArtworkType.AUDIO,
        nullArtworkWidget: _placeholder(context),
      );
    }
    return _placeholder(context);
  }

  Widget _placeholder(BuildContext context) {
    return Center(
      child: Icon(
        Icons.music_note,
        size: 96,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class _LikeFavoriteBar extends StatelessWidget {
  final MediaItem? item;
  const _LikeFavoriteBar({required this.item});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<PlayerController>();
    final ids = _ids();
    final liked = ids.$1 != null ? controller.isLiked(ids.$1!) : (ids.$2 != null ? controller.isLikedKey(ids.$2!) : false);
    final favorite = ids.$1 != null ? controller.isFavorite(ids.$1!) : (ids.$2 != null ? controller.isFavoriteKey(ids.$2!) : false);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          onPressed: () {
            final i = _ids();
            if (i.$1 != null) {
              controller.toggleLike(i.$1!);
            } else if (i.$2 != null) {
              controller.toggleLikeKey(i.$2!);
            }
          },
          icon: Icon(liked ? Icons.favorite : Icons.favorite_border, color: liked ? Colors.red : null),
          tooltip: '喜欢',
        ),
        const SizedBox(width: 12),
        IconButton(
          onPressed: () {
            final i = _ids();
            if (i.$1 != null) {
              controller.toggleFavorite(i.$1!);
            } else if (i.$2 != null) {
              controller.toggleFavoriteKey(i.$2!);
            }
          },
          icon: Icon(favorite ? Icons.bookmark : Icons.bookmark_border),
          tooltip: '收藏',
        ),
      ],
    );
  }

  (int?, String?) _ids() {
    final extras = item?.extras;
    if (extras != null && extras['songId'] != null) {
      return ((extras['songId'] as num).toInt(), null);
    }
    return (null, item?.id);
  }
}

class _PositionBar extends StatelessWidget {
  final AudioHandler handler;
  final MediaItem? mediaItem;
  const _PositionBar({required this.handler, required this.mediaItem});
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlaybackState>(
      stream: handler.playbackState,
      builder: (context, snap) {
        final state = snap.data;
        final pos = state?.updatePosition ?? Duration.zero;
        final dur = mediaItem?.duration ?? Duration.zero;
        return Column(
          children: [
            Slider(
              value: pos.inMilliseconds.clamp(0, dur.inMilliseconds).toDouble(),
              min: 0,
              max: dur.inMilliseconds > 0 ? dur.inMilliseconds.toDouble() : 1,
              onChanged: (v) => handler.seek(Duration(milliseconds: v.round())),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_fmt(pos), style: Theme.of(context).textTheme.labelSmall),
                Text(_fmt(dur), style: Theme.of(context).textTheme.labelSmall),
              ],
            ),
          ],
        );
      },
    );
  }
}

ImageProvider _imageProviderFromUri(Uri uri) {
  if (uri.scheme == 'file') {
    return FileImage(File(uri.toFilePath()));
  }
  return NetworkImage(uri.toString());
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

IconData _modeIcon(PlayMode m) {
  switch (m) {
    case PlayMode.sequence:
      return Icons.repeat;
    case PlayMode.shuffle:
      return Icons.shuffle;
    case PlayMode.single:
      return Icons.repeat_one;
  }
}

void _openQueue(BuildContext context, AudioHandler handler) {
  final selectedIds = <String>{};
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (context, setState) {
          return SafeArea(
            child: StreamBuilder<List<MediaItem>>(
              stream: handler.queue,
              builder: (context, snap) {
                final items = snap.data ?? const <MediaItem>[];
                if (items.isEmpty) {
                  return const SizedBox(height: 200, child: Center(child: Text('播放队列为空')));
                }
                selectedIds.removeWhere((id) => !items.any((it) => it.id == id));
                final controller = context.read<PlayerController>();
                final allSelected = selectedIds.length == items.length;
                return SizedBox(
                  height: MediaQuery.of(context).size.height * 0.7,
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        child: Row(
                          children: [
                            const Text('播放队列'),
                            const Spacer(),
                            if (selectedIds.isNotEmpty)
                              TextButton(
                                onPressed: () async {
                                  final idxs = <int>[];
                                  for (var i = 0; i < items.length; i++) {
                                    if (selectedIds.contains(items[i].id)) idxs.add(i);
                                  }
                                  idxs.sort((a, b) => b.compareTo(a));
                                  for (final i in idxs) {
                                    await controller.removeQueueIndex(i);
                                  }
                                  setState(() {
                                    selectedIds.clear();
                                  });
                                },
                                child: const Text('删除所选'),
                              ),
                            TextButton(
                              onPressed: () {
                                if (allSelected) {
                                  setState(() {
                                    selectedIds.clear();
                                  });
                                } else {
                                  setState(() {
                                    selectedIds
                                      ..clear()
                                      ..addAll(items.map((e) => e.id));
                                  });
                                }
                              },
                              child: Text(allSelected ? '清空' : '全选'),
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      Expanded(
                        child: ReorderableListView.builder(
                          itemCount: items.length,
                          onReorder: (oldIndex, newIndex) async {
                            await controller.reorderQueue(oldIndex, newIndex);
                          },
                          itemBuilder: (context, index) {
                            final it = items[index];
                            final isSel = selectedIds.contains(it.id);
                            return ListTile(
                              key: ValueKey(it.id),
                              leading: Checkbox(
                                value: isSel,
                                onChanged: (v) {
                                  setState(() {
                                    if (v == true) {
                                      selectedIds.add(it.id);
                                    } else {
                                      selectedIds.remove(it.id);
                                    }
                                  });
                                },
                              ),
                              title: Text(it.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text(it.artist ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
                              onTap: () {
                                setState(() {
                                  if (isSel) {
                                    selectedIds.remove(it.id);
                                  } else {
                                    selectedIds.add(it.id);
                                  }
                                });
                              },
                              onLongPress: () {
                                setState(() {
                                  if (isSel) {
                                    selectedIds.remove(it.id);
                                  } else {
                                    selectedIds.add(it.id);
                                  }
                                });
                              },
                              trailing: IconButton(
                                icon: const Icon(Icons.play_arrow),
                                tooltip: '播放此项',
                                onPressed: () async {
                                  await handler.skipToQueueItem(index);
                                  if (context.mounted) Navigator.pop(context);
                                },
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          );
        },
      );
    },
  );
}

class LyricsView extends StatefulWidget {
  final AudioHandler handler;
  final MediaItem? mediaItem;
  final bool transparent;
  const LyricsView({super.key, required this.handler, required this.mediaItem, this.transparent = false});
  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView> {
  final _controller = ScrollController();
  List<_LrcLine> _lines = [];
  int _current = -1;

  @override
  void didUpdateWidget(covariant LyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mediaItem?.id != widget.mediaItem?.id) {
      _load();
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _lines = [];
      _current = -1;
    });
    final m = widget.mediaItem;
    if (m == null) return;
    final extrasLyrics = m.extras != null ? m.extras!['lyrics'] as String? : null;
    if (extrasLyrics != null && extrasLyrics.trim().isNotEmpty) {
      setState(() {
        _lines = _parseLrc(extrasLyrics);
      });
      return;
    }
    try {
      final uri = Uri.tryParse(m.id);
      if (uri != null && uri.isScheme('file')) {
        final audioPath = uri.toFilePath();
        final base = audioPath.replaceAll(RegExp(r'\\'), '/');
        final dot = base.lastIndexOf('.');
        final lrcPath = '${dot > 0 ? base.substring(0, dot) : base}.lrc';
        final file = File(lrcPath);
        if (await file.exists()) {
          final text = await file.readAsString();
          final lines = _parseLrc(text);
          setState(() {
            _lines = lines;
          });
          return;
        }
      }
    } catch (_) {}
    try {
      final store = context.read<SettingsStore>();
      final ep = store.lyricsEndpoint;
      if (ep != null && ep.isNotEmpty) {
        final url = ep
            .replaceAll('{title}', Uri.encodeComponent(m.title))
            .replaceAll('{artist}', Uri.encodeComponent(m.artist ?? ''));
        final res = await http.get(Uri.parse(url));
        if (res.statusCode >= 200 && res.statusCode < 300) {
          final text = res.body;
          final lines = _parseLrc(text);
          if (lines.isNotEmpty) {
            setState(() {
              _lines = lines;
            });
          }
        }
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (_lines.isEmpty) {
      return Container(
        alignment: Alignment.center,
        decoration: widget.transparent
            ? null
            : BoxDecoration(
                color: Theme.of(context).colorScheme.surface.withOpacity(0.6),
                borderRadius: BorderRadius.circular(12),
              ),
        child: const Text('暂无歌词'),
      );
    }
    return StreamBuilder<PlaybackState>(
      stream: widget.handler.playbackState,
      builder: (context, snap) {
        final pos = snap.data?.updatePosition ?? Duration.zero;
        final idx = _locateIndex(pos);
        if (idx != _current && idx >= 0) {
          _current = idx;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!_controller.hasClients) return;
            final target = (idx * 44.0) - 44.0 * 2;
            _controller.animateTo(target.clamp(0, _controller.position.maxScrollExtent), duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
          });
        }
        return Container(
          decoration: widget.transparent
              ? null
              : BoxDecoration(
                  color: Theme.of(context).colorScheme.surface.withOpacity(0.6),
                  borderRadius: BorderRadius.circular(12),
                ),
          child: ListView.builder(
            controller: _controller,
            padding: const EdgeInsets.symmetric(vertical: 12),
            itemExtent: 44,
            itemCount: _lines.length,
            itemBuilder: (context, i) {
              final line = _lines[i];
              final active = i == _current;
              final base = Theme.of(context).textTheme.bodyMedium;
              final activeStyle = Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.white);
              final normalStyle = base?.copyWith(color: (base.color ?? Colors.white).withOpacity(0.7));
              return Center(
                child: Text(
                  line.text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: active ? activeStyle : normalStyle,
                ),
              );
            },
          ),
        );
      },
    );
  }

  int _locateIndex(Duration pos) {
    final ms = pos.inMilliseconds;
    var lo = 0;
    var hi = _lines.length - 1;
    var ans = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (_lines[mid].timeMs <= ms) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }

  List<_LrcLine> _parseLrc(String text) {
    final lines = <_LrcLine>[];
    final reg = RegExp(r'\[(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?\]');
    for (final raw in text.split('\n')) {
      final matches = reg.allMatches(raw);
      if (matches.isEmpty) continue;
      final content = raw.replaceAll(reg, '').trim();
      for (final m in matches) {
        final mm = int.tryParse(m.group(1) ?? '0') ?? 0;
        final ss = int.tryParse(m.group(2) ?? '0') ?? 0;
        final xx = int.tryParse((m.group(3) ?? '0').padRight(3, '0')) ?? 0;
        final timeMs = (mm * 60 + ss) * 1000 + xx;
        lines.add(_LrcLine(timeMs: timeMs, text: content));
      }
    }
    lines.sort((a, b) => a.timeMs.compareTo(b.timeMs));
    return lines;
  }
}

class _LrcLine {
  final int timeMs;
  final String text;
  _LrcLine({required this.timeMs, required this.text});
}
