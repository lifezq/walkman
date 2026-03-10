import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsStore extends ChangeNotifier {
  static const _kUploadEndpoint = 'upload_endpoint';
  static const _kLyricsEndpoint = 'lyrics_endpoint';
  String? _endpoint;
  String? _lyricsEndpoint;
  String? get endpoint => _endpoint;
  String? get lyricsEndpoint => _lyricsEndpoint;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _endpoint = prefs.getString(_kUploadEndpoint);
    _lyricsEndpoint = prefs.getString(_kLyricsEndpoint);
    notifyListeners();
  }

  Future<void> setEndpoint(String? value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value == null || value.isEmpty) {
      await prefs.remove(_kUploadEndpoint);
      _endpoint = null;
    } else {
      await prefs.setString(_kUploadEndpoint, value);
      _endpoint = value;
    }
    notifyListeners();
  }

  Future<void> setLyricsEndpoint(String? value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value == null || value.isEmpty) {
      await prefs.remove(_kLyricsEndpoint);
      _lyricsEndpoint = null;
    } else {
      await prefs.setString(_kLyricsEndpoint, value);
      _lyricsEndpoint = value;
    }
    notifyListeners();
  }
}
