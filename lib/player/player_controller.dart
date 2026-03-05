import 'package:flutter/foundation.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'audio_handler.dart';
import 'play_mode.dart';

class PlayerController extends ChangeNotifier {
  final MyAudioHandler _handler;
  PlayerController(this._handler);
  final Set<String> _likes = {};
  final Set<String> _favorites = {};
  PlayMode _mode = PlayMode.sequence;
  PlayMode get mode => _mode;

  Future<void> setPlaylist(List<SongModel> songs, {int startIndex = 0}) async {
    await _handler.setQueueFromSongs(songs, startIndex: startIndex);
    notifyListeners();
  }

  Future<void> setPlaylistFromUris(List<Uri> uris, {List<String>? titles, int startIndex = 0}) async {
    await _handler.setQueueFromUris(uris, titles: titles, startIndex: startIndex);
    notifyListeners();
  }

  Future<void> play() async {
    await _handler.play();
  }

  Future<void> pause() async {
    await _handler.pause();
  }

  Future<void> next() async {
    await _handler.skipToNext();
  }

  Future<void> previous() async {
    await _handler.skipToPrevious();
  }

  int currentIndex() {
    return -1;
  }

  void loadStates(Set<String> likes, Set<String> favorites) {
    _likes
      ..clear()
      ..addAll(likes);
    _favorites
      ..clear()
      ..addAll(favorites);
    notifyListeners();
  }

  Future<void> initPlayMode() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('play_mode') ?? 'sequence';
    _mode = _fromString(raw);
    await _handler.setPlayMode(_mode);
    notifyListeners();
  }

  Future<void> cyclePlayMode() async {
    switch (_mode) {
      case PlayMode.sequence:
        _mode = PlayMode.shuffle;
        break;
      case PlayMode.shuffle:
        _mode = PlayMode.single;
        break;
      case PlayMode.single:
        _mode = PlayMode.sequence;
        break;
    }
    await _handler.setPlayMode(_mode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('play_mode', _toString(_mode));
    notifyListeners();
  }

  String _toString(PlayMode m) {
    switch (m) {
      case PlayMode.sequence:
        return 'sequence';
      case PlayMode.shuffle:
        return 'shuffle';
      case PlayMode.single:
        return 'single';
    }
  }

  PlayMode _fromString(String s) {
    switch (s) {
      case 'shuffle':
        return PlayMode.shuffle;
      case 'single':
        return PlayMode.single;
      default:
        return PlayMode.sequence;
    }
  }

  bool isLiked(int id) {
    return isLikedKey(id.toString());
  }

  bool isFavorite(int id) {
    return isFavoriteKey(id.toString());
  }

  bool isLikedKey(String key) {
    return _likes.contains(key);
  }

  bool isFavoriteKey(String key) {
    return _favorites.contains(key);
  }

  Future<void> toggleLike(int id) async {
    await toggleLikeKey(id.toString());
  }

  Future<void> toggleFavorite(int id) async {
    await toggleFavoriteKey(id.toString());
  }

  Future<void> toggleLikeKey(String key) async {
    if (_likes.contains(key)) {
      _likes.remove(key);
    } else {
      _likes.add(key);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('likes', _likes.toList());
    notifyListeners();
  }

  Future<void> toggleFavoriteKey(String key) async {
    if (_favorites.contains(key)) {
      _favorites.remove(key);
    } else {
      _favorites.add(key);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('favorites', _favorites.toList());
    notifyListeners();
  }

  Future<void> likeKeys(Iterable<String> keys) async {
    _likes.addAll(keys);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('likes', _likes.toList());
    notifyListeners();
  }

  Future<void> unlikeKeys(Iterable<String> keys) async {
    _likes.removeAll(keys.toSet());
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('likes', _likes.toList());
    notifyListeners();
  }

  Future<void> favoriteKeys(Iterable<String> keys) async {
    _favorites.addAll(keys);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('favorites', _favorites.toList());
    notifyListeners();
  }

  Future<void> unfavoriteKeys(Iterable<String> keys) async {
    _favorites.removeAll(keys.toSet());
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('favorites', _favorites.toList());
    notifyListeners();
  }

  Future<void> likeIds(Iterable<int> ids) => likeKeys(ids.map((e) => e.toString()));
  Future<void> unlikeIds(Iterable<int> ids) => unlikeKeys(ids.map((e) => e.toString()));
  Future<void> favoriteIds(Iterable<int> ids) => favoriteKeys(ids.map((e) => e.toString()));
  Future<void> unfavoriteIds(Iterable<int> ids) => unfavoriteKeys(ids.map((e) => e.toString()));
}
