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
import '../../../data/imported_books.dart';
import '../../../data/sync_repository.dart';
import '../../../data/local_library.dart';
import '../../../data/reading_history.dart';
import '../../../design_system/components.dart';
import '../../../sync_engine/sync_model.dart';
import '../../bookshelf/presentation/book_opening.dart';
import '../data/local_reader_source.dart';
import '../data/reader_fonts.dart';
import '../data/reader_platform.dart';
import '../data/reader_preloader.dart';
import '../data/reader_repository.dart';
import '../data/reader_source.dart';
import 'reader_asset_icon.dart';
import 'reader_bottom_fade.dart';
import 'reader_curl.dart';
import 'reader_dock.dart';
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

final _brightnessSessionProvider = Provider((ref) => _ReaderBrightness());

class _ReaderBrightness {
  bool followsSystem = true;
  double manual = .5;

  double? get override => followsSystem ? null : manual;
}

class _CurlTurn {
  _CurlTurn({
    required this.size,
    required this.insets,
    required this.corner,
    required this.forward,
    required this.downY,
    required this.front,
    required this.underFooter,
    this.under,
    this.pendingChapter,
  });
  final Size size;
  final EdgeInsets insets;
  final Offset corner;
  final bool forward;
  final double downY;
  final ui.Picture front;
  final ReaderPageFooter underFooter;
  ui.Picture? under;
  final int? pendingChapter;
  bool? settlingCommit;

  double travel(Offset point) => forward ? corner.dx - point.dx : point.dx;
  Offset at(double distance, double y) =>
      Offset(forward ? corner.dx - distance : distance, y);

  Offset project(Offset point) {
    if (!forward || (downY > size.height / 2 && downY < size.height * 2 / 3)) {
      return Offset(point.dx, size.height);
    }
    if (downY > size.height / 3 && downY <= size.height / 2) {
      return Offset(point.dx, 1);
    }
    return point;
  }

  void dispose() {
    front.dispose();
    under?.dispose();
  }
}

class _ReaderPageState extends ConsumerState<ReaderPage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final _preferences = ValueNotifier(const ReaderPreferences());
  late final _ReaderBrightness _brightness;
  late ScrollController _scroll;
  late ReaderResumeCache _resumeCache;
  bool _loadStarted = false;
  MediaQueryData? _resumeMetrics;
  double? _closingScrollWithinChapter;
  String? _announcedPaper;
  BookPaperScope? _paperScope;
  ui.Image? _openingPaperImage;
  bool _hasShownTools = false;
  ReaderDockPanel _dockPanel = ReaderDockPanel.none;
  final _catalogScroll = ScrollController();
  bool _refreshingCatalog = false;
  double _navigationBottom = 0, _cornerRadius = 0;
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
    duration: const Duration(milliseconds: 800),
  );
  final _curlPoint = ValueNotifier(Offset.zero);
  _CurlTurn? _curl;
  Offset? _curlDown;
  bool _pageTurnPending = false;
  (Offset, Offset)? _curlSettle;
  Future<void>? _curlCompletion;
  int _curlGesture = 0;
  TextStyle? _footerTextStyle;
  Locale? _footerLocale;
  ReaderRepository? _repository;
  SyncRepository? _sync;
  StreamSubscription<SyncChange>? _remotePositions;
  StreamSubscription<ImportedBook>? _localPositionAdvances;
  StreamSubscription<String>? _localRemovals;
  LocalReaderSource? _localSource;
  PageMode _textMode = PageMode.curl;
  bool get _isLocal => widget.book.imported != null;
  bool get _comic => widget.book.imported?.comic == true;
  bool get _fitImages => prefs.mode != PageMode.scroll;
  Map<String, dynamic>? _pendingRemote;
  bool _applyingRemote = false;

  void _queueRemote(SyncChange event) {
    if (event.entityId == widget.book.id) _queuePosition(event.payload);
  }

  void _queuePosition(Map<String, dynamic> position) {
    if (_exiting || _exitPrepared || _disposed) return;
    _pendingRemote = position;
    unawaited(_applyRemote());
  }

  Future<void> _applyRemote() async {
    if (_loading ||
        _scrollActive ||
        _curl != null ||
        _pageTurnPending ||
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
          'progress': _comic ? 0 : _currentProgress(),
        };
        if ((compareBookPositions(event, current) ?? 0) <= 0) continue;
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
      _exiting = false;
  int _chapterIndex = 0, _page = 0;
  int _epoch = 0;
  int? _battery;
  bool _charging = false;
  final _footerBatteryImages = <String, ui.Image>{};
  DateTime _time = DateTime.now();
  TextAnchor _anchor = const TextAnchor(0, 0);
  TextAnchor? _pendingAnchor;
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
      final resume = !_isLocal && widget.initialChapterUrl == null
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
    _repository?.platform.brightness(null);
    _restoreFullscreen();
  }

  bool _favoriteBusy = false;
  double _bottomClearance = ReaderPlatform.fallbackBottomClearance;
  ReadingSession? _session;
  bool _foreground = true;
  int _sessionTicks = 0;

  @override
  void didChangeMetrics() async {
    final insets = await ReaderPlatform().windowInsets();
    if (!mounted || _exitPrepared) return;
    if (_navigationBottom != insets.navigation ||
        _cornerRadius != insets.radius) {
      setState(() {
        _navigationBottom = insets.navigation;
        _cornerRadius = insets.radius;
      });
    }
  }

  void _resumeSession() {
    if (_foreground && !_loading && chapter != null && _error == null) {
      _updateReadingPosition();
      _session?.resume();
    }
  }

  void _updateReadingPosition() {
    final body = chapter, catalog = _catalog;
    if (body == null || catalog == null) return;
    _session?.updatePosition(
      ReadingPosition(
        chapterUrl: body.url,
        chapterTitle: body.title,
        chapterIndex: _chapterIndex,
        chapterCount: catalog.chapters.length,
        progress: _currentProgress(),
      ),
    );
  }

  Future<void> _pauseSession() async {
    try {
      await _session?.pause();
    } catch (_) {
      if (mounted) _notice('阅读统计保存失败，请重试。');
    }
  }

  ReaderPreferences get prefs => _preferences.value;
  double get _bottomFadeExtent =>
      prefs.mode == PageMode.scroll ? ReaderBottomFade.extent : 0;
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
    _brightness = ref.read(_brightnessSessionProvider);
    _resumeCache = ref.read(readerResumeCacheProvider);
    _scroll = ScrollController();
    WidgetsBinding.instance.addObserver(this);
    _enterFullscreen();
    _scroll.addListener(_onScroll);
    _flip.addListener(() {
      final settle = _curlSettle;
      if (settle != null) {
        _curlPoint.value = _curl!.project(
          Offset.lerp(
            settle.$1,
            settle.$2,
            Curves.easeOutCubic.transform(_flip.value),
          )!,
        );
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
    final insets = await _repository?.platform.windowInsets();
    if (!mounted) return;
    final icon = readerBatteryIcon(battery?.level, battery?.charging ?? false);
    if (!_footerBatteryImages.containsKey(icon)) {
      try {
        final bytes = await rootBundle.load('assets/reader_icons/$icon.png');
        final codec = await ui.instantiateImageCodec(
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        );
        final frame = await codec.getNextFrame();
        codec.dispose();
        if (!mounted || _footerBatteryImages.containsKey(icon)) {
          frame.image.dispose();
        } else {
          _footerBatteryImages[icon] = frame.image;
        }
      } catch (_) {
        // A vector battery keeps the frozen footer readable if decoding fails.
      }
    }
    if (mounted) {
      _time = DateTime.now();
      _battery = battery?.level;
      _charging = battery?.charging ?? false;
      _readingVersion.value++;
      if (clearance != null) {
        setState(() {
          _bottomClearance = clearance;
          _navigationBottom = insets?.navigation ?? _navigationBottom;
          _cornerRadius = insets?.radius ?? _cornerRadius;
        });
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
      final active = _isLocal
          ? (await _localSource?.current())?.favorite ?? widget.book.favorite
          : (await sync.record(
                  widget.book.id,
                  'favorite',
                ))?.effective.payload['active'] ==
                true;
      await sync.setFavorite(widget.book, !active);
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
      if (!_exitPrepared) {
        _repository?.platform.brightness(_brightness.override);
      }
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
        await _localPositionAdvances?.cancel();
        await _localRemovals?.cancel();
        if (_isLocal) {
          final store = sync.importedBooks;
          if (store == null) throw const ReaderFailure('本地书存储不可用。');
          _localSource = LocalReaderSource(store, widget.book.imported!);
          _localPositionAdvances = sync.importedPositionAdvances.stream.listen((
            book,
          ) {
            final position = _localSource?.positionFor(book);
            if (position != null) _queuePosition(position);
          });
          _localRemovals = sync.importedBookRemovals.stream.listen((id) {
            if (mounted && id == widget.book.id) unawaited(_leave());
          });
        } else {
          _remotePositions = sync.remotePositionAdvances.stream.listen(
            _queueRemote,
          );
        }
        _sync = sync;
      }
      final library = await ref.read(localLibraryProvider.future);
      if (!mounted || epoch != _epoch || _exitPrepared) return;
      _session ??= ReadingSession(
        library,
        widget.book.metadata,
        bookId: widget.book.id,
      );
      _fonts = ReaderFonts();
      if (resumePrepared) {
        await repository.platform.brightness(_brightness.override);
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
        if (_comic) {
          _textMode = prefs.mode;
          final comic = await repository.read('comic-preferences');
          if (!mounted || epoch != _epoch || _exitPrepared) return;
          final mode = PageMode.values
              .where((value) => value.name == comic?['mode'])
              .firstOrNull;
          _preferences.value = prefs.copyWith(mode: mode ?? PageMode.scroll);
        }
        try {
          _family = await _fonts!.load(prefs.font);
        } catch (_) {
          _preferences.value = prefs.copyWith(font: 'system');
        }
        if (epoch != _epoch || _exitPrepared) return;
        await repository.platform.brightness(_brightness.override);
        _initializing = false;
      }
      if (!_isLocal) {
        _source = repository.source(
          widget.book.metadata['sourceId'] as String,
          widget.book.metadata['detailUrl'] as String,
        );
      }
      final catalog = await _readCatalog(refresh: refresh);
      final local = _isLocal
          ? null
          : await repository.read('position-${repository.key(widget.book.id)}');
      final remote = _isLocal
          ? await _localSource!.position()
          : (await sync.record(widget.book.id, 'position'))?.effective.payload;
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
      final body = await _readChapter(
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
      final insets = await repository.platform.windowInsets();
      _navigationBottom = insets.navigation;
      _cornerRadius = insets.radius;
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
      if (mounted && epoch == _epoch && !_exitPrepared) {
        setState(() {
          _loading = false;
          _error = e is ReaderFailure
              ? e.message
              : _isLocal
              ? '本地章节加载失败，请重试。'
              : '加载失败，请检查网络后重试。';
        });
      }
    }
  }

  Future<ReaderCatalog> _readCatalog({bool refresh = false}) =>
      _localSource?.catalog() ??
      _repository!.catalog(
        _source!,
        widget.book.metadata['detailUrl'] as String,
        refresh: refresh,
      );

  Future<ReaderChapter> _readChapter(
    ChapterLink link,
    List<ChapterLink> catalog, {
    bool refresh = false,
  }) =>
      _localSource?.chapter(link) ??
      _repository!.chapter(_source!, link, catalog, refresh: refresh);

  Future<ReaderLayout?> _prepareEntryLayout(ReaderChapter body, int epoch) {
    final metrics = MediaQuery.of(context);
    final footer =
        ReaderStatusBar.heightFor(metrics.textScaler) + _bottomClearance + 2;
    _layoutWidth = math.max(1.0, metrics.size.width - 48);
    _layoutHeight = math.max(
      1.0,
      metrics.size.height - footer - _bottomFadeExtent,
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
      fitImagesToPage: _fitImages,
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
      '$_layoutWidth/$_layoutHeight/${prefs.fontSize}/$_family/${prefs.ink.toARGB32()}/${_layoutScaler!.scale(20)}/$_fitImages/${identityHashCode(body)}';

  void _ensureLayouts(double width, double height, TextScaler scaler) {
    final styleKey =
        '$width/$height/${prefs.fontSize}/$_family/${prefs.ink.toARGB32()}/${scaler.scale(20)}/$_fitImages';
    if (_layoutStyleKey != styleKey) {
      _layoutGeneration++;
      _layoutStyleKey = styleKey;
    }
    _layoutWidth = width;
    _layoutHeight = height;
    _layoutScaler = scaler;
    _updateResampling();
    final key = '$styleKey/${_window.map((e) => e.$1).join(',')}';
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
          () => ReaderLayout(
            entry.$2,
            width,
            height,
            style,
            scaler,
            fitImagesToPage: _fitImages,
          ),
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _releaseRetired();
    });
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
    final catalog = _catalog!.chapters;
    _preloader = ReaderPreloader(
      catalog,
      (link) => _readChapter(link, catalog),
      (_, _) {
        if (mounted && !_loading) {
          _queueWarmLayouts();
        }
      },
      parallelism: _isLocal || _source!.dynamicPage ? 1 : 2,
    )..seed(_chapterIndex, chapter!);
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
      if (prefs.mode == PageMode.scroll && _window.isNotEmpty) {
        _preloader?.warm(
          _chapterIndex,
          before: math.max(2, _chapterIndex - _window.first.$1 + 1),
          after: math.max(5, _window.last.$1 - _chapterIndex + 1),
        );
      } else {
        _preloader?.warm(_chapterIndex);
      }
      _queueWarmLayouts();
      _attachWarm();
      _releaseRetired();
    });
  }

  void _updateResampling() {
    // Resampling aligns pointer samples to the vsync clock. Without it the
    // scroll offset follows raw touch events, so on a 120 Hz panel a slow drag
    // advances 0 px on one frame and several px on the next ("stuttering"
    // motion with a perfect frame rate). Build with
    // --dart-define=READER_RESAMPLING=false to A/B the old behaviour.
    const enabled = bool.fromEnvironment(
      'READER_RESAMPLING',
      defaultValue: true,
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
      if (notification.dragDetails != null && _tools) {
        setState(() {
          _tools = false;
          _dockPanel = ReaderDockPanel.none;
        });
      }
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
    if (_disposed || prefs.mode == PageMode.none || _layoutScaler == null) {
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
        final candidates = <int>{
          _chapterIndex - 1,
          _chapterIndex + 1,
          if (prefs.mode == PageMode.scroll) ...[
            _chapterIndex - 2,
            _chapterIndex + 2,
            _window.first.$1 - 1,
            _window.last.$1 + 1,
          ],
        };
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
            fitImagesToPage: _fitImages,
            cancelled: () =>
                _disposed ||
                generation != _layoutGeneration ||
                prefs.mode == PageMode.none,
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
              prefs.mode == PageMode.none) {
            prepared.dispose();
            break;
          }
          _layoutCache[key] = prepared;
          final turn = _curl;
          if (mounted &&
              !_exitPrepared &&
              turn != null &&
              turn.under == null &&
              turn.pendingChapter == index) {
            final page = turn.forward
                ? prepared.pages.first
                : prepared.pages.last;
            setState(() {
              turn.under = PaperCurlPainter.record(
                page,
                prefs.background,
                turn.insets,
                turn.size,
                footer: turn.underFooter.withChapterTitle(
                  _statusChapterTitle(prepared.chapter, index),
                ),
              );
            });
          }
          _attachWarm();
        }
      } while (_warmAgain && !_disposed && prefs.mode != PageMode.none);
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
      ...?_preloader?.chapters,
      for (final e in _window) e.$1: e.$2,
    };
    ReaderLayout? prepared(int index) {
      final body = bodies[index];
      return body == null ? null : _layoutCache[_preparedKey(body)];
    }

    // An adjacent chapter can be shorter than the viewport. Keep enough
    // consecutive content for the top anchor to reach it in either direction.
    final margin = _layoutHeight! * 1.5;
    var first = _chapterIndex, last = _chapterIndex;
    for (var extent = 0.0; extent < margin;) {
      final previous = prepared(first - 1);
      if (previous == null) break;
      first--;
      extent += previous.scrollHeight;
    }
    for (var extent = 0.0; extent < margin;) {
      final next = prepared(last + 1);
      if (next == null) break;
      last++;
      extent += next.scrollHeight;
    }
    // Keep the coordinate system unchanged throughout a drag AND its fling.
    // Trim/rebase only after ScrollEnd; jumpTo would cancel ballistic activity.
    if (_scrollActive) {
      first = math.min(first, _window.first.$1);
      last = math.max(last, _window.last.$1);
    }
    if ((_scrollOrigin - _chapterIndex).abs() <= 2) {
      first = math.min(first, _scrollOrigin);
      last = math.max(last, _scrollOrigin);
    }
    if (first == _window.first.$1 && last == _window.last.$1) return;
    if (_scrollOrigin < first || _scrollOrigin > last) {
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
        ..addAll([for (var i = first; i <= last; i++) (i, bodies[i]!)]),
    );
  }

  Future<void> _openChapter(
    int index, {
    bool last = false,
    ReaderLayout? prepared,
  }) async {
    if (index < 0 ||
        index >= (_catalog?.chapters.length ?? 0) ||
        _loading ||
        _exitPrepared) {
      return;
    }
    final epoch = ++_epoch;
    final saving = _save();
    final pausing = _pauseSession();
    // Both operations capture the outgoing position synchronously. A prepared
    // page can take over in the same frame that removes the curl painter.
    if (prepared == null) {
      setState(() {
        _loading = true;
        _error = null;
      });
      await saving;
      await pausing;
      if (!mounted || epoch != _epoch || _exitPrepared) return;
    }
    final warmBodies = Map<int, ReaderChapter>.of(_preloader?.chapters ?? {});
    _preloader?.dispose();
    _preloader = null;
    try {
      final body =
          prepared?.chapter ??
          warmBodies[index] ??
          await _readChapter(_catalog!.chapters[index], _catalog!.chapters);
      if (!mounted || epoch != _epoch || _exitPrepared) return;
      final anchor = last
          ? prepared?.pages.last.anchor ?? _anchorAtProgress(body, 1)
          : const TextAnchor(0, 0);
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
        _error = null;
        _tools = false;
        _dockPanel = ReaderDockPanel.none;
      });
      _startWarm(seed: warmBodies);
      _attachWarm();
      _moved();
      _resumeSession();
    } catch (e) {
      if (mounted && epoch == _epoch && !_exitPrepared) {
        setState(() => _loading = false);
        _notice(e is ReaderFailure ? e.message : '章节加载失败，请重试。');
        _startWarm(seed: warmBodies);
        _resumeSession();
      }
    }
  }

  bool get _canTurn =>
      !_loading &&
      !_pageTurnPending &&
      !_exitPrepared &&
      layout != null &&
      prefs.mode != PageMode.scroll;

  int _pageAfter(bool forward) => _page + (forward ? 1 : -1);
  int _chapterAfter(bool forward) => _chapterIndex + (forward ? 1 : -1);
  bool _hasPage(int page) => page >= 0 && page < layout!.pageCount;
  bool _hasChapter(int index) =>
      index >= 0 && index < _catalog!.chapters.length;

  ReaderLayout? _adjacentLayout(bool forward) {
    final body = _preloader?.chapters[_chapterAfter(forward)];
    return body == null ? null : _layoutCache[_preparedKey(body)];
  }

  Future<void> _advancePage(bool forward) async {
    final target = _pageAfter(forward);
    if (!_hasPage(target)) {
      final index = _chapterAfter(forward);
      if (_hasChapter(index)) {
        _pageTurnPending = true;
        try {
          await _openChapter(
            index,
            last: !forward,
            prepared: _adjacentLayout(forward),
          );
        } finally {
          _pageTurnPending = false;
        }
      } else {
        _notice(forward ? '已到全书末尾' : '已经是第一章');
      }
      return;
    }
    setState(() {
      _page = target;
      _anchor = layout!.pages[target].anchor;
      _tools = false;
      _dockPanel = ReaderDockPanel.none;
    });
    _moved();
  }

  double _statusInset(double width) =>
      math.max(64.0, math.max(_cornerRadius + 8, (width - 272) / 2));

  String _statusChapterTitle(ReaderChapter? body, int index) {
    final title = body?.title ?? _catalog!.chapters[index].title;
    return RegExp(r'^第.+[章节回卷]').hasMatch(title)
        ? title
        : '第${index + 1}章 $title';
  }

  ReaderPageFooter _pageFooter(Size size) {
    final scaler = MediaQuery.textScalerOf(context);
    final height = ReaderStatusBar.heightFor(scaler);
    final inset = _statusInset(size.width);
    return ReaderPageFooter(
      bounds: Rect.fromLTWH(
        inset,
        size.height - _bottomClearance - height,
        math.max(0, size.width - inset * 2),
        height,
      ),
      time: _time,
      chapterTitle: _statusChapterTitle(chapter, _chapterIndex),
      level: _battery,
      scaler: scaler,
      direction: Directionality.of(context),
      style: readerStatusTextStyle(
        _footerTextStyle ?? readerTheme(prefs).textTheme.bodySmall!,
        prefs.ink,
      ),
      locale: _footerLocale,
      batteryImage:
          _footerBatteryImages[readerBatteryIcon(_battery, _charging)],
    );
  }

  bool _beginCurl(bool forward, Offset down, Size size, EdgeInsets insets) {
    final page = _pageAfter(forward);
    final ReaderLeaf? next;
    ReaderChapter? otherChapter = chapter;
    final otherIndex = _hasPage(page) ? _chapterIndex : _chapterAfter(forward);
    if (_hasPage(page)) {
      next = layout!.pages[page];
    } else {
      if (!_hasChapter(_chapterAfter(forward))) return false;
      final adjacent = _adjacentLayout(forward);
      otherChapter = adjacent?.chapter;
      next = forward ? adjacent?.pages.first : adjacent?.pages.last;
    }
    final current = layout!.pages[_page];
    final from = forward ? current : next;
    final to = forward ? next : current;
    if (from == null) return false;
    final currentFooter = _pageFooter(size);
    final otherFooter = currentFooter.withChapterTitle(
      _statusChapterTitle(otherChapter, otherIndex),
    );
    final fromFooter = forward ? currentFooter : otherFooter;
    final toFooter = forward ? otherFooter : currentFooter;
    final corner = Offset(
      size.width,
      forward && down.dy <= size.height / 2 ? 0 : size.height,
    );
    setState(() {
      _tools = false;
      _dockPanel = ReaderDockPanel.none;
      _curl = _CurlTurn(
        size: size,
        insets: insets,
        corner: corner,
        forward: forward,
        downY: down.dy,
        front: PaperCurlPainter.record(
          from,
          prefs.background,
          insets,
          size,
          footer: fromFooter,
        ),
        underFooter: toFooter,
        pendingChapter: to == null ? _chapterAfter(true) : null,
        under: to == null
            ? null
            : PaperCurlPainter.record(
                to,
                prefs.background,
                insets,
                size,
                footer: toFooter,
              ),
      );
    });
    _curlPoint.value = _curl!.project(down);
    return true;
  }

  void _startCurlDrag(DragStartDetails details) {
    _curlDown = null;
    if (_curl != null ||
        (_loading && _curlCompletion == null) ||
        _exitPrepared) {
      return;
    }
    _curlGesture++;
    _curlDown = details.localPosition;
  }

  Future<void> _updateCurlDrag(
    DragUpdateDetails details,
    Size size,
    EdgeInsets insets,
  ) async {
    final gesture = _curlGesture;
    final completion = _curlCompletion;
    if (completion != null) await completion;
    if (!mounted || gesture != _curlGesture) return;
    final down = _curlDown;
    if (down == null || !_canTurn) return;
    final delta = details.localPosition - down;
    if (_curl == null &&
        (delta.dx.abs() < 8 || !_beginCurl(delta.dx < 0, down, size, insets))) {
      return;
    }
    final turn = _curl!;
    final travel = turn
        .travel(details.localPosition)
        .clamp(0.0, size.width * 2);
    _curlPoint.value = turn.project(turn.at(travel, details.localPosition.dy));
  }

  Future<void> _endCurlDrag({
    Offset velocity = Offset.zero,
    bool cancelled = false,
  }) async {
    final gesture = _curlGesture;
    final completion = _curlCompletion;
    if (completion != null) await completion;
    if (!mounted || gesture != _curlGesture) return;
    final down = _curlDown;
    _curlDown = null;
    final turn = _curl;
    if (down == null || turn == null) return;
    final slow = velocity.dx.abs() <= 100 && velocity.dy.abs() <= 100;
    final commit =
        !cancelled &&
        (slow
            ? turn.travel(_curlPoint.value) > turn.size.width / 2
            : turn.forward
            ? velocity.dx < 0
            : velocity.dx > 0);
    unawaited(_settleCurl(turn, commit));
  }

  Future<void> _settleCurl(_CurlTurn turn, bool commit) async {
    turn.settlingCommit = commit;
    final distance = commit
        ? turn.size.width * 2
        : turn.forward
        ? 0.0
        : -turn.size.width;
    final end = turn.project(turn.at(distance, turn.corner.dy));
    _curlSettle = (_curlPoint.value, end);
    if (!MediaQuery.disableAnimationsOf(context)) {
      try {
        await _flip.forward(from: 0).orCancel;
      } on TickerCanceled {
        if (mounted && _curl == turn) setState(_clearCurl);
        return;
      }
    } else {
      _curlPoint.value = end;
    }
    await _finishCurl(turn);
  }

  Future<void> _completeCurl(_CurlTurn turn) async {
    if (!mounted || _curl != turn) return;
    final advance = turn.settlingCommit == true && _canTurn;
    final acrossChapter = advance && !_hasPage(_pageAfter(turn.forward));
    setState(_clearCurl);
    if (advance) {
      await _advancePage(turn.forward);
      if (mounted && acrossChapter && layout == null) {
        // Chapter activation invalidates the old layout. New input resumes
        // after the frame that installs the prepared chapter, never against
        // the old chapter's page index or a temporarily absent layout.
        await WidgetsBinding.instance.endOfFrame;
      }
    }
    if (!mounted) return;
    if (_pendingRemote != null) unawaited(_applyRemote());
  }

  void _interruptCurl() {
    final turn = _curl;
    if (turn == null || turn.settlingCommit == null || _curlDown != null) {
      return;
    }
    // FramePager.dispatchTouchEvent(DOWN) calls L()/M(): abort the scroller,
    // settle its destination once, then let this new touch start the next turn.
    unawaited(_finishCurl(turn));
  }

  Future<void> _finishCurl(_CurlTurn turn) {
    if (!mounted || _curl != turn) return Future<void>.value();
    final completion = _completeCurl(turn);
    _curlCompletion = completion;
    unawaited(
      completion.whenComplete(() {
        if (identical(_curlCompletion, completion)) _curlCompletion = null;
      }),
    );
    return completion;
  }

  void _clearCurl() {
    final turn = _curl;
    _curl = null;
    _curlDown = null;
    _curlSettle = null;
    _flip.stop();
    if (turn != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => turn.dispose());
    }
  }

  void _tapPage(bool forward, Size size, EdgeInsets insets) {
    if (!_canTurn || _curl != null) return;
    if (prefs.mode == PageMode.none) {
      unawaited(_advancePage(forward));
      return;
    }
    if (!_beginCurl(
      forward,
      forward
          ? Offset(size.width * .9, size.height * .6)
          : Offset(24, size.height),
      size,
      insets,
    )) {
      if (_hasChapter(_chapterAfter(forward))) {
        _preloader?.retry();
        _queueWarmLayouts();
        _notice('正在准备上一章，请稍后再翻页。');
      } else {
        _notice(forward ? '已到全书末尾' : '已经是第一章');
      }
      return;
    }
    final turn = _curl!;
    unawaited(_settleCurl(turn, true));
  }

  Future<void> _tap(TapUpDetails details, Size size, EdgeInsets insets) async {
    final completion = _curlCompletion;
    if (completion != null) await completion;
    if (!mounted || _exitPrepared) return;
    if (_loading) return;
    if (prefs.mode == PageMode.scroll) {
      setState(() {
        _tools = !_tools;
        _dockPanel = ReaderDockPanel.none;
      });
      return;
    }
    if (_tools) {
      setState(() {
        _tools = false;
        _dockPanel = ReaderDockPanel.none;
      });
      return;
    }
    if (_curl != null) return;
    if (details.localPosition.dx < size.width / 3) {
      _tapPage(false, size, insets);
    } else if (details.localPosition.dx > size.width * 2 / 3) {
      _tapPage(true, size, insets);
    } else {
      setState(() => _tools = true);
    }
  }

  void _moved() {
    _updateReadingPosition();
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
          final local = widget.book.imported;
          if (local != null) {
            await _localSource?.store.updatePosition(
              local.hash,
              local.epoch,
              payload['chapterIndex'] as int,
              (payload['progress'] as num).toDouble(),
              anchor: payload,
            );
            return;
          }
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
      _clearCurl();
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
    _settingsSaves = _settingsSaves
        .then((_) async {
          if (_comic && changedMode) {
            await _repository!.write('comic-preferences', {
              'mode': next.mode.name,
            });
          }
          await _repository!.write(
            'preferences',
            (_comic ? next.copyWith(mode: _textMode) : next).toJson(),
          );
        })
        .catchError((Object e) {
          if (mounted) _notice('阅读设置保存失败。');
        });
  }

  void _settings() {
    if (_fonts != null) _showPanel(ReaderDockPanel.settings);
  }

  void _directory() {
    if (_catalog == null) return;
    _showPanel(ReaderDockPanel.catalog);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_catalogScroll.hasClients) {
        _catalogScroll.jumpTo(
          (_chapterIndex * 52.0 - 100).clamp(
            0,
            _catalogScroll.position.maxScrollExtent,
          ),
        );
      }
    });
  }

  void _showPanel(ReaderDockPanel panel) => setState(() {
    _dockPanel = _dockPanel == panel ? ReaderDockPanel.none : panel;
  });

  void _panelBack() => setState(() {
    if (_dockPanel == ReaderDockPanel.fonts) {
      _dockPanel = ReaderDockPanel.settings;
    } else if (_dockPanel != ReaderDockPanel.none) {
      _dockPanel = ReaderDockPanel.none;
    } else {
      _tools = false;
      _dockPanel = ReaderDockPanel.none;
    }
  });

  Future<void> _refreshCatalog() async {
    if (_refreshingCatalog || _repository == null || chapter == null) return;
    setState(() => _refreshingCatalog = true);
    try {
      final value = await _readCatalog(refresh: true);
      if (!mounted) return;
      final currentUrl = chapter!.url;
      final active = value.chapters.indexWhere(
        (c) => urlKey(c.url) == urlKey(currentUrl),
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
    } catch (_) {
      if (mounted) _notice('目录刷新失败，请稍后重试。');
    } finally {
      if (mounted) setState(() => _refreshingCatalog = false);
    }
  }

  Widget _dockBody(BuildContext context, double maxHeight) {
    final title = switch (_dockPanel) {
      ReaderDockPanel.catalog => '目录 · ${_catalog?.chapters.length ?? 0} 章',
      ReaderDockPanel.settings => '阅读设置',
      ReaderDockPanel.fonts => '选择字体',
      ReaderDockPanel.none => '',
    };
    return ConstrainedBox(
      key: const Key('reader-dock-panel'),
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 6, 10, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                if (_dockPanel == ReaderDockPanel.catalog)
                  IconButton(
                    tooltip: '刷新目录',
                    onPressed: _refreshingCatalog ? null : _refreshCatalog,
                    icon: _refreshingCatalog
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh_rounded, size: 20),
                  ),
                IconButton(
                  tooltip: _dockPanel == ReaderDockPanel.fonts
                      ? '返回设置'
                      : '收起面板',
                  onPressed: _panelBack,
                  icon: Icon(
                    _dockPanel == ReaderDockPanel.fonts
                        ? Icons.arrow_back_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 22,
                  ),
                ),
              ],
            ),
          ),
          Flexible(
            child: switch (_dockPanel) {
              ReaderDockPanel.settings => ReaderSettingsSheet(
                followsSystemBrightness: _brightness.followsSystem,
                manualBrightness: _brightness.manual,
                onToggleBrightness: () {
                  setState(() {
                    _brightness.followsSystem = !_brightness.followsSystem;
                  });
                  _repository?.platform.brightness(_brightness.override);
                },
                onBrightnessChanged: (value) {
                  setState(() => _brightness.manual = value);
                  _repository?.platform.brightness(_brightness.override);
                },
                preferences: _preferences,
                onChanged: _changePreferences,
                fonts: _fonts!,
                onFont: () => _showPanel(ReaderDockPanel.fonts),
              ),
              ReaderDockPanel.fonts => ReaderFontSheet(
                fonts: _fonts!,
                selected: prefs.font,
                onSelected: (id, family) {
                  _family = family;
                  _changePreferences(prefs.copyWith(font: id));
                  setState(() => _dockPanel = ReaderDockPanel.settings);
                },
              ),
              ReaderDockPanel.catalog => _catalogContent(maxHeight - 54),
              ReaderDockPanel.none => const SizedBox.shrink(),
            },
          ),
        ],
      ),
    );
  }

  Widget _catalogContent(double height) => SizedBox(
    height: math.max(40, height),
    child: Column(
      children: [
        if (_catalog!.warning.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              _catalog!.warning,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        Expanded(
          child: ListView.builder(
            key: const Key('reader-dock-catalog'),
            controller: _catalogScroll,
            itemExtent: 52,
            itemCount: _catalog!.chapters.length,
            itemBuilder: (context, i) {
              final active =
                  chapter != null &&
                  urlKey(_catalog!.chapters[i].url) == urlKey(chapter!.url);
              return ListTile(
                key: ValueKey('catalog-chapter-$i'),
                selected: active,
                selectedColor: prefs.accent,
                selectedTileColor: Colors.transparent,
                contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                leading: SizedBox(
                  width: 26,
                  child: Center(
                    child: active
                        ? Icon(
                            Icons.bookmark_outline_rounded,
                            size: 18,
                            color: prefs.accent,
                          )
                        : Text(
                            '${i + 1}'.padLeft(2, '0'),
                            style: TextStyle(
                              fontSize: 11,
                              color: prefs.ink.withValues(alpha: .45),
                            ),
                          ),
                  ),
                ),
                trailing: active
                    ? Text(
                        '正在读',
                        style: TextStyle(fontSize: 11, color: prefs.accent),
                      )
                    : null,
                title: Text(
                  _catalog!.chapters[i].title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    color: active ? prefs.accent : prefs.ink,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
                onTap: () {
                  setState(() {
                    _dockPanel = ReaderDockPanel.none;
                    _tools = false;
                    _dockPanel = ReaderDockPanel.none;
                  });
                  unawaited(_openChapter(i));
                },
              );
            },
          ),
        ),
      ],
    ),
  );

  Widget _dockControls() => ReaderDockControls(
    preferences: prefs,
    progress: (layout?.pageCount ?? 0) <= 1
        ? 0
        : _page / (layout!.pageCount - 1),
    onPrevious: _chapterIndex > 0
        ? () => _openChapter(_chapterIndex - 1)
        : null,
    onNext: _catalog != null && _chapterIndex + 1 < _catalog!.chapters.length
        ? () => _openChapter(_chapterIndex + 1)
        : null,
    onProgressChanged: layout == null
        ? null
        : (v) {
            final target = (v * (layout!.pages.length - 1)).round();
            setState(() {
              _page = target;
              _anchor = layout!.anchorForPage(target);
            });
            if (prefs.mode == PageMode.scroll && _scroll.hasClients) {
              final start = _topFor(_chapterIndex) - _topFor(_scrollOrigin);
              _scroll.jumpTo(
                (start + layout!.scrollFor(_anchor)).clamp(
                  _scroll.position.minScrollExtent,
                  _scroll.position.maxScrollExtent,
                ),
              );
            }
            _moved();
          },
    actions: [
      _action('catalog', '目录', _directory),
      _action(
        prefs.night ? 'day' : 'night',
        prefs.night ? '日间' : '夜间',
        () => _changePreferences(prefs.copyWith(night: !prefs.night)),
      ),
      _action('settings', '设置', _settings),
    ],
  );

  Future<void> _leave() async {
    if (_exiting || !mounted) return;
    setState(() {
      _exiting = true;
      _tools = false;
      _dockPanel = ReaderDockPanel.none;
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
      data: readerTheme(prefs),
      child: Builder(
        builder: (context) => PopScope(
          canPop: !_tools || _exiting,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop) {
              _panelBack();
            } else {
              _prepareExit();
            }
          },
          child: Scaffold(
            body: LayoutBuilder(
              builder: (context, constraints) {
                // Theme.of resolves the locale-specific typography used by Text.
                // The recorded footer must use this same resolved style.
                _footerTextStyle = Theme.of(context).textTheme.bodySmall!;
                if (MediaQuery.boldTextOf(context)) {
                  _footerTextStyle = _footerTextStyle!.copyWith(
                    fontWeight: FontWeight.bold,
                  );
                }
                _footerLocale = Localizations.maybeLocaleOf(context);
                const top = 0.0;
                final statusHeight = ReaderStatusBar.heightFor(
                  MediaQuery.textScalerOf(context),
                );
                final footerHeight = statusHeight + _bottomClearance + 2;
                final dockBottom = AppSpacing.dockBottom(
                  context,
                  navigationInset: _navigationBottom,
                );
                final panelHeight = math.max(
                  80.0,
                  math.min(
                    constraints.maxHeight * .58,
                    constraints.maxHeight - safe.top - dockBottom - 174,
                  ),
                );
                final bottom = footerHeight + _bottomFadeExtent;
                final size = Size(constraints.maxWidth, constraints.maxHeight);
                final insets = EdgeInsets.fromLTRB(24, top, 24, bottom);
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
                          onTapUp: (details) => _tap(details, size, insets),
                          child: GestureDetector(
                            key: const Key('reader-content'),
                            behavior: HitTestBehavior.opaque,
                            dragStartBehavior: DragStartBehavior.down,
                            onPanStart: prefs.mode == PageMode.curl
                                ? _startCurlDrag
                                : null,
                            onPanUpdate: prefs.mode == PageMode.curl
                                ? (details) =>
                                      _updateCurlDrag(details, size, insets)
                                : null,
                            onPanEnd: prefs.mode == PageMode.curl
                                ? (details) => _endCurlDrag(
                                    velocity: details.velocity.pixelsPerSecond,
                                  )
                                : null,
                            onPanCancel: prefs.mode == PageMode.curl
                                ? () => _endCurlDrag(cancelled: true)
                                : null,
                            onHorizontalDragStart: prefs.mode == PageMode.none
                                ? (_) {
                                    if (_tools) {
                                      setState(() {
                                        _tools = false;
                                        _dockPanel = ReaderDockPanel.none;
                                      });
                                    }
                                  }
                                : null,
                            onHorizontalDragEnd: prefs.mode == PageMode.none
                                ? (details) {
                                    final speed = details.primaryVelocity ?? 0;
                                    if (_canTurn && speed.abs() > 80) {
                                      unawaited(_advancePage(speed < 0));
                                    }
                                  }
                                : null,
                            child: Listener(
                              onPointerDown: prefs.mode == PageMode.curl
                                  ? (event) {
                                      if (event.buttons == kPrimaryButton) {
                                        _interruptCurl();
                                      }
                                    }
                                  : null,
                              onPointerCancel: prefs.mode == PageMode.curl
                                  ? (_) => _endCurlDrag(cancelled: true)
                                  : null,
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
                                  : Semantics(
                                      label:
                                          '${chapter!.title}，第 ${_page + 1} 页',
                                      child: RepaintBoundary(
                                        child: ValueListenableBuilder<Offset>(
                                          valueListenable: _curlPoint,
                                          builder: (context, finger, _) {
                                            final turn = _curl;
                                            return CustomPaint(
                                              willChange: turn != null,
                                              painter: turn == null
                                                  ? ScreenLeafPainter(
                                                      layout!.pages[_page],
                                                      prefs.background,
                                                      insets,
                                                    )
                                                  : PaperCurlPainter(
                                                      front: turn.front,
                                                      under: turn.under,
                                                      corner: turn.corner,
                                                      finger: finger,
                                                      paper: prefs.background,
                                                      pixelRatio:
                                                          MediaQuery.devicePixelRatioOf(
                                                            context,
                                                          ),
                                                    ),
                                              size: size,
                                            );
                                          },
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
                    if (prefs.mode == PageMode.scroll)
                      Positioned(
                        key: const Key('reader-bottom-fade'),
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: ReaderBottomFade(
                          background: prefs.background,
                          footerHeight: _tools
                              ? math.max(footerHeight, dockBottom)
                              : footerHeight,
                        ),
                      ),
                    Positioned(
                      left: _statusInset(constraints.maxWidth),
                      right: _statusInset(constraints.maxWidth),
                      bottom: _bottomClearance,
                      height: statusHeight,
                      child: Opacity(
                        key: const Key('reader-status-overlay'),
                        opacity:
                            _curl == null &&
                                (!_tools || dockBottom >= footerHeight)
                            ? 1
                            : 0,
                        alwaysIncludeSemantics: true,
                        child: ValueListenableBuilder(
                          valueListenable: _readingVersion,
                          builder: (context, _, _) => ReaderStatusBar(
                            level: _battery,
                            charging: _charging,
                            time: _time,
                            chapterTitle: chapter == null
                                ? ''
                                : _statusChapterTitle(chapter, _chapterIndex),
                            ink: prefs.ink,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: ReaderToolbar(
                        visible: _tools,
                        background: prefs.background,
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
                                    favorite ? '已在收藏' : '添加到收藏',
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
                      child: ReaderDock(
                        visible: _tools,
                        preferences: prefs,
                        bottom: dockBottom,
                        panel: _dockPanel == ReaderDockPanel.none
                            ? null
                            : _dockBody(context, panelHeight),
                        controls: ValueListenableBuilder(
                          valueListenable: _readingVersion,
                          builder: (context, _, _) => _dockControls(),
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

  Widget _action(String icon, String text, VoidCallback onTap) =>
      ReaderDockAction(
        icon: ReaderAssetIcon(icon, color: prefs.ink, size: 20),
        label: text,
        onPressed: onTap,
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
        !_isLocal &&
            !_loading &&
            chapter != null &&
            layout != null &&
            _resumeMetrics != null
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
    _localPositionAdvances?.cancel();
    _localRemovals?.cancel();
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
    if (!_exitPrepared) _repository?.platform.brightness(null);
    _restoreFullscreen();
    _catalogScroll.dispose();
    _scroll.dispose();
    _preloader?.dispose();
    _readingVersion.dispose();
    _curl?.dispose();
    for (final image in _footerBatteryImages.values) {
      image.dispose();
    }
    _footerBatteryImages.clear();
    _curlPoint.dispose();
    _flip.dispose();
    _preferences.dispose();
    for (final l in {..._layouts, ..._layoutCache.values, ..._retired}) {
      if (!identical(l, keptLayout)) l.dispose();
    }
    _retired.clear();
    super.dispose();
  }
}
