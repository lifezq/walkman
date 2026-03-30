import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:metadata_god/metadata_god.dart';
import 'package:path_provider/path_provider.dart';
import 'play_mode.dart';

class MyAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final AudioPlayer _player = AudioPlayer();
  ConcatenatingAudioSource? _concat;
  StreamSubscription<PlaybackEvent>? _eventSub;
  StreamSubscription<int?>? _indexSub;
  StreamSubscription<Duration>? _positionSub;

  MyAudioHandler() {
    _eventSub = _player.playbackEventStream.listen((_) => _broadcastState());
    _indexSub = _player.currentIndexStream.listen((index) {
      _syncMediaItemWithCurrentQueue(index: index);
    });
    _positionSub = _player.positionStream.listen((_) {
      _broadcastState();
    });
  }

  Future<void> setQueueFromSongs(List<SongModel> songs, {int startIndex = 0}) async {
    final items = songs
        .map(
          (s) {
            final albumId = s.albumId;
            final art = (albumId != null)
                ? Uri.parse('content://media/external/audio/albumart/$albumId')
                : null;
            return MediaItem(
              id: s.id.toString(),
              title: s.title,
              artist: s.artist ?? '',
              duration: Duration(milliseconds: s.duration ?? 0),
              artUri: art,
              extras: {
                'songId': s.id,
                'albumId': albumId,
              },
            );
          },
        )
        .toList();
    queue.add(items);
    final children = songs
        .map(
          (s) {
            final albumId = s.albumId;
            final art = (albumId != null)
                ? Uri.parse('content://media/external/audio/albumart/$albumId')
                : null;
            final item = MediaItem(
              id: s.id.toString(),
              title: s.title,
              artist: s.artist ?? '',
              duration: Duration(milliseconds: s.duration ?? 0),
              artUri: art,
              extras: {
                'songId': s.id,
                'albumId': albumId,
              },
            );
            return AudioSource.uri(Uri.parse(s.uri!), tag: item);
          },
        )
        .toList();
    _concat = ConcatenatingAudioSource(children: children);
    await _player.setAudioSource(_concat!, initialIndex: startIndex);
    _syncMediaItemWithCurrentQueue(index: startIndex);
  }

  Future<void> setQueueFromUris(List<Uri> uris, {List<String>? titles, int startIndex = 0}) async {
    final items = <MediaItem>[];
    final children = <AudioSource>[];
    for (var i = 0; i < uris.length; i++) {
      final uri = uris[i];
      final title = titles != null && i < titles.length ? titles[i] : (uri.pathSegments.isNotEmpty ? uri.pathSegments.last : uri.toString());
      Uri? art;
      if (uri.isScheme('file')) {
        try {
          final meta = await MetadataGod.readMetadata(file: uri.toFilePath());
          if (meta.picture != null && meta.picture!.data.isNotEmpty) {
            final dir = await getTemporaryDirectory();
            final name = _safeName(uri.toFilePath());
            final file = File('${dir.path}/art_$name.jpg');
            await file.writeAsBytes(meta.picture!.data);
            art = file.uri;
          }
        } catch (_) {}
        if (art == null) {
          try {
            final dir = await getTemporaryDirectory();
            final name = _safeName(uri.toFilePath());
            final file = File('${dir.path}/art_$name.jpg');
            if (await file.exists()) {
              art = file.uri;
            }
          } catch (_) {}
        }
      }
      final item = MediaItem(id: uri.toString(), title: title, artist: '', artUri: art);
      items.add(item);
      children.add(AudioSource.uri(uri, tag: item));
    }
    queue.add(items);
    _concat = ConcatenatingAudioSource(children: children);
    await _player.setAudioSource(_concat!, initialIndex: startIndex);
    _syncMediaItemWithCurrentQueue(index: startIndex);
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> skipToNext() => _player.seekToNext();

  @override
  Future<void> skipToPrevious() => _player.seekToPrevious();

  Future<void> setPlayMode(PlayMode mode) async {
    switch (mode) {
      case PlayMode.sequence:
        await _player.setShuffleModeEnabled(false);
        await _player.setLoopMode(LoopMode.all);
        break;
      case PlayMode.shuffle:
        await _player.setShuffleModeEnabled(true);
        await _player.setLoopMode(LoopMode.all);
        break;
      case PlayMode.single:
        await _player.setShuffleModeEnabled(false);
        await _player.setLoopMode(LoopMode.one);
        break;
    }
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    await _player.seek(Duration.zero, index: index);
  }

  Future<void> reorderQueue(int oldIndex, int newIndex) async {
    if (_concat == null) return;
    final items = List<MediaItem>.from(queue.value);
    if (newIndex > oldIndex) newIndex -= 1;
    if (oldIndex < 0 || oldIndex >= items.length) return;
    if (newIndex < 0 || newIndex >= items.length) return;
    final item = items.removeAt(oldIndex);
    items.insert(newIndex, item);
    await _concat!.move(oldIndex, newIndex);
    queue.add(items);
    _syncMediaItemWithCurrentQueue();
  }

  Future<void> removeFromQueue(int index) async {
    if (_concat == null) return;
    final items = List<MediaItem>.from(queue.value);
    if (index < 0 || index >= items.length) return;
    items.removeAt(index);
    await _concat!.removeAt(index);
    queue.add(items);
    _syncMediaItemWithCurrentQueue();
  }

  void _syncMediaItemWithCurrentQueue({int? index}) {
    final items = queue.value;
    final i = index ?? _player.currentIndex;
    if (i != null && i >= 0 && i < items.length) {
      mediaItem.add(items[i]);
      return;
    }
    if (items.isEmpty) {
      mediaItem.add(null);
    }
  }

  void _broadcastState() {
    final playing = _player.playing;
    final processingState = _player.processingState;
    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.stop,
          MediaControl.skipToNext,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1, 3],
        processingState: _mapProcessingState(processingState),
        playing: playing,
        updatePosition: _player.position,
        bufferedPosition: _player.bufferedPosition,
        speed: _player.speed,
        queueIndex: _player.currentIndex,
      ),
    );
  }

  AudioProcessingState _mapProcessingState(ProcessingState state) {
    switch (state) {
      case ProcessingState.idle:
        return AudioProcessingState.idle;
      case ProcessingState.loading:
        return AudioProcessingState.loading;
      case ProcessingState.buffering:
        return AudioProcessingState.buffering;
      case ProcessingState.ready:
        return AudioProcessingState.ready;
      case ProcessingState.completed:
        return AudioProcessingState.completed;
    }
  }

  Future<void> close() async {
    await _eventSub?.cancel();
    await _indexSub?.cancel();
    await _positionSub?.cancel();
    await _player.dispose();
  }
}

String _safeName(String input) {
  final s = input.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  return s.length > 64 ? s.substring(s.length - 64) : s;
}
