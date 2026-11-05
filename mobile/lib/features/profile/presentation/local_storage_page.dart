import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../design_system/components.dart';
import '../../../design_system/top_wash.dart';
import '../../reader/presentation/reader_resume_cache.dart';
import '../data/local_storage.dart';

const _segmentColors = [
  Color(0xFF397B6A),
  Color(0xFF8BBBA2),
  Color(0xFFD6C78F),
];

class LocalStoragePage extends ConsumerStatefulWidget {
  const LocalStoragePage({super.key, this.downloadsOnly = false});
  final bool downloadsOnly;

  @override
  ConsumerState<LocalStoragePage> createState() => _LocalStoragePageState();
}

class _LocalStoragePageState extends ConsumerState<LocalStoragePage>
    with WidgetsBindingObserver {
  bool _busy = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!_busy &&
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
          (ref.read(localStorageProvider).asData?.value.indexRunning ??
              false)) {
        ref.invalidate(localStorageProvider);
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_busy) {
      ref.invalidate(localStorageProvider);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _remove({required bool index}) async {
    if (_busy) return;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        backgroundColor: Theme.of(context).colorScheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        icon: Center(
          child: FeatureIconBadge(
            index
                ? Icons.playlist_remove_rounded
                : Icons.cleaning_services_outlined,
            size: 52,
            iconSize: 27,
          ),
        ),
        title: Text(index ? '删除夜社书目索引？' : '清理缓存数据？'),
        content: Text(
          index
              ? '将删除本机保存的全部夜社书名与链接，并停止正在进行的书目下载。\n\n删除后，需在夜社页面重新建立书目才能按书名搜索；网址解析、收藏和阅读进度不受影响。'
              : '将清理已缓存的章节正文、目录和临时文件。再次阅读部分内容时需要联网加载。\n\n夜社书目索引、书架、收藏、阅读记录、设置和设备配对将保留。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(index ? '删除索引' : '确认清理'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    setState(() => _busy = true);
    String message;
    try {
      final repository = ref.read(localStorageRepositoryProvider);
      final result = index
          ? await repository.deleteYesheIndex()
          : await repository.clearCache();
      if (!mounted) return;
      if (!index) {
        ref.read(readerResumeCacheProvider).clear();
        PaintingBinding.instance.imageCache.clear();
      }
      message = result.failedFiles > 0
          ? '部分缓存暂时无法清理，已更新剩余占用，请稍后重试'
          : index
          ? '夜社书目索引已删除'
          : '缓存已清理';
    } catch (error) {
      message = error is PlatformException
          ? error.message ?? '操作未完成，请重试'
          : '操作未完成，请重试';
    } finally {
      if (mounted) {
        ref.invalidate(localStorageProvider);
        setState(() => _busy = false);
      }
    }
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(localStorageProvider);
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        body: TopWashPage(
          tone: TopWashTone.storage,
          height: 360,
          child: SafeArea(
            child: Column(
              children: [
                AppBar(
                  backgroundColor: Colors.transparent,
                  centerTitle: true,
                  title: Text(widget.downloadsOnly ? '下载管理' : '本地存储'),
                  leading: BackButton(
                    onPressed: _busy ? null : () => Navigator.maybePop(context),
                  ),
                ),
                Expanded(
                  child: PageWidth(
                    child: state.when(
                      loading: () =>
                          const Center(child: CircularProgressIndicator()),
                      error: (_, _) => Center(
                        child: TextButton.icon(
                          onPressed: () => ref.invalidate(localStorageProvider),
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text('存储信息暂不可用，点击重试'),
                        ),
                      ),
                      data: (data) => ListView(
                        key: ValueKey(
                          widget.downloadsOnly
                              ? 'download-management-scroll'
                              : 'local-storage-scroll',
                        ),
                        padding: const EdgeInsets.fromLTRB(16, 20, 16, 28),
                        children: widget.downloadsOnly
                            ? _downloads(data)
                            : _overview(data),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _overview(StorageSnapshot data) => [
    _Occupancy(data),
    const SizedBox(height: 20),
    const _Note(
      icon: Icons.info_outline_rounded,
      title: '存储概览',
      text: '这里统计素若阅读在本机使用的空间。管理下载与缓存，为阅读留一点余地。',
    ),
    const SizedBox(height: 16),
    _Category(
      icon: Icons.layers_outlined,
      title: '必要占用',
      bytes: data.necessary,
      color: _segmentColors[0],
      description: '应用文件、书架索引、收藏、阅读记录、设置与导入字体等基础数据，不支持清理。',
    ),
    const SizedBox(height: 12),
    _Category(
      icon: Icons.download_outlined,
      title: '下载内容',
      bytes: data.downloads,
      color: _segmentColors[1],
      description: '您已下载到本地的资源，如不需要可随时清理',
      action: OutlinedButton(
        onPressed: _busy
            ? null
            : () => context.push('/profile/storage/downloads'),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('管理'),
            SizedBox(width: 2),
            Icon(Icons.chevron_right_rounded, size: 18),
          ],
        ),
      ),
    ),
    const SizedBox(height: 12),
    _Category(
      icon: Icons.cleaning_services_outlined,
      title: '缓存数据',
      bytes: data.cache,
      color: _segmentColors[2],
      description: '阅读时缓存的章节正文、目录及临时文件。清理后可能需要联网重新加载。',
      action: FilledButton(
        onPressed: _busy || data.cache == 0
            ? null
            : () => _remove(index: false),
        child: Text(_busy ? '清理中…' : '清理缓存'),
      ),
    ),
    const SizedBox(height: 20),
    const _Note(
      icon: Icons.menu_book_outlined,
      title: '各项说明',
      text: '必要数据会一直保留；夜社书目索引可在下载管理中单独删除。清理缓存不会删除书目索引、收藏和阅读进度。\n\n占用按本机可访问文件大小统计，可能与系统设置略有差异。缓存会随使用重新生成。',
    ),
  ];

  List<Widget> _downloads(StorageSnapshot data) => [
    Text('保存在这台设备上', style: Theme.of(context).textTheme.titleLarge),
    const SizedBox(height: 8),
    Text('查看本机保存的资源，按需释放空间。', style: Theme.of(context).textTheme.bodySmall),
    const SizedBox(height: 22),
    if (data.hasIndex)
      _Category(
        icon: Icons.manage_search_rounded,
        title: '夜社书目索引',
        bytes: data.downloads,
        color: _segmentColors[0],
        description:
            '已收录 ${data.indexCount} 条书目${data.indexRunning ? ' · 正在下载' : ''}\n仅保存书名与链接，用于本地搜索。${data.indexUpdated > 0 ? '\n最近更新：${_date(data.indexUpdated)}' : ''}',
        action: OutlinedButton(
          onPressed: _busy ? null : () => _remove(index: true),
          child: Text(_busy ? '删除中…' : '删除'),
        ),
      )
    else
      const SurfaceBlock(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 32),
          child: Column(
            children: [
              FeatureIconBadge(Icons.download_outlined, size: 56, iconSize: 30),
              SizedBox(height: 18),
              Text('暂无已下载的资源'),
              SizedBox(height: 8),
              Text('在夜社页面建立书目后，可在这里管理。', textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    const SizedBox(height: 20),
    const _Note(
      icon: Icons.info_outline_rounded,
      title: '关于书目索引',
      text: '书目索引不包含小说正文和封面。删除后需重新建立索引才能按书名搜索，不影响网址解析、收藏和阅读进度。',
    ),
    // Add aggregate entries for other explicitly downloaded resources only
    // when those download features exist. Do not show placeholder categories.
  ];

  String _date(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return '${date.year}.${date.month.toString().padLeft(2, '0')}.${date.day.toString().padLeft(2, '0')}';
  }
}

class _Occupancy extends StatelessWidget {
  const _Occupancy(this.data);
  final StorageSnapshot data;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final values = [data.necessary, data.downloads, data.cache];
    final legend = Column(
      children: [
        for (var i = 0; i < values.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: [
                Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    color: _segmentColors[i],
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        ['必要占用', '下载内容', '缓存数据'][i],
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        storageSize(values[i]),
                        style: theme.textTheme.titleMedium,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
    Widget ring(double size) => Semantics(
      label: '应用占用 ${storageSize(data.total)}，由必要占用、下载内容和缓存数据组成',
      image: true,
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: _RingPainter(values, theme.colorScheme.outlineVariant),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(30),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('应用占用', style: theme.textTheme.bodySmall),
                  const SizedBox(height: 9),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      storageSize(data.total),
                      style: theme.textTheme.headlineLarge?.copyWith(
                        fontSize: 30,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Icon(
                    Icons.menu_book_outlined,
                    color: theme.colorScheme.primary.withValues(alpha: .5),
                    size: 25,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 350 &&
            MediaQuery.textScalerOf(context).scale(14) < 19) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ring(constraints.maxWidth >= 500 ? 250 : 208),
              const SizedBox(width: 24),
              Expanded(child: legend),
            ],
          );
        }
        return Column(
          children: [ring(240), const SizedBox(height: 12), legend],
        );
      },
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.values, this.track);
  final List<int> values;
  final Color track;
  @override
  void paint(Canvas canvas, Size size) {
    final width = size.width * .095;
    final rect = (Offset.zero & size).deflate(width / 2 + 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..color = track;
    canvas.drawOval(rect, paint);
    final total = values.fold<int>(0, (sum, value) => sum + value);
    if (total == 0) return;
    var start = -math.pi / 2;
    for (var i = 0; i < values.length; i++) {
      final sweep = values[i] / total * math.pi * 2;
      if (sweep > 0) {
        paint.color = _segmentColors[i];
        canvas.drawArc(rect, start, sweep, false, paint);
      }
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) =>
      oldDelegate.track != track ||
      List.generate(
        values.length,
        (i) => oldDelegate.values[i] != values[i],
      ).any((changed) => changed);
}

class _Category extends StatelessWidget {
  const _Category({
    required this.icon,
    required this.title,
    required this.bytes,
    required this.color,
    required this.description,
    this.action,
  });
  final IconData icon;
  final String title, description;
  final int bytes;
  final Color color;
  final Widget? action;
  @override
  Widget build(BuildContext context) => SurfaceBlock(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FeatureIconBadge(icon, size: 44, iconSize: 26),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    storageSize(bytes),
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ],
              ),
            ),
            if (action != null &&
                MediaQuery.textScalerOf(context).scale(14) < 19) ...[
              const SizedBox(width: 8),
              action!,
            ],
          ],
        ),
        const SizedBox(height: 12),
        Text(
          description,
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        if (action != null && MediaQuery.textScalerOf(context).scale(14) >= 19)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Align(alignment: Alignment.centerRight, child: action),
          ),
      ],
    ),
  );
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.title, required this.text});
  final IconData icon;
  final String title, text;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.primary.withValues(alpha: .035),
      borderRadius: BorderRadius.circular(AppSpacing.radius),
      border: Border.all(
        color: Theme.of(context).colorScheme.primary.withValues(alpha: .08),
      ),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 21, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 10),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
          ],
        ),
        const SizedBox(height: 9),
        Text(
          text,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.65),
        ),
      ],
    ),
  );
}
