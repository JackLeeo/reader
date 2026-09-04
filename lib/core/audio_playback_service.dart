import 'package:audio_session/audio_session.dart';
import 'package:audio_service/audio_service.dart';
import 'package:audioplayers/audioplayers.dart';

/// 后台音频 / 系统媒体控制处理器。
///
/// 包装单个 [AudioPlayer]，把状态同步到系统媒体会话（iOS 锁屏/控制中心、
/// Android 通知栏媒体控制），使听书在 App 退到后台也持续播放，并能用
/// 系统媒体键（播放/暂停/上一段/下一段）控制。
class AudioBookHandler extends BaseAudioHandler with SeekHandler {
  AudioBookHandler(this.player) {
    _bind();
  }

  final AudioPlayer player;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  /// 播放清单回调（用于切到上一/下一段所属范围的音轨）。
  void Function()? onNext;
  void Function()? onPrev;

  void _bind() {
    player.onPlayerStateChanged.listen((s) {
      final playing = s == PlayerState.playing;
      if (playing != _playing) {
        _playing = playing;
        _push();
      }
    });
    player.onPositionChanged.listen((p) {
      _position = p;
      _push();
    });
    player.onDurationChanged.listen((d) {
      _duration = d;
      _push();
    });
    player.onPlayerComplete.listen((_) {
      if (_playing) {
        _playing = false;
        _push();
      }
    });
  }

  void _push() {
    playbackState.add(PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (_playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
        if (_playing) MediaControl.stop,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.pause,
        MediaAction.play,
      },
      processingState: AudioProcessingState.idle,
      playing: _playing,
      updatePosition: _position,
      bufferedPosition: _duration,
    ));
  }

  /// 设置当前媒体信息（锁屏标题/封面），并激活音频会话。
  Future<void> setMedia({
    required String id,
    required String title,
    String? artist,
    Duration? duration,
  }) async {
    final session = await AudioSession.instance;
    await session.setActive(true);
    mediaItem.add(MediaItem(
      id: id,
      title: title,
      artist: artist,
      duration: duration,
    ));
    _push();
  }

  @override
  Future<void> play() async {
    await player.resume();
  }

  @override
  Future<void> pause() async {
    await player.pause();
  }

  @override
  Future<void> stop() async {
    await player.stop();
    _playing = false;
    final session = await AudioSession.instance;
    await session.setActive(false);
    _push();
  }

  @override
  Future<void> seek(Duration position) async {
    await player.seek(position);
  }

  @override
  Future<void> skipToNext() async {
    onNext?.call();
  }

  @override
  Future<void> skipToPrevious() async {
    onPrev?.call();
  }
}

/// 后台音频服务的入口：持有唯一播放器与 [AudioBookHandler]。
///
/// 在不支持的平台（如纯 Dart 测试 / 未接入插件的桌面端）上初始化失败时
/// 安全降级，UI 仍可用（停止使用该服务）。初始化幂等。
class AudioPlaybackService {
  AudioPlaybackService._();
  static final AudioPlaybackService instance = AudioPlaybackService._();

  AudioBookHandler? _handler;
  bool? _available;

  /// 当前使用的播放器（由服务统一持有，供阅读视图复用）。
  AudioPlayer? get player => _handler?.player;

  /// 服务是否可用（后台播放已就绪）。
  bool get available => _available == true;

  /// 初始化后台播放（App 启动时调用一次；失败静默降级）。
  Future<bool> init() async {
    if (_available != null) return _available!;
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      final handler = await AudioService.init(
        builder: () => AudioBookHandler(AudioPlayer()),
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'com.legado.playback',
          androidNotificationChannelName: '朗读/听书播放',
          androidNotificationOngoing: true,
        ),
      );
      _handler = handler;
      _available = true;
    } catch (_) {
      _available = false;
    }
    return _available!;
  }

  /// 通过后台服务播放一段音频并更新锁屏媒体信息。
  Future<void> play({
    required String url,
    required String title,
    String? artist,
    void Function()? onNext,
    void Function()? onPrev,
  }) async {
    if (!available) return;
    try {
      _handler!.onNext = onNext;
      _handler!.onPrev = onPrev;
      await _handler!.setMedia(id: url, title: title, artist: artist);
      await _handler!.player.play(UrlSource(url));
    } catch (_) {}
  }

  Future<void> stop() async {
    if (!available) return;
    try {
      await _handler!.stop();
    } catch (_) {}
  }
}