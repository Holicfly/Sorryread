import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../app/dependencies.dart';
import '../../../data/sync_repository.dart';
import '../../../data/local_library.dart';
import '../../../design_system/app_theme.dart';
import '../../../sync_engine/sync_model.dart';
import '../../bookshelf/presentation/book_opening.dart';
import '../data/reader_fonts.dart';
import '../data/reader_platform.dart';
import '../data/reader_preloader.dart';
import '../data/reader_repository.dart';
import '../data/reader_source.dart';
import 'reader_asset_icon.dart';
import 'reader_bottom_fade.dart';
import 'reader_curl.dart';
import 'reader_layout.dart';
import 'reader_loading_paper.dart';
import 'reader_preferences.dart';
import 'reader_resume_cache.dart';
import 'reader_scroll_sliver.dart';
import 'reader_settings_sheet.dart';
import 'reader_status_bar.dart';

class ReaderOpenRequest {
  const ReaderOpenRequest(this.book, {this.chapterUrl, this.opening});
  final ShelfBook book;
  final String? chapterUrl;
  final BookOpening? opening;
}

class ReaderPage extends ConsumerStatefulWidget {
  const ReaderPage({super.key, required this.book, this.initialChapterUrl});
  final ShelfBook book;
  final String? initialChapterUrl;
  @override
  ConsumerState<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends ConsumerState<ReaderPage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final _preferences = ValueNotifier(const ReaderPreferences());
  late ScrollController _scroll;
  late ReaderResumeCache _resumeCache;
  bool _loadStarted = false;
  MediaQueryData? _resumeMetrics;
  double? _closingScrollWithinChapter;
  String? _announcedPaper;
  BookPaperScope? _paperScope;
  ui.Image? _openingPaperImage;
  bool _hasShownTools = false;
  final _readingVersion = ValueNotifier(0);
  final _scrollCenterKey = const ValueKey('reader-scroll-origin');
  final _layoutCache = <String, ReaderLayout>{};
  ReaderPreloader? _preloader;
  int _scrollOrigin = 0;
  int _layoutGeneration = 0;
  double? _layoutWidth, _layoutHeight;
  TextScaler? _layoutScaler;
  Future<void>? _warmingLayouts;
  bool _warmAgain = false, _scrollActive = false, _disposed = false;
  bool? _previousResampling;
  List<ReaderBlock> _beforeBlocks = [], _afterBlocks = [];
  bool _warmScheduled = false;
  late final AnimationController _flip = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
  );
  ReaderRepository? _repository;
  SyncRepository? _sync;
  StreamSubscription<SyncChange>? _remotePositions;
  SyncChange? _pendingRemote;
  bool _applyingRemote = false;

  void _queueRemote(SyncChange event) {
    if (event.entityId != widget.book.id ||
        _exiting ||
        _exitPrepared ||
        _disposed) {
      return;
    }
    _pendingRemote = event;
    unawaited(_applyRemote());
  }

  Future<void> _applyRemote() async {
    if (_loading ||
        _scrollActive ||
        _applyingRemote ||
        _pendingRemote == null ||
        !mounted ||
        _exiting) {
      return;
    }
    _applyingRemote = true;
    try {
      while (_pendingRemote != null && mounted && !_exiting) {
        final event = _pendingRemote!;
        _pendingRemote = null;
        final body = chapter;
        if (body == null) continue;
        final current = <String, dynamic>{
          'chapterUrl': body.url,
          'chapterIndex': _chapterIndex,
          'chapterCount': _catalog!.chapters.length,
          'bookProgressChapterUrl': body.url,
          'progress': _currentProgress(),
        };
        if ((compareBookPositions(event.payload, current) ?? 0) <= 0) continue;
        // Flush a pending local checkpoint before loading the merged maximum.
        await _save();
        if (mounted && !_exiting) await _load(remoteUpdate: true);
      }
    } finally {
      _applyingRemote = false;
    }
  }

  double _currentProgress() {
    final body = chapter!;
    final p = _anchor.paragraph.clamp(0, body.paragraphs.length - 1);
    final offset = _anchor.offset.clamp(0, body.paragraphs[p].length);
    return ((body.scalarStart(p) +
                body.paragraphs[p].substring(0, offset).runes.length) /
            math.max(1, body.scalarLength))
        .clamp(0, 1);
  }

  ReaderFonts? _fonts;
  SourceRule? _source;
  ReaderCatalog? _catalog;
  final _window = <(int, ReaderChapter)>[];
  final _layouts = <ReaderLayout>[];
  final _retired = <ReaderLayout>[];
  String? _layoutKey, _layoutStyleKey, _family, _error;
  bool _loading = true,
      _tools = false,
      _dirty = false,
      _ignoreScroll = false,
      _exiting = false,
      _forward = true;
  int _chapterIndex = 0, _page = 0;
  int _epoch = 0;
  int? _battery;
  bool _charging = false;
  DateTime _time = DateTime.now();
  TextAnchor _anchor = const TextAnchor(0, 0);
  TextAnchor? _pendingAnchor;
  ReaderLeaf? _flipFrom;
  Timer? _clock, _debounce, _checkpoint;
  Future<void> _saves = Future.value(), _settingsSaves = Future.value();
  double? _pendingScrollWithinChapter;
  bool _initializing = true;
  bool _entryApplied = false;
  Animation<double>? _routeAnimation;
  bool _exitPrepared = false, _fullscreenRestored = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _paperScope = BookPaperScope.maybeOf(context);
    final next = ModalRoute.of(context)?.animation;
    if (next != _routeAnimation) {
      _routeAnimation?.removeStatusListener(_routeStatus);
      _routeAnimation = next;
      next?.addStatusListener(_routeStatus);
    }
    if (!_loadStarted) {
      _loadStarted = true;
      final resume = widget.initialChapterUrl == null
          ? _resumeCache.take(widget.book, MediaQuery.of(context))
          : null;
      if (resume != null) _restoreResume(resume);
      // Start alongside the route, with an immediately paintable loading state
      // (or a transferred prepared chapter). No post-frame/transition gate.
      unawaited(_load(resumePrepared: resume != null));
    }
  }

  void _restoreResume(ReaderResume resume) {
    _preferences.value = resume.preferences;
    _family = resume.family;
    _catalog = resume.catalog;
    _source = resume.source;
    _chapterIndex = _scrollOrigin = resume.chapterIndex;
    _anchor = resume.anchor;
    _pendingAnchor = resume.anchor;
    _bottomClearance = resume.bottomClearance;
    _window.add((resume.chapterIndex, resume.layout.chapter));
    _layoutWidth = resume.layout.width;
    _layoutHeight = resume.layout.height;
    _layoutScaler = MediaQuery.textScalerOf(context);
    _layoutCache[_preparedKey(resume.layout.chapter)] = resume.layout;
    _pendingScrollWithinChapter = resume.scrollWithinChapter;
    _replaceUnattachedScroll(resume.scrollWithinChapter ?? 0);
    _initializing = false;
    _entryApplied = true;
    _loading = false;
    _openingPaperImage = resume.paperImage;
  }

  void _replaceUnattachedScroll(double offset) {
    if (_scroll.hasClients) return;
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _scroll = ScrollController(initialScrollOffset: offset)
      ..addListener(_onScroll);
  }

  void _routeStatus(AnimationStatus status) {
    if (status == AnimationStatus.reverse) _prepareExit();
    if (status == AnimationStatus.completed && _openingPaperImage != null) {
      setState(_releaseOpeningPaper);
    }
  }

  void _releaseOpeningPaper() {
    final image = _openingPaperImage;
    _openingPaperImage = null;
    if (image != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => image.dispose());
    }
  }

  void _restoreFullscreen() {
    if (_fullscreenRestored) return;
    _fullscreenRestored = true;
    unawaited(
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge)
          .then((_) => ReaderPlatform().fullscreen(false)),
    );
  }

  void _prepareExit() {
    if (_exitPrepared) return;
    _exitPrepared = true;
    if (prefs.mode == PageMode.scroll && _scroll.hasClients && layout != null) {
      _closingScrollWithinChapter =
          _scroll.offset + _topFor(_scrollOrigin) - _topFor(_chapterIndex);
    }
    // Capture the position synchronously; persistence runs concurrently with the
    // reverse transition. Repository queues keep writes ordered and durable.
    unawaited(_save());
    unawaited(_pauseSession());
    unawaited(_settingsSaves);
    _restoreFullscreen();
  }

  bool _favoriteBusy = false;
  double _bottomClearance = 12;
  ReadingSession? _session;
  bool _foreground = true;
  int _sessionTicks = 0;

  void _resumeSession() {
    if (_foreground && !_loading && chapter != null && _error == null) {
      _session?.resume();
    }
  }

  Future<void> _pauseSession() async {
    try {
      await _session?.pause();
    } catch (_) {
      if (mounted) _notice('阅读统计保存失败，请重试。');
    }
  }

  ReaderPreferences get prefs => _preferences.value;
  int get _currentWindow => _window.indexWhere((e) => e.$1 == _chapterIndex);
  ReaderChapter? get chapter =>
      _currentWindow < 0 ? null : _window[_currentWindow].$2;
  ReaderLayout? get layout =>
      _currentWindow < 0 || _currentWindow >= _layouts.length
      ? null
      : _layouts[_currentWindow];

  @override
  void initState() {
    super.initState();
    _resumeCache = ref.read(readerResumeCacheProvider);
    _scroll = ScrollController();
    WidgetsBinding.instance.addObserver(this);
    _enterFullscreen();
    _scroll.addListener(_onScroll);
    _flip.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        if (mounted) setState(() => _flipFrom = null);
        _releaseRetired();
      }
    });
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      final now = DateTime.now();
      if (++_sessionTicks % 15 == 0) {
        _session?.checkpoint().catchError((Object _) {
          if (mounted) _notice('阅读统计保存失败，请重试。');
        });
      }
      if (now.minute != _time.minute || now.hour != _time.hour) _updateStatus();
    });
  }

  Future<void> _updateStatus() async {
    final battery = await _repository?.platform.batteryStatus();
    final clearance = await _repository?.platform.bottomClearance();
    if (mounted) {
      _time = DateTime.now();
      _battery = battery?.level;
      _charging = battery?.charging ?? false;
      _readingVersion.value++;
      if (clearance != null && clearance != _bottomClearance) {
        setState(() => _bottomClearance = clearance);
      }
    }
  }

  Future<void> _enterFullscreen() async {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (mounted) await ReaderPlatform().fullscreen(true);
  }

  Future<void> _toggleFavorite() async {
    if (_favoriteBusy) return;
    setState(() => _favoriteBusy = true);
    try {
      final sync = await ref.read(syncRepositoryProvider.future);
      if (!mounted) return;
      final saved = await sync.record(widget.book.id, 'favorite');
      await sync.setFavorite(
        widget.book,
        saved?.effective.payload['active'] != true,
      );
    } catch (_) {
      if (mounted) _notice('书架状态保存失败，请重试。');
    } finally {
      if (mounted) setState(() => _favoriteBusy = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      _resumeSession();
    } else {
      _pauseSession();
    }
    if (state == AppLifecycleState.resumed) {
      _enterFullscreen();
      _repository?.platform.brightness(prefs.brightness);
      _updateStatus();
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _save();
    }
  }

  Future<void> _load({
    bool refresh = false,
    bool remoteUpdate = false,
    bool resumePrepared = false,
  }) async {
    await _pauseSession();
    if (!mounted) return;
    final epoch = ++_epoch;
    _preloader?.dispose();
    _preloader = null;
    if (!resumePrepared) {
      setState(() {
        _releaseOpeningPaper();
        _loading = true;
        _error = null;
      });
    }
    try {
      final repository = await ref.read(readerRepositoryProvider.future);
      final sync = await ref.read(syncRepositoryProvider.future);
      if (!mounted || epoch != _epoch) return;
      if (_repository != repository) setState(() => _repository = repository);
      if (_sync != sync) {
        await _remotePositions?.cancel();
        _remotePositions = sync.remotePositionAdvances.stream.listen(
          _queueRemote,
        );
        _sync = sync;
      }
      final library = await ref.read(localLibraryProvider.future);
      if (!mounted || epoch != _epoch) return;
      _session ??= ReadingSession(library, widget.book.metadata);
      _fonts = ReaderFonts();
      if (resumePrepared) {
        await repository.platform.brightness(prefs.brightness);
        if (!mounted || epoch != _epoch) return;
        _startWarm();
        _resumeSession();
        _moved();
        unawaited(_updateStatus());
        final remote = (await sync.record(
          widget.book.id,
          'position',
        ))?.effective;
        if (remote != null && mounted && !_exitPrepared) _queueRemote(remote);
        return;
      }
      if (_initializing) {
        final saved = await repository.read('preferences');
        if (!mounted) return;
        _preferences.value = saved == null
            ? ReaderPreferences(
                night: Theme.of(context).brightness == Brightness.dark,
              )
            : ReaderPreferences.fromJson(saved);
        try {
          _family = await _fonts!.load(prefs.font);
        } catch (_) {
          _preferences.value = prefs.copyWith(font: 'system');
        }
        await repository.platform.brightness(prefs.brightness);
        _initializing = false;
      }
      _source = repository.source(
        widget.book.metadata['sourceId'] as String,
        widget.book.metadata['detailUrl'] as String,
      );
      final catalog = await repository.catalog(
        _source!,
        widget.book.metadata['detailUrl'] as String,
        refresh: refresh,
      );
      final local = await repository.read(
        'position-${repository.key(widget.book.id)}',
      );
      final remote = (await sync.record(
        widget.book.id,
        'position',
      ))?.effective.payload;
      Map<String, dynamic> catalogPosition(Map<String, dynamic> p) {
        final i = catalog.chapters.indexWhere(
          (c) => urlKey(c.url) == urlKey(p['chapterUrl'] as String? ?? ''),
        );
        return i < 0
            ? p
            : {
                ...p,
                'chapterIndex': i,
                'chapterCount': catalog.chapters.length,
                'bookProgressChapterUrl': p['chapterUrl'],
              };
      }

      Map<String, dynamic>? position = remote;
      if (local != null &&
          (remote == null ||
              (compareBookPositions(
                        catalogPosition(local),
                        catalogPosition(remote),
                      ) ??
                      0) >
                  0)) {
        position = local;
      }
      final requestedUrl = _entryApplied ? null : widget.initialChapterUrl;
      final savedUrl = requestedUrl ?? position?['chapterUrl'] as String?;
      if (requestedUrl != null) position = null;
      var index = savedUrl == null
          ? 0
          : catalog.chapters.indexWhere(
              (c) => urlKey(c.url) == urlKey(savedUrl),
            );
      final missing = index < 0;
      if (missing) index = 0;
      final body = await repository.chapter(
        _source!,
        catalog.chapters[index],
        catalog.chapters,
        refresh: refresh,
      );
      if (!mounted || epoch != _epoch) return;
      var anchor = const TextAnchor(0, 0);
      if (!missing && position != null) {
        final paragraph = position['paragraphIndex'] as int?;
        if (position['contentHash'] == body.hash &&
            paragraph != null &&
            paragraph < body.paragraphs.length) {
          anchor = TextAnchor(
            paragraph,
            _utf16(
              body.paragraphs[paragraph],
              position['characterOffset'] as int? ?? 0,
            ),
          );
        } else {
          anchor = _anchorAtProgress(
            body,
            (position['progress'] as num?)?.toDouble() ?? 0,
          );
        }
      }
      _bottomClearance = await repository.platform.bottomClearance();
      if (!mounted || epoch != _epoch) return;
      final prepared = await _prepareEntryLayout(body, epoch);
      if (prepared == null) return;
      if (!mounted || epoch != _epoch || _exitPrepared) {
        prepared.dispose();
        return;
      }
      _invalidate();
      _layoutCache[_preparedKey(body)] = prepared;
      if (prefs.mode == PageMode.scroll) {
        // Attach the first scroll view at the final offset; never paint chapter
        // start and jump to the saved paragraph on the following frame.
        _replaceUnattachedScroll(prepared.scrollFor(anchor));
      }
      setState(() {
        _entryApplied = true;
        _catalog = catalog;
        _window
          ..clear()
          ..add((index, body));
        _chapterIndex = index;
        _scrollOrigin = index;
        _anchor = anchor;
        _pendingAnchor = anchor;
        _loading = false;
      });
      _startWarm();
      _resumeSession();
      if (!remoteUpdate) _moved(); // Receiving a position is not a new read.
      if (!_applyingRemote) unawaited(_applyRemote());
      _updateStatus();
      if (missing) {
        _notice(
          requestedUrl == null ? '上次章节不在当前目录中，已打开第一章。' : '指定章节不在当前目录中，已打开第一章。',
        );
      }
      if (catalog.warning.isNotEmpty) _notice(catalog.warning);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e is ReaderFailure ? e.message : '加载失败，请检查网络后重试。';
        });
      }
    }
  }

  Future<ReaderLayout?> _prepareEntryLayout(ReaderChapter body, int epoch) {
    final metrics = MediaQuery.of(context);
    final footer =
        metrics.viewPadding.bottom +
        ReaderStatusBar.heightFor(metrics.textScaler) +
        _bottomClearance +
        2;
    _layoutWidth = math.max(1.0, metrics.size.width - 48);
    _layoutHeight = math.max(
      1.0,
      metrics.size.height - footer - ReaderBottomFade.extent,
    );
    _layoutScaler = metrics.textScaler;
    return ReaderLayout.prepare(
      body,
      _layoutWidth!,
      _layoutHeight!,
      TextStyle(
        fontFamily: _family,
        fontSize: prefs.fontSize,
        height: 1.8,
        color: prefs.ink,
      ),
      metrics.textScaler,
      cancelled: () =>
          _disposed || !mounted || epoch != _epoch || _exitPrepared,
      yieldWork: () {
        final binding = SchedulerBinding.instance;
        final done = binding.endOfFrame;
        binding.ensureVisualUpdate();
        return done;
      },
    );
  }

  int _utf16(String text, int scalarOffset) =>
      String.fromCharCodes(text.runes.take(scalarOffset)).length;
  TextAnchor _anchorAtProgress(ReaderChapter body, double progress) {
    var remaining =
        (body.paragraphs.fold<int>(0, (sum, p) => sum + p.runes.length + 2) *
                progress.clamp(0, 1))
            .round();
    for (var i = 0; i < body.paragraphs.length; i++) {
      final length = body.paragraphs[i].runes.length;
      if (remaining <= length) {
        return TextAnchor(i, _utf16(body.paragraphs[i], remaining));
      }
      remaining -= length + 2;
    }
    final p = body.paragraphs.length - 1;
    return TextAnchor(p, body.paragraphs[p].length);
  }

  void _invalidate({bool keepPrepared = false}) {
    _layoutGeneration++;
    _retired.addAll(
      keepPrepared
          ? _layouts.where((l) => !_layoutCache.containsValue(l))
          : {..._layouts, ..._layoutCache.values},
    );
    _layouts.clear();
    if (!keepPrepared) _layoutCache.clear();
    _layoutKey = null;
  }

  void _releaseRetired() {
    if (_scrollActive && !_disposed) return;
    for (final item in _retired) {
      item.dispose();
    }
    _retired.clear();
  }

  String _preparedKey(ReaderChapter body) =>
      '$_layoutWidth/$_layoutHeight/${prefs.fontSize}/$_family/${prefs.ink.toARGB32()}/${_layoutScaler!.scale(20)}/${identityHashCode(body)}';

  void _ensureLayouts(double width, double height, TextScaler scaler) {
    final styleKey =
        '$width/$height/${prefs.fontSize}/$_family/${prefs.ink.toARGB32()}/${scaler.scale(20)}';
    if (_layoutStyleKey != styleKey) {
      _layoutGeneration++;
      _layoutStyleKey = styleKey;
    }
    _layoutWidth = width;
    _layoutHeight = height;
    _layoutScaler = scaler;
    _updateResampling();
    final key =
        '$width/$height/${prefs.fontSize}/$_family/${prefs.ink.toARGB32()}/${scaler.scale(20)}/${_window.map((e) => e.$1).join(',')}';
    if (_layoutKey == key) return;
    final reanchor = _pendingAnchor != null || _layoutKey == null;
    final anchor = _pendingAnchor ?? _anchor;
    final oldLayouts = List<ReaderLayout>.of(_layouts);
    _layouts.clear();
    _layoutKey = key;
    final style = TextStyle(
      fontFamily: _family,
      fontSize: prefs.fontSize,
      height: 1.8,
      color: prefs.ink,
    );
    for (final entry in _window) {
      final cacheKey = _preparedKey(entry.$2);
      _layouts.add(
        _layoutCache.putIfAbsent(
          cacheKey,
          () => ReaderLayout(entry.$2, width, height, style, scaler),
        ),
      );
    }
    final keep = {
      for (final e in _window) _preparedKey(e.$2),
      for (final e
          in _preloader?.chapters.entries ?? <MapEntry<int, ReaderChapter>>[])
        if ((e.key - _chapterIndex).abs() <= 2) _preparedKey(e.value),
    };
    _layoutCache.removeWhere((key, l) {
      if (keep.contains(key)) return false;
      if (!oldLayouts.contains(l)) _retired.add(l);
      return true;
    });
    _retired.addAll(
      oldLayouts.where(
        (l) => !_layouts.contains(l) && !_layoutCache.containsValue(l),
      ),
    );
    final origin = _window.indexWhere((e) => e.$1 == _scrollOrigin);
    _beforeBlocks = [for (final l in _layouts.take(origin)) ...l.blocks]
        .reversed
        .toList();
    _afterBlocks = [for (final l in _layouts.skip(origin)) ...l.blocks];
    _scheduleWarm();
    _page = layout!.pageFor(anchor);
    _anchor = anchor;
    _pendingAnchor = null;
    if (prefs.mode == PageMode.scroll && reanchor) {
      final top = _topFor(_chapterIndex) - _topFor(_scrollOrigin);
      _ignoreScroll = true;
      final target =
          top + (_pendingScrollWithinChapter ?? layout!.scrollFor(anchor));
      _pendingScrollWithinChapter = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) {
          _scroll.jumpTo(
            target.clamp(
              _scroll.position.minScrollExtent,
              _scroll.position.maxScrollExtent,
            ),
          );
        }
        _ignoreScroll = false;
      });
    }
    if (_flipFrom == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _flipFrom == null) _releaseRetired();
      });
    }
  }

  void _onScroll() {
    if (_ignoreScroll ||
        prefs.mode != PageMode.scroll ||
        _layouts.isEmpty ||
        !_scroll.hasClients) {
      return;
    }
    final absolute = _scroll.offset + _topFor(_scrollOrigin);
    var top = 0.0;
    for (var i = 0; i < _layouts.length; i++) {
      final l = _layouts[i];
      if (top + l.scrollHeight > absolute || i == _layouts.length - 1) {
        final anchor = l.anchorForScroll(
          (absolute - top).clamp(0, l.scrollHeight),
        );
        if (_chapterIndex != _window[i].$1 ||
            _anchor.paragraph != anchor.paragraph ||
            _anchor.offset != anchor.offset) {
          final changedChapter = _chapterIndex != _window[i].$1;
          _chapterIndex = _window[i].$1;
          _anchor = anchor;
          _page = l.pageFor(anchor);
          if (changedChapter || _tools) _readingVersion.value++;
          _moved();
          if (changedChapter) _scheduleWarm();
        }
        break;
      }
      top += l.scrollHeight;
    }
  }

  double _topFor(int chapterIndex) => _layouts
      .take(
        _window
            .indexWhere((e) => e.$1 == chapterIndex)
            .clamp(0, _layouts.length),
      )
      .fold<double>(0, (sum, l) => sum + l.scrollHeight);

  void _startWarm({Map<int, ReaderChapter> seed = const {}}) {
    _preloader?.dispose();
    if (chapter == null) return;
    _preloader = ReaderPreloader(_repository!, _source!, _catalog!.chapters, (
      _,
      _,
    ) {
      if (mounted && !_loading && prefs.mode == PageMode.scroll) {
        _queueWarmLayouts();
      }
    })..seed(_chapterIndex, chapter!);
    for (final entry in seed.entries) {
      if (entry.key >= _chapterIndex - 2 && entry.key <= _chapterIndex + 5) {
        _preloader!.seed(entry.key, entry.value);
      }
    }
    _preloader!.warm(_chapterIndex);
  }

  void _scheduleWarm() {
    if (_warmScheduled) return;
    _warmScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _warmScheduled = false;
      if (!mounted) return;
      _preloader?.warm(_chapterIndex);
      _queueWarmLayouts();
      _attachWarm();
      _releaseRetired();
    });
  }

  void _updateResampling() {
    const enabled = bool.fromEnvironment(
      'READER_RESAMPLING',
      // Select only after the real-device smoothness/latency A/B comparison.
      defaultValue: false,
    );
    final use =
        enabled &&
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android &&
        prefs.mode == PageMode.scroll;
    if (use && _previousResampling == null) {
      _previousResampling = GestureBinding.instance.resamplingEnabled;
      GestureBinding.instance.resamplingEnabled = true;
    } else if (!use && _previousResampling != null) {
      GestureBinding.instance.resamplingEnabled = _previousResampling!;
      _previousResampling = null;
    }
  }

  bool _scrollNotification(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is ScrollStartNotification) {
      _scrollActive = true;
      _repository?.readingBusy = true;
      _sync?.setReaderScrolling(true);
      _debounce?.cancel();
    } else if (notification is ScrollEndNotification) {
      _scrollActive = false;
      _repository?.readingBusy = false;
      _sync?.setReaderScrolling(false);
      if (_dirty) _moved();
      if (_pendingRemote != null) unawaited(_applyRemote());
      _scheduleWarm();
    }
    return false;
  }

  void _queueWarmLayouts() {
    if (_disposed || prefs.mode != PageMode.scroll || _layoutScaler == null) {
      return;
    }
    _warmAgain = true;
    if (_warmingLayouts != null) return;
    _warmingLayouts = _prepareWarmLayouts().whenComplete(() {
      _warmingLayouts = null;
    });
  }

  Future<void> _prepareWarmLayouts() async {
    try {
      do {
        _warmAgain = false;
        final generation = _layoutGeneration;
        final width = _layoutWidth!,
            height = _layoutHeight!,
            scaler = _layoutScaler!;
        final style = TextStyle(
          fontFamily: _family,
          fontSize: prefs.fontSize,
          height: 1.8,
          color: prefs.ink,
        );
        final candidates = [
          _chapterIndex - 1,
          _chapterIndex + 1,
          _chapterIndex - 2,
          _chapterIndex + 2,
        ];
        for (final index in candidates) {
          final body = _preloader?.chapters[index];
          if (_disposed || generation != _layoutGeneration) break;
          if (body == null) continue;
          final key = _preparedKey(body);
          if (_layoutCache.containsKey(key)) continue;
          final prepared = await ReaderLayout.prepare(
            body,
            width,
            height,
            style,
            scaler,
            cancelled: () =>
                _disposed ||
                generation != _layoutGeneration ||
                prefs.mode != PageMode.scroll,
            yieldWork: () {
              final binding = SchedulerBinding.instance;
              final done = binding.endOfFrame;
              // A batch can start in a post-frame callback. endOfFrame alone
              // does not request another frame in that phase.
              binding.ensureVisualUpdate();
              return done;
            },
          );
          if (prepared == null) break;
          if (_disposed ||
              generation != _layoutGeneration ||
              prefs.mode != PageMode.scroll) {
            prepared.dispose();
            break;
          }
          _layoutCache[key] = prepared;
          _attachWarm();
        }
      } while (_warmAgain && !_disposed && prefs.mode == PageMode.scroll);
    } catch (error, stack) {
      // A failed speculative layout must not remove the current chapter.
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'reader layout preload',
        ),
      );
    }
  }

  void _attachWarm() {
    if (prefs.mode != PageMode.scroll || chapter == null) return;
    if (_layoutScaler == null ||
        !_layoutCache.containsKey(_preparedKey(chapter!))) {
      return;
    }
    final bodies = {
      for (final e in _window) e.$1: e.$2,
      ...?_preloader?.chapters,
    };
    final indices = [_chapterIndex - 1, _chapterIndex, _chapterIndex + 1]
        .where(
          (i) =>
              bodies.containsKey(i) &&
              _layoutScaler != null &&
              _layoutCache.containsKey(_preparedKey(bodies[i]!)),
        )
        .toList();
    // Keep the coordinate system unchanged throughout a drag AND its fling.
    // Trim/rebase only after ScrollEnd; jumpTo would cancel ballistic activity.
    if (_scrollActive) {
      indices.addAll(
        _window.map((e) => e.$1).where((i) => !indices.contains(i)),
      );
      indices.sort();
    }
    if ((_scrollOrigin - _chapterIndex).abs() <= 2 &&
        bodies.containsKey(_scrollOrigin) &&
        !indices.contains(_scrollOrigin)) {
      indices.add(_scrollOrigin);
      indices.sort();
    }
    if (indices.join(',') == _window.map((e) => e.$1).join(',')) return;
    if (!indices.contains(_scrollOrigin)) {
      if (_scroll.hasClients) {
        _pendingScrollWithinChapter =
            _scroll.offset + _topFor(_scrollOrigin) - _topFor(_chapterIndex);
      }
      _scrollOrigin = _chapterIndex;
      _pendingAnchor = _anchor;
    }
    setState(
      () => _window
        ..clear()
        ..addAll(indices.map((i) => (i, bodies[i]!))),
    );
  }

  Future<void> _openChapter(
    int index, {
    bool last = false,
    ReaderLeaf? animateFrom,
    bool forward = true,
  }) async {
    if (index < 0 || index >= (_catalog?.chapters.length ?? 0) || _loading) {
      return;
    }
    await _save();
    if (!mounted) return;
    await _pauseSession();
    if (!mounted) return;
    final epoch = ++_epoch;
    final warmBodies = Map<int, ReaderChapter>.of(_preloader?.chapters ?? {});
    _preloader?.dispose();
    _preloader = null;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final body =
          warmBodies[index] ??
          await _repository!.chapter(
            _source!,
            _catalog!.chapters[index],
            _catalog!.chapters,
          );
      if (!mounted || epoch != _epoch) return;
      final anchor = last ? _anchorAtProgress(body, 1) : const TextAnchor(0, 0);
      if (animateFrom != null) _flip.value = 0;
      _invalidate(keepPrepared: true);
      setState(() {
        _window
          ..clear()
          ..add((index, body));
        _chapterIndex = index;
        _scrollOrigin = index;
        _anchor = anchor;
        _pendingAnchor = anchor;
        _loading = false;
        _tools = false;
        _flipFrom = animateFrom;
        _forward = forward;
      });
      _startWarm(seed: warmBodies);
      _attachWarm();
      if (animateFrom != null) _flip.forward();
      _moved();
      _resumeSession();
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        _notice(e is ReaderFailure ? e.message : '章节加载失败，请重试。');
        _startWarm(seed: warmBodies);
        _resumeSession();
      }
    }
  }

  Future<void> _turn(bool forward) async {
    if (_loading ||
        _flip.isAnimating ||
        layout == null ||
        prefs.mode == PageMode.scroll) {
      return;
    }
    final target = _page + (forward ? 1 : -1);
    if (target < 0 || target >= layout!.pageCount) {
      final index = _chapterIndex + (forward ? 1 : -1);
      if (index < 0 || index >= _catalog!.chapters.length) {
        _notice(forward ? '已到全书末尾' : '已经是第一章');
        return;
      }
      await _openChapter(
        index,
        last: !forward,
        animateFrom: prefs.mode == PageMode.curl ? layout!.pages[_page] : null,
        forward: forward,
      );
      return;
    }
    final from = layout!.pages[_page];
    setState(() {
      _page = target;
      _anchor = layout!.pages[target].anchor;
      _tools = false;
      if (prefs.mode == PageMode.curl) {
        _flipFrom = from;
        _forward = forward;
      }
    });
    if (prefs.mode == PageMode.curl) _flip.forward(from: 0);
    _moved();
  }

  void _tap(TapUpDetails details, double width) {
    if (_loading) return;
    if (prefs.mode == PageMode.scroll) {
      setState(() => _tools = !_tools);
      return;
    }
    if (_tools) {
      setState(() => _tools = false);
      return;
    }
    if (details.localPosition.dx < width / 3) {
      _turn(false);
    } else if (details.localPosition.dx > width * 2 / 3) {
      _turn(true);
    } else {
      setState(() => _tools = true);
    }
  }

  void _moved() {
    _dirty = true;
    _debounce?.cancel();
    if (!_scrollActive) {
      _debounce = Timer(const Duration(milliseconds: 650), _save);
    }
    // Bound possible progress loss even during a very long uninterrupted drag.
    _checkpoint ??= Timer(const Duration(seconds: 15), _save);
  }

  Future<void> _save() {
    if (!_scrollActive && !_applyingRemote && _pendingRemote != null) {
      scheduleMicrotask(_applyRemote);
    }
    _debounce?.cancel();
    _checkpoint?.cancel();
    _checkpoint = null;
    final body = chapter, repository = _repository, sync = _sync;
    if (!_dirty || body == null || repository == null || sync == null) {
      return _saves;
    }
    _dirty = false;
    final p = _anchor.paragraph.clamp(0, body.paragraphs.length - 1);
    final offset = _anchor.offset.clamp(0, body.paragraphs[p].length);
    final character = body.paragraphs[p].substring(0, offset).runes.length;
    final prefix = body.scalarStart(p) + character;
    final total = body.scalarLength;
    final payload = <String, dynamic>{
      ...widget.book.metadata,
      'chapterUrl': body.url,
      'chapterTitle': body.title,
      'chapterIndex': _chapterIndex,
      'chapterCount': _catalog!.chapters.length,
      'bookProgressChapterUrl': body.url,
      'paragraphIndex': p,
      'characterOffset': character,
      'contentHash': body.hash,
      'progress': (prefix / math.max(1, total)).clamp(0, 1),
      'active': true,
      'updatedUtc': DateTime.now().toUtc().toIso8601String(),
    };
    _saves = _saves
        .then((_) async {
          await repository.write(
            'position-${repository.key(widget.book.id)}',
            payload,
          );
          await sync.localChange(widget.book.id, 'position', payload);
          final recent = await sync.record(widget.book.id, 'recent');
          if (recent?.effective.payload['active'] != true) {
            await sync.localChange(widget.book.id, 'recent', {
              ...widget.book.metadata,
              'chapterUrl': '',
              'chapterTitle': '',
              'progress': 0,
              'active': true,
            });
          }
        })
        .catchError((Object error) {
          if (mounted) _notice('阅读位置保存失败，请稍后重试。');
        });
    return _saves;
  }

  void _changePreferences(ReaderPreferences next) {
    final changedMode = prefs.mode != next.mode;
    final reflow =
        prefs.fontSize != next.fontSize ||
        prefs.font != next.font ||
        changedMode;
    if (reflow || prefs.ink != next.ink) {
      _pendingAnchor = _anchor;
      _pendingScrollWithinChapter = !reflow && _scroll.hasClients
          ? _scroll.offset + _topFor(_scrollOrigin) - _topFor(_chapterIndex)
          : null;
    }
    if (changedMode) {
      _scrollActive = false;
      _repository?.readingBusy = false;
      _sync?.setReaderScrolling(false);
    }
    setState(() {
      _preferences.value = next;
      if (changedMode && chapter != null) {
        final body = chapter!;
        _window
          ..clear()
          ..add((_chapterIndex, body));
        _layoutKey = null;
        _scrollOrigin = _chapterIndex;
      }
    });
    if (changedMode) _scheduleWarm();
    _repository?.platform.brightness(next.brightness);
    _settingsSaves = _settingsSaves
        .then((_) => _repository!.write('preferences', next.toJson()))
        .catchError((Object e) {
          if (mounted) _notice('阅读设置保存失败。');
        });
  }

  Future<void> _settings() async {
    if (_fonts == null) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: false,
      backgroundColor: Colors.transparent,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .8,
      ),
      builder: (context) => ValueListenableBuilder(
        valueListenable: _preferences,
        builder: (context, p, _) => _sheetFrame(
          ReaderSettingsSheet(
            preferences: _preferences,
            onChanged: _changePreferences,
            fonts: _fonts!,
            onFont: () => _fontPicker(context),
          ),
          p,
        ),
      ),
    );
  }

  Widget _sheetFrame(Widget child, ReaderPreferences p) => Theme(
    data: _theme(p),
    child: Material(
      color: p.background,
      clipBehavior: Clip.antiAlias,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: p.ink.withValues(alpha: .35),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
          Flexible(child: child),
        ],
      ),
    ),
  );

  Future<void> _fontPicker(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: false,
      backgroundColor: Colors.transparent,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .85,
      ),
      builder: (context) => _sheetFrame(
        ReaderFontSheet(
          fonts: _fonts!,
          selected: prefs.font,
          onSelected: (id, family) {
            _family = family;
            _changePreferences(prefs.copyWith(font: id));
          },
        ),
        prefs,
      ),
    );
  }

  Future<void> _directory() async {
    if (_catalog == null) return;
    var refreshing = false;
    final scroll = ScrollController(
      initialScrollOffset: math.max(0, _chapterIndex * 56.0 - 100),
    );
    final result = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      showDragHandle: false,
      backgroundColor: Colors.transparent,
      builder: (context) => _sheetFrame(
        StatefulBuilder(
          builder: (context, update) => SafeArea(
            top: false,
            child: SizedBox(
              height: MediaQuery.sizeOf(context).height * .7,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '目录 · ${_catalog!.chapters.length} 章',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        IconButton(
                          tooltip: '刷新目录',
                          onPressed: refreshing
                              ? null
                              : () async {
                                  update(() => refreshing = true);
                                  try {
                                    final value = await _repository!.catalog(
                                      _source!,
                                      widget.book.metadata['detailUrl']
                                          as String,
                                      refresh: true,
                                    );
                                    if (mounted) {
                                      final currentUrl = chapter!.url;
                                      final active = value.chapters.indexWhere(
                                        (c) =>
                                            urlKey(c.url) == urlKey(currentUrl),
                                      );
                                      if (active < 0) {
                                        _notice('新目录未包含当前章节，已保留原目录。');
                                      } else {
                                        _pendingAnchor = _anchor;
                                        setState(() {
                                          final body = chapter!;
                                          _catalog = value;
                                          _chapterIndex = active;
                                          _scrollOrigin = active;
                                          _window
                                            ..clear()
                                            ..add((active, body));
                                          _layoutKey = null;
                                        });
                                        _startWarm();
                                        _moved();
                                      }
                                    }
                                    if (context.mounted) {
                                      update(() => refreshing = false);
                                    }
                                  } catch (_) {
                                    if (context.mounted) {
                                      update(() => refreshing = false);
                                    }
                                    if (mounted) _notice('目录刷新失败，请稍后重试。');
                                  }
                                },
                          icon: refreshing
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.refresh),
                        ),
                      ],
                    ),
                  ),
                  if (_catalog!.warning.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(_catalog!.warning),
                    ),
                  Expanded(
                    child: ListView.builder(
                      controller: scroll,
                      itemExtent: 56,
                      itemCount: _catalog!.chapters.length,
                      itemBuilder: (context, i) {
                        final active =
                            urlKey(_catalog!.chapters[i].url) ==
                            urlKey(chapter!.url);
                        return ListTile(
                          key: ValueKey('catalog-chapter-$i'),
                          selected:
                              urlKey(_catalog!.chapters[i].url) ==
                              urlKey(chapter!.url),
                          selectedColor: prefs.accent,
                          selectedTileColor: Colors.transparent,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20,
                          ),
                          leading: SizedBox(
                            width: 28,
                            child: Center(
                              child: active
                                  ? Icon(
                                      Icons.bookmark_outline_rounded,
                                      size: 20,
                                      color: prefs.accent,
                                    )
                                  : Text(
                                      '${i + 1}'.padLeft(2, '0'),
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: prefs.ink.withValues(alpha: .45),
                                      ),
                                    ),
                            ),
                          ),
                          trailing: active
                              ? Text(
                                  '正在读',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: prefs.accent,
                                    letterSpacing: .5,
                                  ),
                                )
                              : null,
                          title: Text(
                            _catalog!.chapters[i].title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 16,
                              color: active ? prefs.accent : prefs.ink,
                              fontWeight: active
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                          onTap: () => Navigator.pop(context, i),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        prefs,
      ),
    );
    scroll.dispose();
    if (result != null && mounted) await _openChapter(result);
  }

  Future<void> _leave() async {
    if (_exiting || !mounted) return;
    setState(() {
      _exiting = true;
      _tools = false;
    });
    _prepareExit();
    Navigator.of(context).pop();
  }

  void _notice(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(text), duration: const Duration(seconds: 3)),
      );
    }
  }

  ThemeData _theme(ReaderPreferences p) {
    final base = p.isDark ? AppTheme.dark : AppTheme.light;
    return base.copyWith(
      scaffoldBackgroundColor: p.background,
      colorScheme: base.colorScheme.copyWith(
        surface: p.background,
        surfaceContainerHighest: p.rail,
        surfaceContainerHigh: p.rail,
        surfaceContainer: p.background,
        surfaceTint: Colors.transparent,
        onSurface: p.ink,
        onSurfaceVariant: p.ink.withValues(alpha: .65),
        outline: p.ink.withValues(alpha: .4),
        primary: p.accent,
        onPrimary: p.isDark ? p.background : Colors.white,
        primaryContainer: p.rail,
        onPrimaryContainer: p.ink,
        secondaryContainer: p.selected,
        secondary: p.accent,
        onSecondaryContainer: p.ink,
        outlineVariant: p.ink.withValues(alpha: .12),
      ),
      sliderTheme: base.sliderTheme.copyWith(
        activeTrackColor: p.accent,
        inactiveTrackColor: p.rail,
        thumbColor: p.selected,
        overlayColor: p.accent.withValues(alpha: .1),
        trackHeight: 6,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(readerRepositoryProvider);
    if (_tools) _hasShownTools = true;
    _resumeMetrics = MediaQuery.of(context);
    final safe = MediaQuery.viewPaddingOf(context);
    final favorite =
        ref.watch(
          shelfBooksProvider.select(
            (value) => value
                .whenData(
                  (books) => books.any(
                    (book) => book.id == widget.book.id && book.favorite,
                  ),
                )
                .asData
                ?.value,
          ),
        ) ??
        widget.book.favorite;
    final reader = Theme(
      data: _theme(prefs),
      child: Builder(
        builder: (context) => PopScope(
          canPop: !_tools || _exiting,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop) {
              setState(() => _tools = false);
            } else {
              _prepareExit();
            }
          },
          child: Scaffold(
            body: LayoutBuilder(
              builder: (context, constraints) {
                const top = 0.0;
                final statusHeight = ReaderStatusBar.heightFor(
                  MediaQuery.textScalerOf(context),
                );
                final footerHeight =
                    safe.bottom + statusHeight + _bottomClearance + 2;
                final bottom = footerHeight + ReaderBottomFade.extent;
                final width = math.max(1.0, constraints.maxWidth - 48),
                    height = math.max(
                      1.0,
                      constraints.maxHeight - top - bottom,
                    );
                if (chapter != null) {
                  _ensureLayouts(
                    width,
                    height,
                    MediaQuery.textScalerOf(context),
                  );
                  final ready =
                      '$_layoutKey/${identityHashCode(chapter)}/$_chapterIndex';
                  if (!_loading && ready != _announcedPaper) {
                    _announcedPaper = ready;
                    if (_openingPaperImage == null) {
                      _paperScope?.prepareBodyRaster();
                    }
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted && !_loading && !_exitPrepared) {
                        BookPaperReady(
                          alreadyRasterized: _openingPaperImage != null,
                        ).dispatch(context);
                      }
                    });
                  }
                }
                return Stack(
                  children: [
                    if (_repository != null)
                      Positioned.fill(
                        child: ExcludeSemantics(
                          child: IgnorePointer(
                            child: ValueListenableBuilder(
                              valueListenable: _repository!.dynamicView,
                              builder: (context, controller, _) =>
                                  controller == null
                                  ? const SizedBox.shrink()
                                  : Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        WebViewWidget(controller: controller),
                                        ColoredBox(color: prefs.background),
                                      ],
                                    ),
                            ),
                          ),
                        ),
                      ),
                    if (chapter != null)
                      Positioned.fill(
                        child: GestureDetector(
                          key: const Key('reader-tap-surface'),
                          behavior: HitTestBehavior.opaque,
                          onTapUp: (details) =>
                              _tap(details, constraints.maxWidth),
                          child: GestureDetector(
                            key: const Key('reader-content'),
                            behavior: HitTestBehavior.opaque,
                            onHorizontalDragEnd: prefs.mode == PageMode.scroll
                                ? null
                                : (d) {
                                    if ((d.primaryVelocity ?? 0).abs() > 80) {
                                      _turn(d.primaryVelocity! < 0);
                                    }
                                  },
                            child: prefs.mode == PageMode.scroll
                                ? Padding(
                                    padding: EdgeInsets.fromLTRB(
                                      24,
                                      top,
                                      24,
                                      footerHeight,
                                    ),
                                    child:
                                        NotificationListener<
                                          ScrollNotification
                                        >(
                                          onNotification: _scrollNotification,
                                          child: _scrolling(),
                                        ),
                                  )
                                : AnimatedBuilder(
                                    animation: _flip,
                                    builder: (context, _) => Semantics(
                                      label:
                                          '${chapter!.title}，第 ${_page + 1} 页',
                                      child: RepaintBoundary(
                                        child: CustomPaint(
                                          painter: _flipFrom == null
                                              ? ScreenLeafPainter(
                                                  layout!.pages[_page],
                                                  prefs.background,
                                                  EdgeInsets.fromLTRB(
                                                    24,
                                                    top,
                                                    24,
                                                    bottom,
                                                  ),
                                                )
                                              : PaperCurlPainter(
                                                  from: _flipFrom!,
                                                  to: layout!.pages[_page],
                                                  progress: Curves
                                                      .easeInOutCubic
                                                      .transform(_flip.value),
                                                  forward: _forward,
                                                  paper: prefs.background,
                                                  insets: EdgeInsets.fromLTRB(
                                                    24,
                                                    top,
                                                    24,
                                                    bottom,
                                                  ),
                                                ),
                                          size: Size(
                                            constraints.maxWidth,
                                            constraints.maxHeight,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                          ),
                        ),
                      ),
                    if (_loading)
                      Positioned.fill(
                        child: ReaderLoadingPaper(
                          ink: prefs.ink,
                          accent: prefs.accent,
                        ),
                      ),
                    if (_error != null)
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.menu_book_outlined,
                                size: 42,
                                color: prefs.ink,
                              ),
                              const SizedBox(height: 16),
                              Text(_error!, textAlign: TextAlign.center),
                              const SizedBox(height: 20),
                              FilledButton.tonal(
                                onPressed: () => _load(refresh: true),
                                child: const Text('重试'),
                              ),
                              TextButton(
                                onPressed: _leave,
                                child: const Text('返回书架'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (chapter != null && prefs.mode != PageMode.scroll)
                      Positioned(
                        key: const Key('reader-page-tail'),
                        left: 24,
                        right: 24,
                        bottom: footerHeight,
                        height: ReaderBottomFade.extent,
                        child: IgnorePointer(
                          child: ExcludeSemantics(
                            child: ClipRect(
                              child: AnimatedBuilder(
                                animation: _flip,
                                builder: (context, _) {
                                  // Every actual page line remains above the fade.
                                  // The preview is repeated in full on the next page.
                                  final next = _page + 1 < layout!.pages.length
                                      ? layout!.pages[_page + 1]
                                      : _currentWindow + 1 < _layouts.length
                                      ? _layouts[_currentWindow + 1].pages.first
                                      : null;
                                  return next == null || _flip.isAnimating
                                      ? const SizedBox.shrink()
                                      : CustomPaint(painter: LeafPainter(next));
                                },
                              ),
                            ),
                          ),
                        ),
                      ),
                    Positioned(
                      key: const Key('reader-bottom-fade'),
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: ReaderBottomFade(
                        background: prefs.background,
                        footerHeight: footerHeight,
                      ),
                    ),
                    Positioned(
                      left: 24,
                      right: 24,
                      bottom: safe.bottom + _bottomClearance,
                      height: statusHeight,
                      child: ValueListenableBuilder(
                        valueListenable: _readingVersion,
                        builder: (context, _, _) => ReaderStatusBar(
                          level: _battery,
                          charging: _charging,
                          time: _time,
                          chapterTitle: chapter == null
                              ? ''
                              : RegExp(r'^第.+[章节回卷]').hasMatch(chapter!.title)
                              ? chapter!.title
                              : '第${_chapterIndex + 1}章 ${chapter!.title}',
                          ink: prefs.ink,
                        ),
                      ),
                    ),
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: _toolbar(
                        top: true,
                        child: SafeArea(
                          bottom: false,
                          child: SizedBox(
                            height: 60,
                            child: Row(
                              children: [
                                IconButton(
                                  tooltip: '返回书架',
                                  onPressed: _leave,
                                  icon: const Icon(
                                    Icons.arrow_back_ios_new_rounded,
                                    size: 22,
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    widget.book.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium,
                                  ),
                                ),
                                TextButton.icon(
                                  key: const Key('reader-favorite'),
                                  onPressed: _favoriteBusy
                                      ? null
                                      : _toggleFavorite,
                                  style: TextButton.styleFrom(
                                    foregroundColor: prefs.ink,
                                    textStyle: Theme.of(context)
                                        .textTheme
                                        .labelLarge
                                        ?.copyWith(fontSize: 12),
                                  ),
                                  icon: _favoriteBusy
                                      ? const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 1.5,
                                          ),
                                        )
                                      : Icon(
                                          favorite
                                              ? Icons.bookmark_rounded
                                              : Icons.bookmark_add_outlined,
                                          size: 18,
                                        ),
                                  label: Text(
                                    favorite ? '已在书架' : '添加到书架',
                                    maxLines: 1,
                                  ),
                                ),
                                const SizedBox(width: 8),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: _toolbar(
                        top: false,
                        child: ValueListenableBuilder(
                          valueListenable: _readingVersion,
                          builder: (context, _, _) => SafeArea(
                            top: false,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Row(
                                    children: [
                                      TextButton(
                                        onPressed: _chapterIndex > 0
                                            ? () => _openChapter(
                                                _chapterIndex - 1,
                                              )
                                            : null,
                                        child: const Text('上一章'),
                                      ),
                                      Expanded(
                                        child: Slider(
                                          key: const Key('reader-progress'),
                                          value: layout == null
                                              ? 0
                                              : layout!.pageCount <= 1
                                              ? 0
                                              : _page / (layout!.pageCount - 1),
                                          onChanged: layout == null
                                              ? null
                                              : (v) {
                                                  final target =
                                                      (v *
                                                              (layout!
                                                                      .pages
                                                                      .length -
                                                                  1))
                                                          .round();
                                                  setState(() {
                                                    _page = target;
                                                    _anchor = layout!
                                                        .anchorForPage(target);
                                                  });
                                                  if (prefs.mode ==
                                                          PageMode.scroll &&
                                                      _scroll.hasClients) {
                                                    final start =
                                                        _topFor(_chapterIndex) -
                                                        _topFor(_scrollOrigin);
                                                    _scroll.jumpTo(
                                                      (start +
                                                              layout!.scrollFor(
                                                                _anchor,
                                                              ))
                                                          .clamp(
                                                            _scroll
                                                                .position
                                                                .minScrollExtent,
                                                            _scroll
                                                                .position
                                                                .maxScrollExtent,
                                                          ),
                                                    );
                                                  }
                                                  _moved();
                                                },
                                        ),
                                      ),
                                      TextButton(
                                        onPressed:
                                            _catalog != null &&
                                                _chapterIndex + 1 <
                                                    _catalog!.chapters.length
                                            ? () => _openChapter(
                                                _chapterIndex + 1,
                                              )
                                            : null,
                                        child: const Text('下一章'),
                                      ),
                                    ],
                                  ),
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceAround,
                                    children: [
                                      _action('catalog', '目录', _directory),
                                      _action(
                                        prefs.night ? 'day' : 'night',
                                        prefs.night ? '日间' : '夜间',
                                        () => _changePreferences(
                                          prefs.copyWith(night: !prefs.night),
                                        ),
                                      ),
                                      _action('settings', '设置', _settings),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (!_tools &&
                        chapter == null &&
                        !_loading &&
                        _error == null)
                      Positioned(
                        top: safe.top,
                        left: 8,
                        child: IconButton(
                          onPressed: _leave,
                          icon: const Icon(Icons.arrow_back),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
    // The live reader stays attached and laid out at the exact saved offset.
    // Reuse the last closing plane during a warm opening, then reveal this
    // same subtree without another load, layout, or scroll restoration.
    final image = _openingPaperImage;
    return Stack(
      fit: StackFit.expand,
      children: [
        Offstage(offstage: image != null, child: reader),
        if (image != null)
          RawImage(
            key: const Key('reader-prepared-paper'),
            image: image,
            fit: BoxFit.fill,
            filterQuality: FilterQuality.low,
          ),
      ],
    );
  }

  Widget _toolbar({required bool top, required Widget child}) => IgnorePointer(
    ignoring: !_tools,
    child: ExcludeSemantics(
      excluding: !_tools,
      child: AnimatedSlide(
        offset: _tools ? Offset.zero : Offset(0, top ? -1 : 1),
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        child: Material(
          color: prefs.background,
          elevation: 0,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: top
                  ? null
                  : Border(
                      top: BorderSide(
                        color: prefs.ink.withValues(alpha: .22),
                        width: .5,
                      ),
                    ),
            ),
            child: child,
          ),
        ),
      ),
    ),
  );
  Widget _action(String icon, String text, VoidCallback onTap) => TextButton(
    onPressed: onTap,
    style: TextButton.styleFrom(
      foregroundColor: prefs.ink,
      minimumSize: const Size(76, 66),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ReaderAssetIcon(icon, color: prefs.ink),
        const SizedBox(height: 4),
        Text(text, style: const TextStyle(fontSize: 12)),
      ],
    ),
  );

  Widget _scrolling() {
    return CustomScrollView(
      controller: _scroll,
      center: _scrollCenterKey,
      physics: const ClampingScrollPhysics(),
      slivers: [
        ReaderScrollSliver(blocks: _beforeBlocks),
        ReaderScrollSliver(key: _scrollCenterKey, blocks: _afterBlocks),
        SliverToBoxAdapter(
          child: SizedBox(
            height: 48,
            child: Center(
              child: TextButton(
                onPressed: () => _preloader?.retry(),
                child: Text(
                  _window.last.$1 + 1 == _catalog!.chapters.length
                      ? '全书完'
                      : '后续章节正在预加载，点击可重试',
                  style: TextStyle(
                    fontSize: 12,
                    color: prefs.ink.withValues(alpha: .6),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    var keptLayout =
        !_loading && chapter != null && layout != null && _resumeMetrics != null
        ? layout
        : null;
    if (keptLayout != null) {
      final retainedPaper = !_hasShownTools && !_flip.isAnimating
          ? _paperScope?.cloneFrozenPaper()
          : null;
      final remembered = _resumeCache.remember(
        widget.book.id,
        ReaderResume(
          catalog: _catalog!,
          source: _source!,
          layout: keptLayout,
          preferences: prefs,
          family: _family,
          chapterIndex: _chapterIndex,
          anchor: _anchor,
          scrollWithinChapter:
              _closingScrollWithinChapter ??
              (prefs.mode == PageMode.scroll && _scroll.hasClients
                  ? _scroll.offset +
                        _topFor(_scrollOrigin) -
                        _topFor(_chapterIndex)
                  : null),
          metrics: _resumeMetrics!,
          bottomClearance: _bottomClearance,
          paperImage: retainedPaper,
          position: {
            'chapterUrl': chapter!.url,
            'chapterIndex': _chapterIndex,
            'chapterCount': _catalog!.chapters.length,
            'bookProgressChapterUrl': chapter!.url,
            'progress': _currentProgress(),
          },
        ),
      );
      if (!remembered) {
        retainedPaper?.dispose();
        keptLayout = null;
      }
    }
    _openingPaperImage?.dispose();
    _openingPaperImage = null;
    _session?.pause().ignore();
    _disposed = true;
    _remotePositions?.cancel();
    _routeAnimation?.removeStatusListener(_routeStatus);
    _layoutGeneration++;
    _scrollActive = false;
    _repository?.readingBusy = false;
    _sync?.setReaderScrolling(false);
    if (_previousResampling != null) {
      GestureBinding.instance.resamplingEnabled = _previousResampling!;
    }
    _save();
    _clock?.cancel();
    _debounce?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _repository?.platform.brightness(null);
    _restoreFullscreen();
    _scroll.dispose();
    _preloader?.dispose();
    _readingVersion.dispose();
    _flip.dispose();
    _preferences.dispose();
    for (final l in {..._layouts, ..._layoutCache.values, ..._retired}) {
      if (!identical(l, keptLayout)) l.dispose();
    }
    _retired.clear();
    super.dispose();
  }
}
