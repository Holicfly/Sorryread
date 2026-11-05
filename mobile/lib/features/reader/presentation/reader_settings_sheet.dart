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
  Widget build(
    BuildContext context,
  ) => ValueListenableBuilder<ReaderPreferences>(
    valueListenable: preferences,
    builder: (context, p, _) {
      final compact = TextButton.styleFrom(
        foregroundColor: p.ink,
        backgroundColor: p.rail,
        minimumSize: const Size(44, 36),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        textStyle: const TextStyle(fontSize: 13),
      );
      Widget label(String text) => SizedBox(
        width: 38,
        child: Text(text, style: const TextStyle(fontSize: 12)),
      );
      return SingleChildScrollView(
        key: const Key('reader-settings-content'),
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              key: const Key('reader-light-row'),
              children: [
                label('亮度'),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 6,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 12,
                      ),
                    ),
                    child: Slider(
                      key: const Key('reader-brightness'),
                      min: .02,
                      max: 1,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      value: p.brightness ?? .5,
                      onChanged: (v) => onChanged(p.copyWith(brightness: v)),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Semantics(
                  toggled: p.eyeCare,
                  label: '护眼模式',
                  child: TextButton(
                    key: const Key('reader-eye-care'),
                    style: TextButton.styleFrom(
                      foregroundColor: p.ink,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(44, 44),
                    ),
                    onPressed: () => onChanged(p.copyWith(eyeCare: !p.eyeCare)),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('护眼', style: TextStyle(fontSize: 12)),
                        const SizedBox(width: 6),
                        Image.asset(
                          'assets/reader_icons/${p.eyeCare ? 'eye_on' : 'eye_off'}.png',
                          width: 22,
                          height: 22,
                          color: p.ink,
                          excludeFromSemantics: true,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                label('字号'),
                Expanded(
                  child: TextButton(
                    style: compact,
                    onPressed: p.fontSize > 14
                        ? () => onChanged(
                            p.copyWith(
                              fontSize: (p.fontSize - 1).clamp(14, 36),
                            ),
                          )
                        : null,
                    child: const Text('A⁻', style: TextStyle(fontSize: 17)),
                  ),
                ),
                SizedBox(
                  width: 36,
                  child: Text(
                    '${p.fontSize.round()}',
                    textAlign: TextAlign.center,
                  ),
                ),
                Expanded(
                  child: TextButton(
                    style: compact,
                    onPressed: p.fontSize < 36
                        ? () => onChanged(
                            p.copyWith(
                              fontSize: (p.fontSize + 1).clamp(14, 36),
                            ),
                          )
                        : null,
                    child: const Text('A⁺', style: TextStyle(fontSize: 17)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                style: compact,
                onPressed: onFont,
                child: Text('${fonts.label(p.font)} ›'),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                label('配色'),
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      for (
                        var i = 0;
                        i < ReaderPreferences.backgrounds.length;
                        i++
                      )
                        Expanded(
                          child: Semantics(
                            label: ['暖白', '米色', '浅绿', '浅蓝', '深灰', '墨黑'][i],
                            selected: p.palette == i && !p.night,
                            child: InkResponse(
                              onTap: () => onChanged(
                                p.copyWith(palette: i, night: false),
                              ),
                              radius: 22,
                              child: SizedBox(
                                height: 44,
                                child: Center(
                                  child: Container(
                                    width: 27,
                                    height: 27,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: ReaderPreferences.backgrounds[i],
                                      border: Border.all(
                                        color: p.palette == i && !p.night
                                            ? p.accent
                                            : p.ink.withValues(alpha: .18),
                                        width: p.palette == i && !p.night
                                            ? 2
                                            : 1,
                                      ),
                                    ),
                                    child: p.palette == i && !p.night
                                        ? Icon(
                                            Icons.check,
                                            size: 16,
                                            color: i >= 4
                                                ? Colors.white
                                                : p.ink,
                                          )
                                        : null,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                label('翻页'),
                Expanded(
                  child: ReaderRail(
                    labels: const ['仿真', '上下滑动', '无动画'],
                    index: p.mode.index,
                    onChanged: (i) =>
                        onChanged(p.copyWith(mode: PageMode.values[i])),
                  ),
                ),
              ],
            ),
          ],
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
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
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
              dense: true,
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
    } catch (e) {
      if (mounted) {
        setState(() => error = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => busy = null);
    }
  }
}
