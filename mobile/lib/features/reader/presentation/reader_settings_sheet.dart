import 'package:flutter/material.dart';

import '../data/reader_fonts.dart';
import 'reader_preferences.dart';
import 'reader_rail.dart';

class ReaderSettingsSheet extends StatelessWidget {
  const ReaderSettingsSheet({
    super.key,
    required this.preferences,
    required this.onChanged,
    required this.onFont,
    required this.fonts,
  });
  final ValueNotifier<ReaderPreferences> preferences;
  final ValueChanged<ReaderPreferences> onChanged;
  final VoidCallback onFont;
  final ReaderFonts fonts;
  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<ReaderPreferences>(
        valueListenable: preferences,
        builder: (context, p, _) {
          final theme = Theme.of(context), colors = theme.colorScheme;
          Widget pill(String label, VoidCallback? onTap) => TextButton(
            style: TextButton.styleFrom(
              foregroundColor: p.ink,
              backgroundColor: p.rail,
              minimumSize: const Size(48, 44),
              padding: const EdgeInsets.symmetric(horizontal: 16),
            ),
            onPressed: onTap,
            child: Text(label),
          );
          Widget row(String label, Widget child) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Row(
              children: [
                SizedBox(width: 44, child: Text(label)),
                const SizedBox(width: 4),
                Expanded(child: child),
              ],
            ),
          );
          return SafeArea(
            top: false,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Text('亮度', style: theme.textTheme.titleSmall),
                      const Spacer(),
                      Icon(
                        Icons.visibility_outlined,
                        size: 20,
                        color: colors.primary,
                      ),
                      const SizedBox(width: 6),
                      const Text('护眼模式'),
                      Switch(
                        value: p.eyeCare,
                        onChanged: (v) => onChanged(p.copyWith(eyeCare: v)),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      Icon(Icons.brightness_low, color: colors.primary),
                      Expanded(
                        child: Slider(
                          key: const Key('reader-brightness'),
                          min: .02,
                          max: 1,
                          value: p.brightness ?? .5,
                          onChanged: (v) =>
                              onChanged(p.copyWith(brightness: v)),
                        ),
                      ),
                      const Icon(Icons.brightness_high_outlined, size: 20),
                    ],
                  ),
                  const Divider(height: 12),
                  row(
                    '字号',
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        pill(
                          'A⁻',
                          p.fontSize > 14
                              ? () => onChanged(
                                  p.copyWith(
                                    fontSize: (p.fontSize - 1).clamp(14, 36),
                                  ),
                                )
                              : null,
                        ),
                        SizedBox(
                          width: 28,
                          child: Text(
                            '${p.fontSize.round()}',
                            textAlign: TextAlign.center,
                          ),
                        ),
                        pill(
                          'A⁺',
                          p.fontSize < 36
                              ? () => onChanged(
                                  p.copyWith(
                                    fontSize: (p.fontSize + 1).clamp(14, 36),
                                  ),
                                )
                              : null,
                        ),
                        pill('${fonts.label(p.font)} ›', onFont),
                      ],
                    ),
                  ),
                  row(
                    '配色',
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        for (
                          var i = 0;
                          i < ReaderPreferences.backgrounds.length;
                          i++
                        )
                          Semantics(
                            label: ['暖白', '米色', '浅绿', '浅蓝', '深灰', '墨黑'][i],
                            selected: p.palette == i && !p.night,
                            child: InkResponse(
                              onTap: () => onChanged(
                                p.copyWith(palette: i, night: false),
                              ),
                              radius: 26,
                              child: Container(
                                width: 38,
                                height: 38,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: ReaderPreferences.backgrounds[i],
                                  border: Border.all(
                                    color: p.palette == i && !p.night
                                        ? colors.primary
                                        : colors.outlineVariant,
                                    width: p.palette == i && !p.night ? 2 : 1,
                                  ),
                                ),
                                child: p.palette == i && !p.night
                                    ? Icon(
                                        Icons.check,
                                        size: 19,
                                        color: i >= 4
                                            ? Colors.white
                                            : colors.primary,
                                      )
                                    : null,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  row(
                    '翻页',
                    ReaderRail(
                      labels: const ['仿真', '上下滑动', '无动画'],
                      index: p.mode.index,
                      onChanged: (i) =>
                          onChanged(p.copyWith(mode: PageMode.values[i])),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
}

class ReaderFontSheet extends StatefulWidget {
  const ReaderFontSheet({
    super.key,
    required this.fonts,
    required this.selected,
    required this.onSelected,
  });
  final ReaderFonts fonts;
  final String selected;
  final void Function(String id, String? family) onSelected;
  @override
  State<ReaderFontSheet> createState() => _ReaderFontSheetState();
}

class _ReaderFontSheetState extends State<ReaderFontSheet> {
  String? busy, error;
  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text('阅读字体', style: Theme.of(context).textTheme.titleLarge),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          for (final font in readingFonts)
            ListTile(
              title: Text(font.label),
              subtitle: Text(busy == font.id ? '正在加载内置字体…' : font.detail),
              trailing: busy == font.id
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : widget.selected == font.id
                  ? Icon(
                      Icons.check,
                      color: Theme.of(context).colorScheme.primary,
                    )
                  : const Icon(Icons.chevron_right),
              enabled: busy == null,
              onTap: () => _choose(font),
            ),
          TextButton(
            onPressed: busy == null
                ? () =>
                      showLicensePage(context: context, applicationName: '素若阅读')
                : null,
            child: const Text('字体许可'),
          ),
        ],
      ),
    ),
  );
  Future<void> _choose(ReadingFont font) async {
    setState(() {
      busy = font.id;
      error = null;
    });
    try {
      final family = await widget.fonts.load(font.id);
      if (!mounted) return;
      widget.onSelected(font.id, family);
      Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() => error = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => busy = null);
    }
  }
}
