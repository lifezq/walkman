import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PlaylistItem {
  final String uri;
  final String title;
  final String? artist;
  final String? artPath;
  final int? durationMs;
  PlaylistItem({
    required this.uri,
    required this.title,
    this.artist,
    this.artPath,
    this.durationMs,
  });

  Map<String, dynamic> toJson() => {
        'uri': uri,
        'title': title,
        'artist': artist,
        'artPath': artPath,
        'durationMs': durationMs,
      };

  static PlaylistItem fromJson(Map<String, dynamic> m) => PlaylistItem(
        uri: m['uri'] as String,
        title: m['title'] as String,
        artist: m['artist'] as String?,
        artPath: m['artPath'] as String?,
        durationMs: m['durationMs'] as int?,
      );
}

class Playlist {
  final String id;
  String name;
  final List<PlaylistItem> items;
  Playlist({required this.id, required this.name, List<PlaylistItem>? items}) : items = items ?? [];

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'items': items.map((e) => e.toJson()).toList(),
      };

  static Playlist fromJson(Map<String, dynamic> m) => Playlist(
        id: m['id'] as String,
        name: m['name'] as String,
        items: (m['items'] as List).cast<Map<String, dynamic>>().map(PlaylistItem.fromJson).toList(),
      );
}

class PlaylistStore extends ChangeNotifier {
  static const _kKey = 'playlists_v1';
  static const _kRecentKey = 'recent_v1';
  static const _kRecentPlaylistsMeta = 'recent_playlist_meta_v1';
  final List<Playlist> _playlists = [];
  List<Playlist> get playlists => List.unmodifiable(_playlists);
  final List<PlaylistItem> _recent = [];
  List<PlaylistItem> get recent => List.unmodifiable(_recent);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kKey);
    _playlists.clear();
    if (raw != null) {
      try {
        final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
        _playlists.addAll(list.map(Playlist.fromJson));
      } catch (_) {}
    }
    _recent.clear();
    final rawRecent = prefs.getString(_kRecentKey);
    if (rawRecent != null) {
      try {
        final list = (jsonDecode(rawRecent) as List).cast<Map<String, dynamic>>();
        _recent.addAll(list.map(PlaylistItem.fromJson));
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kKey, jsonEncode(_playlists.map((e) => e.toJson()).toList()));
  }

  Future<void> create(String name) async {
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    _playlists.add(Playlist(id: id, name: name));
    await _save();
    notifyListeners();
  }

  Future<void> rename(String id, String newName) async {
    final p = _playlists.firstWhere((e) => e.id == id, orElse: () => throw ArgumentError('not found'));
    p.name = newName;
    await _save();
    notifyListeners();
  }

  Future<void> delete(String id) async {
    _playlists.removeWhere((e) => e.id == id);
    await _save();
    notifyListeners();
  }

  Future<void> addOrCreate(String name, List<PlaylistItem> items) async {
    final existing = _playlists.where((e) => e.name == name).toList();
    final p = existing.isNotEmpty ? existing.first : Playlist(id: DateTime.now().microsecondsSinceEpoch.toString(), name: name);
    if (existing.isEmpty) _playlists.add(p);
    p.items.addAll(items);
    await _save();
    await _touchRecentPlaylist(name);
    notifyListeners();
  }

  Future<void> addItems(String id, List<PlaylistItem> items) async {
    final p = _playlists.firstWhere((e) => e.id == id, orElse: () => throw ArgumentError('not found'));
    p.items.addAll(items);
    await _save();
    notifyListeners();
  }

  Future<void> removeItems(String id, Iterable<int> indexes) async {
    final p = _playlists.firstWhere((e) => e.id == id, orElse: () => throw ArgumentError('not found'));
    final sorted = indexes.toList()..sort((a, b) => b.compareTo(a));
    for (final i in sorted) {
      if (i >= 0 && i < p.items.length) p.items.removeAt(i);
    }
    await _save();
    notifyListeners();
  }

  Future<void> reorderItems(String id, int oldIndex, int newIndex) async {
    final p = _playlists.firstWhere((e) => e.id == id, orElse: () => throw ArgumentError('not found'));
    if (newIndex > oldIndex) newIndex -= 1;
    if (oldIndex < 0 || oldIndex >= p.items.length) return;
    if (newIndex < 0 || newIndex >= p.items.length) return;
    final item = p.items.removeAt(oldIndex);
    p.items.insert(newIndex, item);
    await _save();
    notifyListeners();
  }

  Future<void> addHistory(PlaylistItem item, {int capacity = 100}) async {
    _recent.removeWhere((e) => e.uri == item.uri);
    _recent.insert(0, item);
    if (_recent.length > capacity) {
      _recent.removeRange(capacity, _recent.length);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kRecentKey, jsonEncode(_recent.map((e) => e.toJson()).toList()));
    notifyListeners();
  }

  Future<void> removeRecent(Iterable<int> indexes) async {
    final sorted = indexes.toList()..sort((a, b) => b.compareTo(a));
    for (final i in sorted) {
      if (i >= 0 && i < _recent.length) _recent.removeAt(i);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kRecentKey, jsonEncode(_recent.map((e) => e.toJson()).toList()));
    notifyListeners();
  }

  Future<void> clearRecent() async {
    _recent.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kRecentKey);
    notifyListeners();
  }

  Future<void> removeByUris(String id, Set<String> uris) async {
    final p = _playlists.firstWhere((e) => e.id == id, orElse: () => throw ArgumentError('not found'));
    p.items.removeWhere((e) => uris.contains(e.uri));
    await _save();
    notifyListeners();
  }

  Future<void> sortItems(String id, String mode) async {
    final p = _playlists.firstWhere((e) => e.id == id, orElse: () => throw ArgumentError('not found'));
    int cmpStr(String a, String b) => a.toLowerCase().compareTo(b.toLowerCase());
    switch (mode) {
      case 'titleAsc':
        p.items.sort((a, b) => cmpStr(a.title, b.title));
        break;
      case 'titleDesc':
        p.items.sort((a, b) => cmpStr(b.title, a.title));
        break;
      case 'artistAsc':
        p.items.sort((a, b) => cmpStr(a.artist ?? '', b.artist ?? ''));
        break;
      case 'artistDesc':
        p.items.sort((a, b) => cmpStr(b.artist ?? '', a.artist ?? ''));
        break;
      case 'durationAsc':
        p.items.sort((a, b) => (a.durationMs ?? 0).compareTo(b.durationMs ?? 0));
        break;
      case 'durationDesc':
        p.items.sort((a, b) => (b.durationMs ?? 0).compareTo(a.durationMs ?? 0));
        break;
    }
    await _save();
    notifyListeners();
  }

  Future<void> _touchRecentPlaylist(String name, {int capacity = 8}) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kRecentPlaylistsMeta);
    Map<String, int> meta = {};
    if (raw != null) {
      try {
        final m = (jsonDecode(raw) as Map).map((k, v) => MapEntry(k.toString(), (v as num).toInt()));
        meta.addAll(m);
      } catch (_) {}
    }
    meta[name] = DateTime.now().millisecondsSinceEpoch;
    final entries = meta.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final pruned = Map.fromEntries(entries.take(capacity));
    await prefs.setString(_kRecentPlaylistsMeta, jsonEncode(pruned));
  }
}
