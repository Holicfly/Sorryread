import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dependencies.dart';
import '../../../data/local_library.dart';
import '../../../data/reading_history.dart';
import '../../../data/sync_repository.dart';
import '../../../design_system/components.dart';
import '../../reader/data/reader_platform.dart';
import '../../reader/data/reader_source.dart';
import '../../reader/presentation/reader_asset_icon.dart';
import '../../reader/presentation/reader_dock.dart';
import '../../reader/presentation/reader_preferences.dart';
import '../../reader/presentation/reader_settings_sheet.dart';
import '../data/yeshe_comic.dart';

class ComicReaderPage extends ConsumerStatefulWidget {
  const ComicReaderPage({super.key, required this.book, this.chapterUrl});
  final ShelfBook book;
  final String? chapterUrl;

  @override
  ConsumerState<ComicReaderPage> createState() => _ComicReaderPageState();
}

class _ComicReaderPageState extends ConsumerState<ComicReaderPage>
    with WidgetsBindingObserver {
  static const _preferencesKey = 'yeshe-comic-preferences';
  final _preferences = ValueNotifier(
    const ReaderPreferences(mode: PageMode.scroll),
  );
  final _platform = ReaderPlatform();
  ScrollController? _scroll;
  ComicRepository? _repository;
  ComicDetail? _detail;
  SyncRepository? _sync;
  ReadingSession? _session;
  List<String> _pages = const [];
  int _chapter = 0, _page = 0, _chapterRequest = 0;
  double _ratio = 1.4, _extent = 1, _brightness = .5;
  double _navigationBottom = 0;
  bool _loading = true, _tools = false, _systemBrightness = true;
  bool _foreground = true, _dirty = false, _favoriting = false;
  String? _error;
  bool _retryDetail = true;
  Timer? _debounce, _checkpoint;
  Future<void> _writes = Future.value(), _settingsWrites = Future.value();
  ReaderDockPanel _panel = ReaderDockPanel.none;

  ShelfBook get _book => _detail?.book.toShelfBook() ?? widget.book;
  List<ChapterLink> get _chapters => _detail?.chapters ?? const [];
  double get _progress => _pages.length <= 1 ? 0 : _page / (_pages.length - 1);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky)
          .then((_) async {
            if (!mounted) return;
            await _platform.fullscreen(true);
            await _refreshNavigationInset();
          }),
    );
    unawaited(_initialize());
  }

  Future<void> _refreshNavigationInset() async {
    final insets = await _platform.windowInsets();
    if (mounted && _navigationBottom != insets.navigation) {
      setState(() => _navigationBottom = insets.navigation);
    }
  }

  @override
  void didChangeMetrics() => unawaited(_refreshNavigationInset());

  Future<void> _initialize() async {
    setState(() {
      _loading = true;
      _error = null;
      _retryDetail = true;
    });
    try {
      final (repository, sync, library) = await (
        ref.read(comicRepositoryProvider.future),
        ref.read(syncRepositoryProvider.future),
        ref.read(localLibraryProvider.future),
      ).wait;
      final (detail, position, settings) = await (
        repository.detail(widget.book.metadata['detailUrl'] as String),
        sync.record(widget.book.id, 'position'),
        repository.reader.read(_preferencesKey),
      ).wait;
      if (!mounted) return;
      _repository = repository;
      _sync = sync;
      _detail = detail;
      _session = ReadingSession(library, _book.metadata, bookId: _book.id);
      _preferences.value = settings == null
          ? ReaderPreferences(
              night: Theme.of(context).brightness == Brightness.dark,
              mode: PageMode.scroll,
            )
          : ReaderPreferences.fromJson(settings)
                .copyWith(mode: PageMode.scroll);
      _systemBrightness = settings?['systemBrightness'] != false;
      _brightness = ((settings?['brightness'] as num?)?.toDouble() ?? .5).clamp(
        .02,
        1,
      );
      unawaited(_platform.brightness(_systemBrightness ? null : _brightness));
      final saved = position?.effective.payload;
      final target = widget.chapterUrl ?? saved?['chapterUrl'];
      final index = _chapters.indexWhere((chapter) => chapter.url == target);
      if (index < 0 && widget.chapterUrl != null) {
        _showError('这个章节已不在漫画目录中。');
        return;
      }
      final resume = index >= 0 && saved?['chapterUrl'] == target
          ? (saved?['comicPage'] as int? ?? 0)
          : 0;
      await _loadChapter(math.max(0, index), resume: resume);
    } catch (error) {
      _showError(error is ReaderFailure ? error.message : '漫画详情加载失败，请重试。');
    }
  }

  Future<void> _loadChapter(int index, {int resume = 0}) async {
    final request = ++_chapterRequest;
    _save();
    unawaited(_session?.pause());
    setState(() {
      _loading = true;
      _error = null;
      _retryDetail = false;
      _chapter = index;
      _page = resume;
      _pages = const [];
      _panel = ReaderDockPanel.none;
    });
    try {
      final pages = await _repository!.pages(_chapters[index].url);
      if (!mounted || request != _chapterRequest) return;
      final page = resume.clamp(0, pages.length - 1);
      final ratio = await _pageRatio(pages[page]);
      if (!mounted || request != _chapterRequest) return;
      final extent = math.min(840.0, MediaQuery.sizeOf(context).width) * ratio;
      _scroll?.dispose();
      final scroll = ScrollController(
        initialScrollOffset: extent * page,
        keepScrollOffset: false,
      )..addListener(_onScroll);
      setState(() {
        _scroll = scroll;
        _extent = extent;
        _ratio = ratio;
        _page = page;
        _pages = pages;
        _loading = false;
      });
      _positionChanged();
      _save();
      if (_foreground) _session?.resume();
    } catch (error) {
      if (request != _chapterRequest) return;
      _showError(error is ReaderFailure ? error.message : '漫画章节加载失败，请重试。');
    }
  }

  Future<double> _pageRatio(String url) async {
    try {
      final file = await _repository!.image(url);
      final buffer = await ui.ImmutableBuffer.fromFilePath(file.path);
      try {
        final image = await ui.ImageDescriptor.encoded(buffer);
        try {
          return (image.height / image.width).clamp(.35, 3.5);
        } finally {
          image.dispose();
        }
      } finally {
        buffer.dispose();
      }
    } catch (_) {
      // The page remains independently retryable.
      return 1.4;
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() {
      _error = message;
      _loading = false;
    });
  }

  void _onScroll() {
    final position = _scroll?.position;
    if (position == null || _pages.isEmpty || !position.hasContentDimensions) {
      return;
    }
    final page =
        (position.extentAfter <= 1 && position.maxScrollExtent > 0
                ? _pages.length - 1
                : ((position.pixels +
                              math.min(position.viewportDimension, _extent) *
                                  .2) /
                          _extent)
                      .floor())
            .clamp(0, _pages.length - 1);
    if (page == _page) return;
    setState(() => _page = page);
    _positionChanged();
  }

  void _jump(int page) {
    final scroll = _scroll;
    if (scroll == null || !scroll.hasClients) return;
    scroll.jumpTo((_extent * page).clamp(0, scroll.position.maxScrollExtent));
    if (_page != page) {
      setState(() => _page = page);
      _positionChanged();
    }
  }

  void _positionChanged() {
    final chapter = _chapters[_chapter];
    _session?.updatePosition(
      ReadingPosition(
        chapterUrl: chapter.url,
        chapterTitle: chapter.title,
        chapterIndex: _chapter,
        chapterCount: _chapters.length,
        progress: _progress,
      ),
    );
    _dirty = true;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 650), _save);
    _checkpoint ??= Timer(const Duration(seconds: 10), _save);
  }

  Future<void> _save() {
    _debounce?.cancel();
    _checkpoint?.cancel();
    _checkpoint = null;
    final sync = _sync;
    if (!_dirty || sync == null || _pages.isEmpty) return _writes;
    _dirty = false;
    final chapter = _chapters[_chapter], book = _book;
    final position = {
      'chapterUrl': chapter.url,
      'chapterTitle': chapter.title,
      'chapterIndex': _chapter,
      'chapterCount': _chapters.length,
      'bookProgressChapterUrl': chapter.url,
      'comicPage': _page,
      'progress': _progress,
    };
    _writes = _writes
        .then((_) => sync.saveComicPosition(book, position))
        .catchError((Object _) {
          if (mounted) {
            _dirty = true;
            _notice('阅读位置保存失败，请重试');
          }
        });
    unawaited(_session?.checkpoint());
    return _writes;
  }

  void _settingsChanged(ReaderPreferences value) {
    final repository = _repository;
    if (repository == null) return;
    setState(() => _preferences.value = value);
    final payload = {
      ...value.toJson(),
      'brightness': _brightness,
      'systemBrightness': _systemBrightness,
    };
    _settingsWrites = _settingsWrites
        .then((_) => repository.reader.write(_preferencesKey, payload))
        .catchError((Object _) {
          if (mounted) _notice('阅读设置保存失败');
        });
  }

  Future<void> _toggleFavorite(bool favorite) async {
    final sync = _sync;
    if (sync == null || _favoriting) return;
    setState(() => _favoriting = true);
    try {
      await sync.setFavorite(_book, !favorite);
    } catch (_) {
      if (mounted) _notice('收藏状态保存失败，请重试');
    } finally {
      if (mounted) setState(() => _favoriting = false);
    }
  }

  void _notice(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  void _togglePanel(ReaderDockPanel panel) => setState(() {
    _panel = _panel == panel ? ReaderDockPanel.none : panel;
  });

  void _hideTools() => setState(() {
    _tools = false;
    _panel = ReaderDockPanel.none;
  });

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground && !_loading && _pages.isNotEmpty) {
      _session?.resume();
    } else {
      _save();
      unawaited(_session?.pause());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _save();
    unawaited(_session?.pause());
    unawaited(_platform.brightness(null));
    unawaited(
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge)
          .then((_) => _platform.fullscreen(false)),
    );
    _scroll?.dispose();
    _preferences.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(comicRepositoryProvider);
    final prefs = _preferences.value;
    final favorite =
        ref
            .watch(shelfBooksProvider)
            .value
            ?.any((item) => item.id == widget.book.id && item.favorite) ??
        widget.book.favorite;
    return Theme(
      data: readerTheme(prefs),
      child: PopScope(
        canPop: !_tools,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) {
            _save();
            unawaited(_session?.pause());
          } else if (_tools) {
            if (_panel == ReaderDockPanel.none) {
              _hideTools();
            } else {
              _togglePanel(_panel);
            }
          }
        },
        child: Scaffold(
          body: Stack(
            children: [
              Positioned.fill(child: _body(prefs)),
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: ReaderToolbar(
                  visible: _tools || _loading || _error != null,
                  background: prefs.background,
                  child: SafeArea(
                    bottom: false,
                    child: ListTile(
                      leading: IconButton(
                        tooltip: '返回',
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.arrow_back_rounded),
                      ),
                      title: Text(
                        _book.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: _pages.isEmpty
                          ? null
                          : Text(
                              '${_chapters[_chapter].title} · ${_page + 1}/${_pages.length} 页',
                            ),
                    ),
                  ),
                ),
              ),
              if (_pages.isNotEmpty)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: ReaderDock(
                    visible: _tools,
                    preferences: prefs,
                    bottom: AppSpacing.dockBottom(
                      context,
                      navigationInset: _navigationBottom,
                    ),
                    controls: _controls(prefs, favorite),
                    panel: _dockPanel(),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(ReaderPreferences prefs) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error case final message?) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            TextButton(
              onPressed: _retryDetail
                  ? _initialize
                  : () => _loadChapter(_chapter, resume: _page),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    final next = _chapter + 1 < _chapters.length;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (_tools) {
          _hideTools();
        } else {
          setState(() => _tools = true);
        }
      },
      child: LayoutBuilder(
        builder: (context, bounds) {
          final width = math.min(bounds.maxWidth, 840.0);
          final extent = width * _ratio;
          if (_extent != extent) {
            _extent = extent;
            final page = _page;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && !_loading) _jump(page);
            });
          }
          return Center(
            child: SizedBox(
              width: width,
              child: CustomScrollView(
                controller: _scroll,
                scrollCacheExtent: ScrollCacheExtent.pixels(extent * 2),
                slivers: [
                  SliverFixedExtentList.builder(
                    itemExtent: extent,
                    itemCount: _pages.length,
                    addAutomaticKeepAlives: false,
                    itemBuilder: (context, i) => _ComicPageImage(
                      key: ValueKey((_chapter, i)),
                      repository: _repository!,
                      url: _pages[i],
                      page: i + 1,
                      eyeCare: prefs.eyeCare,
                      width: (width * MediaQuery.devicePixelRatioOf(context))
                          .ceil()
                          .clamp(1, 800),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: next
                            ? TextButton(
                                onPressed: () => _loadChapter(_chapter + 1),
                                child: const Text('阅读下一话'),
                              )
                            : const Text('已读到最后一话'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _controls(ReaderPreferences prefs, bool favorite) {
    int pageFor(double value) => (value * (_pages.length - 1)).round();
    return ReaderDockControls(
      preferences: prefs,
      chapterUnit: '话',
      progress: _progress,
      progressLabel: (value) => '第 ${pageFor(value) + 1} 页',
      onProgressChanged: _pages.length <= 1
          ? null
          : (value) => _jump(pageFor(value)),
      onPrevious: _chapter > 0 ? () => _loadChapter(_chapter - 1) : null,
      onNext: _chapter + 1 < _chapters.length
          ? () => _loadChapter(_chapter + 1)
          : null,
      actions: [
        ReaderDockAction(
          icon: ReaderAssetIcon('catalog', color: prefs.ink, size: 20),
          label: '目录',
          onPressed: () => _togglePanel(ReaderDockPanel.catalog),
        ),
        ReaderDockAction(
          icon: Icon(
            favorite ? Icons.favorite : Icons.favorite_border,
            size: 20,
          ),
          label: favorite ? '已收藏' : '收藏',
          onPressed: _favoriting ? null : () => _toggleFavorite(favorite),
        ),
        ReaderDockAction(
          icon: ReaderAssetIcon('settings', color: prefs.ink, size: 20),
          label: '设置',
          onPressed: () => _togglePanel(ReaderDockPanel.settings),
        ),
      ],
    );
  }

  Widget? _dockPanel() => switch (_panel) {
    ReaderDockPanel.catalog => ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .45,
      ),
      child: ListView.builder(
        shrinkWrap: true,
        padding: const EdgeInsets.only(top: 8),
        itemCount: _chapters.length,
        itemBuilder: (context, index) => ListTile(
          title: Text(_chapters[index].title),
          selected: _chapter == index,
          onTap: () {
            if (_chapter == index) {
              _togglePanel(ReaderDockPanel.catalog);
            } else {
              _loadChapter(index);
            }
          },
        ),
      ),
    ),
    ReaderDockPanel.settings => ReaderSettingsSheet(
      preferences: _preferences,
      followsSystemBrightness: _systemBrightness,
      manualBrightness: _brightness,
      onToggleBrightness: () {
        _systemBrightness = !_systemBrightness;
        unawaited(_platform.brightness(_systemBrightness ? null : _brightness));
        _settingsChanged(_preferences.value);
      },
      onBrightnessChanged: (value) {
        _brightness = value;
        unawaited(_platform.brightness(value));
        _settingsChanged(_preferences.value);
      },
      onChanged: _settingsChanged,
    ),
    _ => null,
  };
}

class _ComicPageImage extends StatefulWidget {
  const _ComicPageImage({
    super.key,
    required this.repository,
    required this.url,
    required this.page,
    required this.eyeCare,
    required this.width,
  });

  final ComicRepository repository;
  final String url;
  final int page, width;
  final bool eyeCare;

  @override
  State<_ComicPageImage> createState() => _ComicPageImageState();
}

class _ComicPageImageState extends State<_ComicPageImage> {
  late Future<File> _image = widget.repository.image(widget.url);

  void _retry([File? damaged]) {
    setState(() {
      _image = () async {
        if (damaged != null && await damaged.exists()) {
          await FileImage(damaged).evict();
          await damaged.delete();
        }
        return widget.repository.image(widget.url);
      }();
    });
  }

  Widget _error([File? file]) => Center(
    child: TextButton.icon(
      onPressed: () => _retry(file),
      icon: const Icon(Icons.refresh),
      label: Text('第 ${widget.page} 页加载失败 · 重试'),
    ),
  );

  @override
  Widget build(BuildContext context) => FutureBuilder<File>(
    future: _image,
    builder: (context, result) {
      if (result.connectionState != ConnectionState.done) {
        return const Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      }
      final file = result.data;
      if (file == null) return _error();
      final image = Image.file(
        file,
        fit: BoxFit.contain,
        cacheWidth: widget.width,
        semanticLabel: '第 ${widget.page} 页',
        errorBuilder: (_, _, _) => _error(file),
      );
      return widget.eyeCare
          ? ColorFiltered(
              colorFilter: const ColorFilter.mode(
                Color(0x1CE8AF65),
                BlendMode.srcATop,
              ),
              child: image,
            )
          : image;
    },
  );
}
