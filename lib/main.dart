import 'dart:io';
import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:audio_service/audio_service.dart';
import 'package:metadata_god/metadata_god.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';

import 'player/player_controller.dart';
import 'player/audio_handler.dart';
import 'playlist/playlist_store.dart';
import 'playlist/playlist_page.dart';
import 'player/play_mode.dart';
import 'player/full_player_page.dart';
import 'settings/settings_store.dart';
import 'settings/settings_page.dart';

const MethodChannel _deviceInfoChannel = MethodChannel('walkman/device_info');
bool _metadataGodAvailable = false;

Future<List<String>> _getAndroidSupportedAbis() async {
  if (!Platform.isAndroid) return const <String>[];
  try {
    return await _deviceInfoChannel.invokeListMethod<String>('getSupportedAbis') ?? const <String>[];
  } catch (_) {
    return const <String>[];
  }
}

bool _hasSupportedMetadataGodAbi(List<String> abis) {
  if (abis.isEmpty) return true;
  return abis.any((abi) => abi.contains('arm64') || abi.contains('armeabi'));
}

Future<bool> _tryInitializeMetadataGod() async {
  if (Platform.isAndroid) {
    final abis = await _getAndroidSupportedAbis();
    if (!_hasSupportedMetadataGodAbi(abis)) {
      debugPrint('MetadataGod disabled on unsupported ABI: $abis');
      return false;
    }
  }
  try {
    await MetadataGod.initialize();
    return true;
  } catch (e) {
    debugPrint('MetadataGod init skipped: $e');
    return false;
  }
}

Future<dynamic> _readMetadataSafe(String filePath) async {
  if (!_metadataGodAvailable) return null;
  try {
    return await MetadataGod.readMetadata(file: filePath);
  } catch (e) {
    debugPrint('MetadataGod read failed, disabling metadata: $e');
    _metadataGodAvailable = false;
    return null;
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _metadataGodAvailable = await _tryInitializeMetadataGod();
  try {
    await JustAudioBackground.init(
      androidNotificationChannelId: 'com.lifezq.walkman.channel.audio',
      androidNotificationChannelName: '音频播放',
      androidNotificationOngoing: true,
    );
  } catch (_) {}
  AudioHandler audioHandler;
  try {
    audioHandler = await AudioService.init(
      builder: () => MyAudioHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.lifezq.walkman.channel.audio',
        androidNotificationChannelName: '音频播放',
        androidNotificationOngoing: true,
      ),
    );
  } catch (_) {
    audioHandler = MyAudioHandler();
  }
  runApp(WalkmanApp(audioHandler: audioHandler));
}

class WalkmanApp extends StatelessWidget {
  final AudioHandler audioHandler;
  const WalkmanApp({super.key, required this.audioHandler});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<AudioHandler>.value(value: audioHandler),
        ChangeNotifierProvider(create: (_) => PlayerController(audioHandler as MyAudioHandler)),
        ChangeNotifierProvider(create: (_) => PlaylistStore()..load()),
        ChangeNotifierProvider(create: (_) => SettingsStore()..load()),
      ],
      child: MaterialApp(
        title: 'Walkman',
        theme: ThemeData(useMaterial3: true),
        builder: (context, child) => NowPlayingListener(child: child!),
        home: const RootPage(),
      ),
    );
  }
}

class RootPage extends StatelessWidget {
  const RootPage({super.key});
  @override
  Widget build(BuildContext context) {
    return const DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: TabBar(
          tabs: [
            Tab(text: '库', icon: Icon(Icons.library_music)),
            Tab(text: '歌单', icon: Icon(Icons.queue_music)),
          ],
        ),
        body: TabBarView(
          children: [
            HomePage(),
            PlaylistPage(),
          ],
        ),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final OnAudioQuery _audioQuery = OnAudioQuery();
  List<SongModel> _songs = [];
  List<_PickedAudio> _picked = [];
  bool _loading = true;
  final Set<String> _selected = {};
  String _query = '';
  bool _onlyLiked = false;
  bool _onlyFavorite = false;
  _SortMode _sortMode = _SortMode.titleAsc;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _init();
      }
    });
  }

  Future<void> _init() async {
    if (Platform.isAndroid) {
      try {
        final ok = await _audioQuery.permissionsStatus();
        if (!ok) {
          await _audioQuery.permissionsRequest();
        }
      } catch (_) {}
    }
    List<SongModel> songs = [];
    if (Platform.isAndroid) {
      songs = await _audioQuery.querySongs(
        sortType: SongSortType.DATE_ADDED,
        orderType: OrderType.DESC_OR_GREATER,
        uriType: UriType.EXTERNAL,
        ignoreCase: true,
      );
    } else {
      await _loadImportedList();
    }
    final prefs = await SharedPreferences.getInstance();
    final likes = prefs.getStringList('likes')?.toSet() ?? <String>{};
    final favorites = prefs.getStringList('favorites')?.toSet() ?? <String>{};
    if (!mounted) return;
    final controller = context.read<PlayerController>();
    controller.loadStates(likes, favorites);
    await controller.initPlayMode();
    setState(() {
      _songs = songs;
      _loading = false;
    });
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: ['mp3', 'aac', 'm4a', 'wav', 'flac', 'ogg'],
    );
    if (result == null) return;
    final files = result.files.where((f) => f.path != null).toList();
    final temp = await getTemporaryDirectory();
    final list = <_PickedAudio>[];
    for (final f in files) {
      Uri? artUri;
      String? artist;
      Duration? duration;
      try {
        final meta = await _readMetadataSafe(f.path!);
        if (meta != null) {
          artist = meta.artist;
          if (meta.durationMs != null) {
            final ms = meta.durationMs!;
            final int intMs = ms is int ? ms : (ms as num).round();
            duration = Duration(milliseconds: intMs);
          }
          if (meta.picture != null && meta.picture!.data.isNotEmpty) {
            final file = File('${temp.path}/art_${_safeName(f.path!)}.jpg');
            await file.writeAsBytes(meta.picture!.data);
            artUri = file.uri;
          }
        }
        if (artUri == null) {
          final url = await _searchArtworkUrl(f.name, artist);
          if (url != null) {
            final bytes = await _download(url);
            if (bytes != null) {
              final file = File('${temp.path}/art_${_safeName(f.path!)}.jpg');
              await file.writeAsBytes(bytes);
              artUri = file.uri;
            }
          }
        }
      } catch (_) {}
      list.add(_PickedAudio(
        uri: Uri.file(f.path!),
        title: f.name,
        artUri: artUri,
        artist: artist,
        duration: duration,
      ));
    }
    setState(() {
      _picked = list;
    });
    await _saveImportedList();
  }

  void _toggleSelectKey(String key) {
    setState(() {
      if (_selected.contains(key)) {
        _selected.remove(key);
      } else {
        _selected.add(key);
      }
    });
  }

  void _clearSelection() {
    setState(() {
      _selected.clear();
    });
  }

  void _selectAll() {
    setState(() {
      _selected.clear();
      if (Platform.isIOS) {
        _selected.addAll(_picked.map((e) => e.uri.toString()));
      } else {
        _selected.addAll(_songs.map((e) => e.id.toString()));
      }
    });
  }

  Future<void> _batchLike(PlayerController player, bool value) async {
    if (Platform.isIOS) {
      final keys = _selected;
      if (value) {
        await player.likeKeys(keys);
      } else {
        await player.unlikeKeys(keys);
      }
    } else {
      final ids = _selected.map((k) => int.tryParse(k)).whereType<int>();
      if (value) {
        await player.likeIds(ids);
      } else {
        await player.unlikeIds(ids);
      }
    }
    _clearSelection();
  }

  Future<void> _batchFavorite(PlayerController player, bool value) async {
    if (Platform.isIOS) {
      final keys = _selected;
      if (value) {
        await player.favoriteKeys(keys);
      } else {
        await player.unfavoriteKeys(keys);
      }
    } else {
      final ids = _selected.map((k) => int.tryParse(k)).whereType<int>();
      if (value) {
        await player.favoriteIds(ids);
      } else {
        await player.unfavoriteIds(ids);
      }
    }
    _clearSelection();
  }

  Future<void> _playSelection(PlayerController player) async {
    if (_selected.isEmpty) return;
    if (Platform.isIOS) {
      final selectedSet = _selected.toSet();
      final list = _picked.where((e) => selectedSet.contains(e.uri.toString())).toList();
      final uris = list.map((e) => e.uri).toList();
      final titles = list.map((e) => e.title).toList();
      await player.setPlaylistFromUris(uris, titles: titles);
    } else {
      final ids = _selected.map((k) => int.tryParse(k)).whereType<int>().toSet();
      final items = _songs.where((s) => ids.contains(s.id)).toList();
      await player.setPlaylist(items);
    }
    await player.play();
    _clearSelection();
  }

  Future<void> _addSingleSongToPlaylist(BuildContext context, SongModel s) async {
    final store = context.read<PlaylistStore>();
    final names = await _choosePlaylistNames(context, store);
    if (names.isEmpty) return;
    final entry = PlaylistItem(
      uri: s.uri!,
      title: s.title,
      artist: s.artist,
      durationMs: s.duration,
    );
    for (final n in names) {
      await store.addOrCreate(n, [entry]);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('last_playlist_names', names);
  }
  Future<void> _saveImportedList() async {
    final prefs = await SharedPreferences.getInstance();
    final data = _picked
        .map((e) => {
              'uri': e.uri.toString(),
              'title': e.title,
              'artist': e.artist,
              'durationMs': e.duration?.inMilliseconds,
              'artPath': e.artUri != null && e.artUri!.scheme == 'file' ? e.artUri!.toFilePath() : null,
            })
        .toList();
    await prefs.setString('imported_files', jsonEncode(data));
  }

  Future<void> _loadImportedList() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('imported_files');
    if (raw == null) return;
    try {
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      _picked = list
          .map((m) => _PickedAudio(
                uri: Uri.parse(m['uri'] as String),
                title: m['title'] as String,
                artist: m['artist'] as String?,
                duration: m['durationMs'] != null ? Duration(milliseconds: (m['durationMs'] as num).round()) : null,
                artUri: (m['artPath'] != null) ? File(m['artPath'] as String).uri : null,
              ))
          .toList();
    } catch (_) {}
  }

  Future<void> _deleteSelection() async {
    if (!Platform.isIOS || _selected.isEmpty) return;
    final keys = _selected.toSet();
    final toDelete = _picked.where((e) => keys.contains(e.uri.toString())).toList();
    for (final item in toDelete) {
      if (item.artUri != null && item.artUri!.scheme == 'file') {
        try {
          final f = File.fromUri(item.artUri!);
          if (await f.exists()) {
            await f.delete();
          }
        } catch (_) {}
      }
    }
    setState(() {
      _picked.removeWhere((e) => keys.contains(e.uri.toString()));
      _selected.clear();
    });
    await _saveImportedList();
  }

  Future<String?> _searchArtworkUrl(String title, String? artist) async {
    try {
      final term = Uri.encodeComponent([title, if (artist != null) artist].where((e) => e.isNotEmpty).join(' '));
      final url = 'https://itunes.apple.com/search?media=music&limit=1&term=$term';
      final res = await http.get(Uri.parse(url));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final results = data['results'] as List<dynamic>;
        if (results.isNotEmpty) {
          final art = results.first['artworkUrl100'] as String?;
          if (art != null) {
            return art.replaceAll('100x100bb', '512x512bb');
          }
        }
      }
    } catch (_) {}
    return null;
  }

  Future<List<int>?> _download(String url) async {
    try {
      final res = await http.get(Uri.parse(url));
      if (res.statusCode == 200) return res.bodyBytes;
    } catch (_) {}
    return null;
  }

  Future<void> _addSinglePickedToPlaylist(BuildContext context, _PickedAudio item) async {
    final store = context.read<PlaylistStore>();
    final names = await _choosePlaylistNames(context, store);
    if (names.isEmpty) return;
    final entries = [
      PlaylistItem(
        uri: item.uri.toString(),
        title: item.title,
        artist: item.artist,
        artPath: item.artUri != null && item.artUri!.scheme == 'file' ? item.artUri!.toFilePath() : null,
        durationMs: item.duration?.inMilliseconds,
      )
    ];
    for (final n in names) {
      await store.addOrCreate(n, entries);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('last_playlist_names', names);
  }

  Future<List<String>> _choosePlaylistNames(BuildContext context, PlaylistStore store) async {
    final prefs = await SharedPreferences.getInstance();
    final lastList = prefs.getStringList('last_playlist_names') ?? [];
    final names = store.playlists.map((e) => e.name).toList();
    final recent = lastList.where((n) => names.contains(n)).toList();
    final other = names.where((n) => !recent.contains(n)).toList();
    final ordered = [...recent, ...other];
    final selected = <String>{...recent};
    final controller = TextEditingController();
    if (!context.mounted) return <String>[];
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
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
            FilledButton(
              onPressed: () {
                final newName = controller.text.trim();
                if (newName.isNotEmpty) selected.add(newName);
                Navigator.pop(context, selected.toList());
              },
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    ).then((value) => value ?? <String>[]);
  }

  void _showPickedDetail(BuildContext context, _PickedAudio item) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('文件详情'),
        content: SelectableText([
          '标题：${item.title}',
          '歌手：${item.artist ?? '未知'}',
          if (item.duration != null) '时长：${_fmt(item.duration!)}',
          '路径：${item.uri.toFilePath()}',
        ].join('\n')),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭'))],
      ),
    );
  }

  Future<void> _openPickedFile(_PickedAudio item) async {
    if (item.uri.scheme == 'file') {
      await OpenFilex.open(item.uri.toFilePath());
    }
  }

  void _showSongDetail(BuildContext context, SongModel s) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('歌曲详情'),
        content: SelectableText([
          '标题：${s.title}',
          '歌手：${s.artist ?? '未知'}',
          if ((s.duration ?? 0) > 0) '时长：${_fmt(Duration(milliseconds: s.duration!))}',
          if (s.uri != null) 'URI：${s.uri}',
          'ID：${s.id}',
        ].join('\n')),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭'))],
      ),
    );
  }

  Future<void> _openAndroidSong(SongModel s) async {
    final uri = s.uri;
    if (uri == null) return;
    await OpenFilex.open(uri);
  }

  Future<void> _locateInPlaylistByUri(String uri) async {
    if (uri.isEmpty) return;
    final store = context.read<PlaylistStore>();
    final candidates = store.playlists.where((p) => p.items.any((it) => it.uri == uri)).toList();
    if (candidates.isEmpty) {
      if (!mounted) return;
      showDialog(context: context, builder: (_) => const AlertDialog(content: Text('未在任何歌单中找到'),));
      return;
    }
    final chosen = await showDialog<String>(
      context: context,
      builder: (_) => SimpleDialog(
        title: const Text('选择歌单'),
        children: [
          for (final p in candidates)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, p.id),
              child: Text(p.name),
            )
        ],
      ),
    );
    if (chosen == null) return;
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlaylistDetailPage(playlistId: chosen, highlightUri: uri)));
  }

  Future<void> _removeFromPlaylistsByUri(String uri) async {
    if (uri.isEmpty) return;
    final store = context.read<PlaylistStore>();
    final candidates = store.playlists.where((p) => p.items.any((it) => it.uri == uri)).toList();
    if (candidates.isEmpty) return;
    final selected = <String>{};
    final ids = await showDialog<List<String>>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('从歌单中移除'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final p in candidates)
                  CheckboxListTile(
                    value: selected.contains(p.id),
                    title: Text(p.name),
                    onChanged: (v) => setState(() {
                      if (v == true) {
                        selected.add(p.id);
                      } else {
                        selected.remove(p.id);
                      }
                    }),
                  )
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, <String>[]), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(context, selected.toList()), child: const Text('确定')),
          ],
        ),
      ),
    );
    if (ids == null || ids.isEmpty) return;
    for (final id in ids) {
      await store.removeByUris(id, {uri});
    }
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerController>();
    final handler = context.watch<AudioHandler>();
    final isIOS = Platform.isIOS;
    final List<_PickedAudio> iosList = isIOS
        ? _picked.where((e) {
            final matchesQuery = _query.isEmpty || e.title.toLowerCase().contains(_query.toLowerCase()) || (e.artist ?? '').toLowerCase().contains(_query.toLowerCase());
            final key = e.uri.toString();
            final likedOk = !_onlyLiked || player.isLikedKey(key);
            final favOk = !_onlyFavorite || player.isFavoriteKey(key);
            return matchesQuery && likedOk && favOk;
          }).toList()
        : <_PickedAudio>[];
    final List<SongModel> androidList = !isIOS
        ? _songs.where((s) {
            final matchesQuery = _query.isEmpty || s.title.toLowerCase().contains(_query.toLowerCase()) || (s.artist ?? '').toLowerCase().contains(_query.toLowerCase());
            final likedOk = !_onlyLiked || player.isLiked(s.id);
            final favOk = !_onlyFavorite || player.isFavorite(s.id);
            return matchesQuery && likedOk && favOk;
          }).toList()
        : <SongModel>[];
    _applySort(iosList, androidList);
    final List<_FolderSongsGroup> androidFolderGroups =
        !isIOS ? _groupSongsByFolder(androidList) : const <_FolderSongsGroup>[];
    final List<_FolderSongsGroup> androidRootFolderGroups =
        !isIOS ? _rootFolderGroups(androidFolderGroups) : const <_FolderSongsGroup>[];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Walkman'),
        actions: [
          IconButton(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => SettingsPage(
                    onScanLocalMusic: Platform.isAndroid ? _scanAndroid : null,
                    onUpload: _handleUploadTap,
                  ),
                ),
              );
            },
            icon: const Icon(Icons.settings),
            tooltip: '设置',
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (isIOS)
                  OutlinedButton(
                    onPressed: _pickFiles,
                    child: const Text('导入音频'),
                  ),
                if (isIOS)
                  OutlinedButton(
                    onPressed: _scanDirectory,
                    child: const Text('扫描文件夹'),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: '搜索标题或歌手',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('排序：', style: TextStyle(fontSize: 14)),
                const SizedBox(width: 4),
                DropdownButton<_SortMode>(
                  value: _sortMode,
                  onChanged: (m) => setState(() => _sortMode = m!),
                  underline: const SizedBox(),
                  items: const [
                    DropdownMenuItem(value: _SortMode.titleAsc, child: Text('标题 ↑')),
                    DropdownMenuItem(value: _SortMode.titleDesc, child: Text('标题 ↓')),
                    DropdownMenuItem(value: _SortMode.artistAsc, child: Text('歌手 ↑')),
                    DropdownMenuItem(value: _SortMode.artistDesc, child: Text('歌手 ↓')),
                    DropdownMenuItem(value: _SortMode.durationAsc, child: Text('时长 ↑')),
                    DropdownMenuItem(value: _SortMode.durationDesc, child: Text('时长 ↓')),
                  ],
                ),
                const Spacer(),
                FilterChip(
                  label: const Text('只看喜欢'),
                  selected: _onlyLiked,
                  onSelected: (v) => setState(() => _onlyLiked = v),
                ),
                const SizedBox(width: 8),
                FilterChip(
                  label: const Text('只看收藏'),
                  selected: _onlyFavorite,
                  onSelected: (v) => setState(() => _onlyFavorite = v),
                ),
              ],
            ),
            const SizedBox(height: 8),
            MiniPlayer(handler: handler),
            const SizedBox(height: 8),
            if (_selected.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text('已选 ${_selected.length} 项'),
                    OutlinedButton(
                      onPressed: _selectAll,
                      child: const Text('全选'),
                    ),
                    FilledButton.tonal(
                      onPressed: () => _batchLike(player, true),
                      child: const Text('喜欢'),
                    ),
                    FilledButton.tonal(
                      onPressed: () => _batchLike(player, false),
                      child: const Text('取消喜欢'),
                    ),
                    OutlinedButton(
                      onPressed: () => _batchFavorite(player, true),
                      child: const Text('收藏'),
                    ),
                    OutlinedButton(
                      onPressed: () => _batchFavorite(player, false),
                      child: const Text('取消收藏'),
                    ),
                    OutlinedButton(
                      onPressed: () => _addToPlaylist(context),
                      child: const Text('添加到歌单'),
                    ),
                    OutlinedButton(
                      onPressed: _batchSaveSelectedToLocal,
                      child: const Text('保存选中'),
                    ),
                    OutlinedButton(
                      onPressed: _batchUploadSelected,
                      child: const Text('上传选中'),
                    ),
                    FilledButton(
                      onPressed: () => _playSelection(player),
                      child: const Text('播放所选'),
                    ),
                    if (isIOS)
                      TextButton(
                        onPressed: _deleteSelection,
                        child: const Text('删除所选'),
                      ),
                    TextButton(
                      onPressed: _clearSelection,
                      child: const Text('清空'),
                    ),
                  ],
                ),
              ),
            if (_loading)
              const Expanded(
                child: Center(child: CircularProgressIndicator()),
              )
            else if (!isIOS && _songs.isEmpty)
              const Expanded(
                child: Center(
                  child: Text(
                    '未发现本地音乐文件',
                  ),
                ),
              )
            else if (isIOS && _picked.isEmpty)
              const Expanded(
                child: Center(
                  child: Text('请先导入音频文件'),
                ),
              )
            else
              Expanded(
                child: ListView.separated(
                  itemCount: isIOS ? iosList.length : androidRootFolderGroups.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    if (isIOS) {
                      final item = iosList[index];
                      final key = item.uri.toString();
                      final liked = player.isLikedKey(key);
                      final favorite = player.isFavoriteKey(key);
                      final artist = _displayArtist(item.artist);
                      return ListTile(
                        leading: GestureDetector(
                          onTap: () async {
                            final uris = iosList.map((e) => e.uri).toList();
                            final titles = iosList.map((e) => e.title).toList();
                            await player.setPlaylistFromUris(uris, titles: titles, startIndex: index);
                            await player.play();
                            if (!context.mounted) return;
                            FullPlayerPage.open(context);
                          },
                          child: _leadingArtForPicked(item),
                        ),
                        selected: _selected.contains(key),
                        onLongPress: () => _toggleSelectKey(key),
                        onTap: () {
                          if (_selected.isNotEmpty) {
                            _toggleSelectKey(key);
                          } else {
                            final uris = iosList.map((e) => e.uri).toList();
                            final titles = iosList.map((e) => e.title).toList();
                            player.setPlaylistFromUris(uris, titles: titles, startIndex: index);
                            player.play();
                          }
                        },
                        title: Text(item.title),
                        subtitle: Text([
                          if (artist.isNotEmpty) artist,
                          if (item.duration != null) _fmt(item.duration!)
                        ].join(' · ')),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              onPressed: () => player.toggleLikeKey(key),
                              icon: Icon(
                                liked ? Icons.favorite : Icons.favorite_border,
                                color: liked ? Colors.red : null,
                              ),
                            ),
                            IconButton(
                              onPressed: () => player.toggleFavoriteKey(key),
                              icon: Icon(
                                favorite ? Icons.bookmark : Icons.bookmark_border,
                              ),
                            ),
                            IconButton(
                              tooltip: '添加到歌单',
                              onPressed: () => _addSinglePickedToPlaylist(context, item),
                              icon: const Icon(Icons.playlist_add),
                            ),
                        PopupMenuButton<String>(
                          onSelected: (v) {
                            if (v == 'detail') _showPickedDetail(context, item);
                            if (v == 'open') _openPickedFile(item);
                          },
                          itemBuilder: (context) => const [
                            PopupMenuItem(value: 'detail', child: Text('查看详情')),
                            PopupMenuItem(value: 'open', child: Text('在文件中打开')),
                          ],
                        ),
                          ],
                        ),
                      );
                    } else {
                      final group = androidRootFolderGroups[index];
                      return ListTile(
                        leading: const Icon(Icons.folder),
                        title: Text(group.name),
                        subtitle: Text('${group.songs.length} 首歌曲'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => _AndroidFolderSongsPage(
                                currentPath: group.path,
                                allGroups: androidFolderGroups,
                                onAddSingleSongToPlaylist: _addSingleSongToPlaylist,
                                onShowSongDetail: _showSongDetail,
                                onOpenAndroidSong: _openAndroidSong,
                                onLocateInPlaylistByUri: _locateInPlaylistByUri,
                                onRemoveFromPlaylistsByUri: _removeFromPlaylistsByUri,
                                onSaveAndroidSongToLocal: _saveAndroidSongToLocal,
                              ),
                            ),
                          );
                        },
                      );
                    }
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<_FolderSongsGroup> _groupSongsByFolder(List<SongModel> songs) {
    final byFolder = <String, List<SongModel>>{};
    for (final song in songs) {
      final folderPath = _folderPathOfSong(song);
      byFolder.putIfAbsent(folderPath, () => <SongModel>[]).add(song);
    }
    final groups = byFolder.entries
        .map((e) => _FolderSongsGroup(
              path: e.key,
              name: _folderNameFromPath(e.key),
              songs: e.value,
            ))
        .toList();
    groups.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return groups;
  }

  List<_FolderSongsGroup> _rootFolderGroups(List<_FolderSongsGroup> groups) {
    final paths = groups.map((e) => e.path).toSet();
    final roots = groups.where((g) => !paths.contains(_parentFolderPath(g.path))).toList();
    roots.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return roots;
  }

  String _folderPathOfSong(SongModel song) {
    final raw = song.data;
    if (raw.isEmpty) return 'Unknown folder';
    final normalized = raw.replaceAll('\\', '/');
    final idx = normalized.lastIndexOf('/');
    if (idx <= 0) return normalized;
    return normalized.substring(0, idx);
  }

  void _applySort(List<_PickedAudio> iosList, List<SongModel> androidList) {
    int cmpStr(String a, String b) => a.toLowerCase().compareTo(b.toLowerCase());
    switch (_sortMode) {
      case _SortMode.titleAsc:
        iosList.sort((a, b) => cmpStr(a.title, b.title));
        androidList.sort((a, b) => cmpStr(a.title, b.title));
        break;
      case _SortMode.titleDesc:
        iosList.sort((a, b) => cmpStr(b.title, a.title));
        androidList.sort((a, b) => cmpStr(b.title, a.title));
        break;
      case _SortMode.artistAsc:
        iosList.sort((a, b) => cmpStr(a.artist ?? '', b.artist ?? ''));
        androidList.sort((a, b) => cmpStr(a.artist ?? '', b.artist ?? ''));
        break;
      case _SortMode.artistDesc:
        iosList.sort((a, b) => cmpStr(b.artist ?? '', a.artist ?? ''));
        androidList.sort((a, b) => cmpStr(b.artist ?? '', a.artist ?? ''));
        break;
      case _SortMode.durationAsc:
        iosList.sort((a, b) => (a.duration?.inMilliseconds ?? 0).compareTo(b.duration?.inMilliseconds ?? 0));
        androidList.sort((a, b) => (a.duration ?? 0).compareTo(b.duration ?? 0));
        break;
      case _SortMode.durationDesc:
        iosList.sort((a, b) => (b.duration?.inMilliseconds ?? 0).compareTo(a.duration?.inMilliseconds ?? 0));
        androidList.sort((a, b) => (b.duration ?? 0).compareTo(a.duration ?? 0));
        break;
    }
  }

  Future<void> _addToPlaylist(BuildContext context) async {
    final store = context.read<PlaylistStore>();
    final names = await _choosePlaylistNames(context, store);
    if (names.isEmpty) return;
    final items = <PlaylistItem>[];
    if (Platform.isIOS) {
      final set = _selected.toSet();
      final list = _picked.where((e) => set.contains(e.uri.toString())).toList();
      for (final it in list) {
        items.add(PlaylistItem(
          uri: it.uri.toString(),
          title: it.title,
          artist: it.artist,
          artPath: it.artUri != null && it.artUri!.scheme == 'file' ? it.artUri!.toFilePath() : null,
          durationMs: it.duration?.inMilliseconds,
        ));
      }
    } else {
      final ids = _selected.map((k) => int.tryParse(k)).whereType<int>().toSet();
      final list = _songs.where((s) => ids.contains(s.id)).toList();
      for (final s in list) {
        items.add(PlaylistItem(
          uri: s.uri!,
          title: s.title,
          artist: s.artist,
          durationMs: s.duration,
        ));
      }
    }
    for (final n in names) {
      await store.addOrCreate(n, items);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('last_playlist_names', names);
    _clearSelection();
  }

  Future<void> _scanAndroid() async {
    try {
      final ok = await _audioQuery.permissionsStatus();
      if (!ok) {
        await _audioQuery.permissionsRequest();
      }
      final songs = await _audioQuery.querySongs(
        sortType: SongSortType.DATE_ADDED,
        orderType: OrderType.DESC_OR_GREATER,
        uriType: UriType.EXTERNAL,
        ignoreCase: true,
      );
      setState(() {
        _songs = songs;
      });
    } catch (_) {}
  }

  Future<void> _scanDirectory() async {
    final dir = await FilePicker.platform.getDirectoryPath();
    if (dir == null) return;
    final exts = ['.mp3', '.aac', '.m4a', '.wav', '.flac', '.ogg'];
    final list = <_PickedAudio>[];
    try {
      final temp = await getTemporaryDirectory();
      final d = Directory(dir);
      await for (final ent in d.list(recursive: true, followLinks: false)) {
        if (ent is File) {
          final name = ent.uri.pathSegments.isNotEmpty ? ent.uri.pathSegments.last : ent.path;
          final lower = name.toLowerCase();
          if (!exts.any((e) => lower.endsWith(e))) continue;
      Uri? artUri;
      String? artist;
          Duration? duration;
          try {
            final meta = await _readMetadataSafe(ent.path);
            if (meta != null) {
              artist = meta.artist;
              if (meta.durationMs != null) {
                final ms = meta.durationMs!;
                final int intMs = ms is int ? ms : (ms as num).round();
                duration = Duration(milliseconds: intMs);
              }
              if (meta.picture != null && meta.picture!.data.isNotEmpty) {
                final file = File('${temp.path}/art_${_safeName(ent.path)}.jpg');
                await file.writeAsBytes(meta.picture!.data);
                artUri = file.uri;
              }
            }
          } catch (_) {}
          list.add(_PickedAudio(uri: ent.uri, title: name, artUri: artUri, artist: artist, duration: duration));
        }
      }
    } catch (_) {}
    if (list.isEmpty) return;
    setState(() {
      _picked = list;
    });
    await _saveImportedList();
  }

  Future<void> _saveAndroidSongToLocal(SongModel s) async {
    final playlistStore = context.read<PlaylistStore>();
    final path = s.data;
    if (path.isEmpty) return;
    final file = File(path);
    if (!await file.exists()) return;
    try {
      final dst = await _copyToLibrary(file);
      final item = PlaylistItem(
        uri: dst.uri.toString(),
        title: s.title,
        artist: s.artist,
        durationMs: s.duration,
      );
      await playlistStore.addOrCreate('本地库', [item]);
      if (!mounted) return;
      showDialog(context: context, builder: (_) => const AlertDialog(content: Text('已保存至“本地库”歌单')));
    } catch (_) {
      if (!mounted) return;
      showDialog(context: context, builder: (_) => const AlertDialog(content: Text('保存失败')));
    }
  }

  Future<bool> _uploadFileCore(File file, {required String endpoint, required String filename, String? title, String? artist}) async {
    try {
      final uri = Uri.parse(endpoint);
      final req = http.MultipartRequest('POST', uri);
      req.files.add(await http.MultipartFile.fromPath('file', file.path, filename: filename));
      if (title != null) req.fields['title'] = title;
      if (artist != null) req.fields['artist'] = artist;
      final res = await req.send();
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  Future<void> _batchUploadSelected() async {
    final store = context.read<SettingsStore>();
    final ep = store.endpoint;
    if (ep == null || ep.isEmpty) {
      if (!mounted) return;
      showDialog(context: context, builder: (_) => const AlertDialog(content: Text('请先在设置中配置上传服务器地址')));
      return;
    }
    final items = <Map<String, dynamic>>[];
    if (Platform.isIOS) {
      final keys = _selected.toSet();
      for (final it in _picked.where((e) => keys.contains(e.uri.toString()))) {
        if (it.uri.scheme != 'file') continue;
        final file = File(it.uri.toFilePath());
        if (await file.exists()) {
          items.add({'file': file, 'filename': file.path.split('/').last, 'title': it.title, 'artist': it.artist});
        }
      }
    } else {
      final ids = _selected.map((k) => int.tryParse(k)).whereType<int>().toSet();
      for (final s in _songs.where((e) => ids.contains(e.id))) {
        final path = s.data;
        if (path.isEmpty) continue;
        final file = File(path);
        if (await file.exists()) {
          items.add({'file': file, 'filename': path.split('/').last, 'title': s.title, 'artist': s.artist});
        }
      }
    }
    if (items.isEmpty) {
      if (!mounted) return;
      showDialog(context: context, builder: (_) => const AlertDialog(content: Text('没有可上传的文件')));
      return;
    }
    await _runBatchUploadDialog(items, ep);
  }

  Future<void> _runBatchUploadDialog(List<Map<String, dynamic>> items, String endpoint) async {
    int index = 0;
    int success = 0;
    int failed = 0;
    final failedItems = <Map<String, dynamic>>[];
    bool running = true;
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setState) {
          Future.microtask(() async {
            if (!running) return;
            for (; index < items.length; index++) {
              final it = items[index];
              final file = it['file'] as File;
              final filename = it['filename'] as String;
              final title = it['title'] as String?;
              final artist = it['artist'] as String?;
              final ok = await _uploadFileCore(file, endpoint: endpoint, filename: filename, title: title, artist: artist);
              if (ok) {
                success++;
              } else {
                failed++;
                failedItems.add(it);
              }
              if (!mounted) break;
              setState(() {});
            }
            running = false;
          });
          final total = items.length;
          final current = index < total ? (items[index]['filename'] as String) : '';
          final done = !running && index >= total;
          return AlertDialog(
            title: const Text('上传进度'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('总数：$total'),
                Text('成功：$success'),
                Text('失败：$failed'),
                const SizedBox(height: 8),
                if (!done) ...[
                  const LinearProgressIndicator(),
                  const SizedBox(height: 6),
                  Text('当前：$current'),
                ] else ...[
                  const SizedBox(height: 8),
                  const Text('已完成'),
                ],
              ],
            ),
            actions: [
              if (done && failedItems.isNotEmpty)
                TextButton(
                  onPressed: () async {
                    Navigator.pop(ctx);
                    await _runBatchUploadDialog(failedItems, endpoint);
                  },
                  child: const Text('重试失败项'),
                ),
              TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                },
                child: Text(done ? '关闭' : '后台进行'),
              ),
            ],
          );
        });
      },
    );
  }

  Future<Directory> _ensureLibraryDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/library');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File> _copyToLibrary(File src) async {
    final dir = await _ensureLibraryDir();
    final name = _safeName(src.path.split('/').last);
    final dst = File('${dir.path}/$name');
    if (await dst.exists()) {
      // Append timestamp to avoid collision
      final ts = DateTime.now().millisecondsSinceEpoch;
      final parts = name.split('.');
      final base = parts.length > 1 ? parts.sublist(0, parts.length - 1).join('.') : name;
      final ext = parts.length > 1 ? '.${parts.last}' : '';
      final newName = '${base}_$ts$ext';
      final newDst = File('${dir.path}/$newName');
      return src.copy(newDst.path);
    }
    return src.copy(dst.path);
  }

  Future<void> _batchSaveSelectedToLocal() async {
    final playlistStore = context.read<PlaylistStore>();
    final items = <Map<String, dynamic>>[];
    if (Platform.isIOS) {
      final keys = _selected.toSet();
      for (final it in _picked.where((e) => keys.contains(e.uri.toString()))) {
        if (it.uri.scheme != 'file') continue;
        final file = File(it.uri.toFilePath());
        if (await file.exists()) {
          items.add({'file': file, 'title': it.title, 'artist': it.artist, 'durationMs': it.duration?.inMilliseconds});
        }
      }
    } else {
      final ids = _selected.map((k) => int.tryParse(k)).whereType<int>().toSet();
      for (final s in _songs.where((e) => ids.contains(e.id))) {
        final path = s.data;
        if (path.isEmpty) continue;
        final file = File(path);
        if (await file.exists()) {
          items.add({'file': file, 'title': s.title, 'artist': s.artist, 'durationMs': s.duration});
        }
      }
    }
    if (items.isEmpty) {
      if (!mounted) return;
      showDialog(context: context, builder: (_) => const AlertDialog(content: Text('没有可保存的文件')));
      return;
    }
    int index = 0;
    int success = 0;
    int failed = 0;
    final saved = <PlaylistItem>[];
    bool running = true;
    if (!mounted) return;
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setState) {
          Future.microtask(() async {
            if (!running) return;
            for (; index < items.length; index++) {
              final it = items[index];
              final file = it['file'] as File;
              try {
                final dst = await _copyToLibrary(file);
                saved.add(PlaylistItem(
                  uri: dst.uri.toString(),
                  title: it['title'] as String,
                  artist: it['artist'] as String?,
                  durationMs: (it['durationMs'] as int?),
                ));
                success++;
              } catch (_) {
                failed++;
              }
              if (!mounted) break;
              setState(() {});
            }
            running = false;
          });
          final total = items.length;
          final current = index < total ? ((items[index]['file'] as File).path.split('/').last) : '';
          final done = !running && index >= total;
          return AlertDialog(
            title: const Text('保存到本地库'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('总数：$total'),
                Text('成功：$success'),
                Text('失败：$failed'),
                const SizedBox(height: 8),
                if (!done) ...[
                  const LinearProgressIndicator(),
                  const SizedBox(height: 6),
                  Text('当前：$current'),
                ] else ...[
                  const SizedBox(height: 8),
                  const Text('已完成'),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(done ? '关闭' : '后台进行'),
              ),
            ],
          );
        });
      },
    );
    if (saved.isNotEmpty) {
      await playlistStore.addOrCreate('本地库', saved);
      if (!mounted) return;
      showDialog(context: context, builder: (_) => const AlertDialog(content: Text('已保存至“本地库”歌单')));
    }
  }

  Future<void> _handleUploadTap() async {
    await _pickAndSaveToLocal();
  }

  Future<void> _pickAndSaveToLocal() async {
    final playlistStore = context.read<PlaylistStore>();
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: ['mp3', 'aac', 'm4a', 'wav', 'flac', 'ogg'],
    );
    if (result == null) return;
    final files = result.files.where((f) => f.path != null).toList();
    if (files.isEmpty) {
      if (!mounted) return;
      showDialog(context: context, builder: (_) => const AlertDialog(content: Text('未选择任何文件')));
      return;
    }
    int success = 0;
    int failed = 0;
    final saved = <PlaylistItem>[];
    for (final f in files) {
      try {
        final src = File(f.path!);
        if (!await src.exists()) {
          failed++;
          continue;
        }
        final dst = await _copyToLibrary(src);
        String title = f.name;
        String? artist;
        int? durationMs;
        try {
          final meta = await _readMetadataSafe(dst.path);
          if (meta != null) {
            if (meta.title != null && meta.title!.isNotEmpty) title = meta.title!;
            artist = meta.artist;
            if (meta.durationMs != null) {
              final ms = meta.durationMs!;
              durationMs = ms is int ? ms : (ms as num).round();
            }
          }
        } catch (_) {}
        saved.add(PlaylistItem(uri: dst.uri.toString(), title: title, artist: artist, durationMs: durationMs));
        success++;
      } catch (_) {
        failed++;
      }
    }
    if (saved.isNotEmpty) {
      await playlistStore.addOrCreate('本地库', saved);
    }
    if (!mounted) return;
    final msg = '成功：$success，失败：$failed';
    showDialog(context: context, builder: (_) => AlertDialog(content: Text('上传完成（$msg）')));
  }
}

String _folderNameFromPath(String path) {
  final normalized = path.replaceAll('\\', '/');
  final segments = normalized.split('/').where((e) => e.isNotEmpty).toList();
  if (segments.isEmpty) return path;
  return segments.last;
}

String _displayArtist(String? raw) {
  final v = (raw ?? '').trim();
  if (v.isEmpty) return '';
  final lower = v.toLowerCase();
  if (lower == 'unknown' || lower == '<unknown>' || lower == '未知') return '';
  return v;
}

String _parentFolderPath(String path) {
  final normalized = path.replaceAll('\\', '/');
  final idx = normalized.lastIndexOf('/');
  if (idx <= 0) return '';
  return normalized.substring(0, idx);
}

class _FolderSongsGroup {
  final String path;
  final String name;
  final List<SongModel> songs;

  const _FolderSongsGroup({
    required this.path,
    required this.name,
    required this.songs,
  });
}

class _AndroidFolderSongsPage extends StatelessWidget {
  final String currentPath;
  final List<_FolderSongsGroup> allGroups;
  final Future<void> Function(BuildContext context, SongModel song) onAddSingleSongToPlaylist;
  final void Function(BuildContext context, SongModel song) onShowSongDetail;
  final Future<void> Function(SongModel song) onOpenAndroidSong;
  final Future<void> Function(String uri) onLocateInPlaylistByUri;
  final Future<void> Function(String uri) onRemoveFromPlaylistsByUri;
  final Future<void> Function(SongModel song) onSaveAndroidSongToLocal;

  const _AndroidFolderSongsPage({
    required this.currentPath,
    required this.allGroups,
    required this.onAddSingleSongToPlaylist,
    required this.onShowSongDetail,
    required this.onOpenAndroidSong,
    required this.onLocateInPlaylistByUri,
    required this.onRemoveFromPlaylistsByUri,
    required this.onSaveAndroidSongToLocal,
  });

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerController>();
    final byPath = {for (final g in allGroups) g.path: g};
    final songs = byPath[currentPath]?.songs ?? const <SongModel>[];
    final childGroups = allGroups.where((g) => _parentFolderPath(g.path) == currentPath).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return Scaffold(
      appBar: AppBar(
        title: Text(_folderNameFromPath(currentPath)),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.separated(
              itemCount: childGroups.length + songs.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                if (index < childGroups.length) {
                  final g = childGroups[index];
                  return ListTile(
                    leading: const Icon(Icons.folder),
                    title: Text(g.name),
                    subtitle: Text('${g.songs.length} 首歌曲'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => _AndroidFolderSongsPage(
                            currentPath: g.path,
                            allGroups: allGroups,
                            onAddSingleSongToPlaylist: onAddSingleSongToPlaylist,
                            onShowSongDetail: onShowSongDetail,
                            onOpenAndroidSong: onOpenAndroidSong,
                            onLocateInPlaylistByUri: onLocateInPlaylistByUri,
                            onRemoveFromPlaylistsByUri: onRemoveFromPlaylistsByUri,
                            onSaveAndroidSongToLocal: onSaveAndroidSongToLocal,
                          ),
                        ),
                      );
                    },
                  );
                }
                final songIndex = index - childGroups.length;
                final s = songs[songIndex];
                final liked = player.isLiked(s.id);
                final favorite = player.isFavorite(s.id);
                final artist = _displayArtist(s.artist);
                return ListTile(
                  leading: GestureDetector(
                    onTap: () async {
                      await player.setPlaylist(songs, startIndex: songIndex);
                      await player.play();
                      if (!context.mounted) return;
                      FullPlayerPage.open(context);
                    },
                    child: QueryArtworkWidget(
                      id: s.id,
                      type: ArtworkType.AUDIO,
                      nullArtworkWidget: const _PlaceholderArt(),
                    ),
                  ),
                  onTap: () {
                    player.setPlaylist(songs, startIndex: songIndex);
                    player.play();
                  },
                  title: Text(s.title),
                  subtitle: Text([
                    if (artist.isNotEmpty) artist,
                    if ((s.duration ?? 0) > 0) _fmt(Duration(milliseconds: s.duration!)),
                  ].join(' · ')),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        onPressed: () => player.toggleLike(s.id),
                        icon: Icon(
                          liked ? Icons.favorite : Icons.favorite_border,
                          color: liked ? Colors.red : null,
                        ),
                      ),
                      IconButton(
                        onPressed: () => player.toggleFavorite(s.id),
                        icon: Icon(
                          favorite ? Icons.bookmark : Icons.bookmark_border,
                        ),
                      ),
                      IconButton(
                        tooltip: '添加到歌单',
                        onPressed: () => onAddSingleSongToPlaylist(context, s),
                        icon: const Icon(Icons.playlist_add),
                      ),
                      PopupMenuButton<String>(
                        onSelected: (v) {
                          if (v == 'detail') onShowSongDetail(context, s);
                          if (v == 'open') onOpenAndroidSong(s);
                          if (v == 'locate') onLocateInPlaylistByUri(s.uri ?? '');
                          if (v == 'remove_from_playlist') onRemoveFromPlaylistsByUri(s.uri ?? '');
                          if (v == 'save_local') onSaveAndroidSongToLocal(s);
                        },
                        itemBuilder: (context) => const [
                          PopupMenuItem(value: 'detail', child: Text('查看详情')),
                          PopupMenuItem(value: 'open', child: Text('打开文件')),
                          PopupMenuItem(value: 'locate', child: Text('定位到歌单位置')),
                          PopupMenuItem(value: 'remove_from_playlist', child: Text('从歌单移除…')),
                          PopupMenuItem(value: 'save_local', child: Text('保存到本地库')),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

enum _SortMode { titleAsc, titleDesc, artistAsc, artistDesc, durationAsc, durationDesc }
class _PickedAudio {
  final Uri uri;
  final String title;
  final Uri? artUri;
  final String? artist;
  final Duration? duration;
  _PickedAudio({
    required this.uri,
    required this.title,
    this.artUri,
    this.artist,
    this.duration,
  });
}

class MiniPlayer extends StatelessWidget {
  final AudioHandler handler;
  const MiniPlayer({super.key, required this.handler});

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerController>();
    final mode = context.select<PlayerController, PlayMode>((c) => c.mode);
    return StreamBuilder<MediaItem?>(
      stream: handler.mediaItem,
      builder: (context, snapItem) {
        final item = snapItem.data;
        return Material(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    IconButton(
                      tooltip: '播放模式',
                      onPressed: () => player.cyclePlayMode(),
                      icon: Icon(_modeIcon(mode)),
                    ),
                    GestureDetector(
                      onTap: () {
                        FullPlayerPage.open(context);
                      },
                      child: _ArtworkThumb(item: item),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: GestureDetector(
                        onTap: () {
                          FullPlayerPage.open(context);
                        },
                        child: Text(
                          item?.title ?? '未播放',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => handler.skipToPrevious(),
                      icon: const Icon(Icons.skip_previous),
                    ),
                    StreamBuilder<PlaybackState>(
                      stream: handler.playbackState,
                      builder: (context, snapState) {
                        final playing = snapState.data?.playing ?? false;
                        return IconButton(
                          onPressed: () => playing ? handler.pause() : handler.play(),
                          icon: Icon(playing ? Icons.pause_circle_filled : Icons.play_circle_fill),
                        );
                      },
                    ),
                    IconButton(
                      onPressed: () => handler.skipToNext(),
                      icon: const Icon(Icons.skip_next),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                _MiniPositionBar(handler: handler, duration: item?.duration ?? Duration.zero),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _MiniPositionBar extends StatelessWidget {
  final AudioHandler handler;
  final Duration duration;
  const _MiniPositionBar({required this.handler, required this.duration});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlaybackState>(
      stream: handler.playbackState,
      builder: (context, snapState) {
        final position = snapState.data?.updatePosition ?? Duration.zero;
        final canSeek = duration > Duration.zero;
        return Row(
          children: [
            Text(_fmt(position), style: Theme.of(context).textTheme.bodySmall),
            Expanded(
              child: Slider(
                value: position.inMilliseconds.clamp(0, duration.inMilliseconds).toDouble(),
                max: (duration.inMilliseconds > 0 ? duration.inMilliseconds : 1).toDouble(),
                onChanged: canSeek
                    ? (v) => handler.seek(Duration(milliseconds: v.round()))
                    : null,
              ),
            ),
            Text(_fmt(duration), style: Theme.of(context).textTheme.bodySmall),
          ],
        );
      },
    );
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

class _ArtworkThumb extends StatelessWidget {
  final MediaItem? item;
  const _ArtworkThumb({required this.item});

  @override
  Widget build(BuildContext context) {
    final extras = item?.extras;
    if (item?.artUri != null) {
      final uri = item!.artUri!;
      if (uri.scheme == 'file') {
        return ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Image.file(
            File.fromUri(uri),
            width: 40,
            height: 40,
            fit: BoxFit.cover,
          ),
        );
      }
      if (uri.scheme == 'http' || uri.scheme == 'https') {
        return ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Image.network(
            uri.toString(),
            width: 40,
            height: 40,
            fit: BoxFit.cover,
          ),
        );
      }
    }
    if (Platform.isAndroid && extras != null && extras['songId'] != null) {
      final int songId = extras['songId'] as int;
      return QueryArtworkWidget(
        id: songId,
        type: ArtworkType.AUDIO,
        nullArtworkWidget: const _PlaceholderArt(),
        artworkHeight: 40,
        artworkWidth: 40,
      );
    }
    return const _PlaceholderArt();
  }
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
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
      child: const Icon(Icons.music_note),
    );
  }
}

Widget _leadingArtForPicked(_PickedAudio item) {
  if (item.artUri != null) {
    final uri = item.artUri!;
    if (uri.scheme == 'file') {
      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.file(
          File.fromUri(uri),
          width: 40,
          height: 40,
          fit: BoxFit.cover,
        ),
      );
    }
    if (uri.scheme == 'http' || uri.scheme == 'https') {
      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.network(
          uri.toString(),
          width: 40,
          height: 40,
          fit: BoxFit.cover,
        ),
      );
    }
  }
  return const _PlaceholderArt();
}

String _safeName(String input) {
  final s = input.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  return s.length > 64 ? s.substring(s.length - 64) : s;
}

class NowPlayingListener extends StatefulWidget {
  final Widget child;
  const NowPlayingListener({super.key, required this.child});

  @override
  State<NowPlayingListener> createState() => _NowPlayingListenerState();
}

class _NowPlayingListenerState extends State<NowPlayingListener> {
  AudioHandler? _handler;
  StreamSubscription<MediaItem?>? _mediaSub;
  String? _lastHistoryUri;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final current = context.read<AudioHandler>();
    if (!identical(current, _handler)) {
      _bindHandler(current);
    }
  }

  void _bindHandler(AudioHandler handler) {
    _mediaSub?.cancel();
    _handler = handler;
    _mediaSub = handler.mediaItem.listen((item) {
      if (item == null) return;
      if (_lastHistoryUri == item.id) return;
      _lastHistoryUri = item.id;
      final artUri = item.artUri;
      final store = context.read<PlaylistStore>();
      unawaited(
        store.addHistory(
          PlaylistItem(
            uri: item.id,
            title: item.title,
            artist: item.artist,
            artPath: artUri != null && artUri.scheme == 'file' ? artUri.toFilePath() : null,
            durationMs: item.duration?.inMilliseconds,
          ),
        ),
      );
    });
  }

  @override
  void dispose() {
    _mediaSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
