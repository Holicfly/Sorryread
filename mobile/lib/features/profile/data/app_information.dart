import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const projectUrl = 'https://github.com/Holicfly/Sorryread';

class AppInformation {
  static const channel = MethodChannel('sorryread/app');

  Future<String> version() async {
    final value = await channel.invokeMethod<String>('version');
    if (value == null || value.isEmpty) throw StateError('版本信息暂不可用');
    return value;
  }

  Future<void> openProject() async {
    await channel.invokeMethod<void>('openUrl', projectUrl);
  }
}

final appInformationProvider = Provider((ref) => AppInformation());
final appVersionProvider = FutureProvider<String>(
  (ref) => ref.watch(appInformationProvider).version(),
);

class ComponentLicense {
  const ComponentLicense(this.name, this.texts);
  final String name;
  final List<String> texts;
}

final componentLicensesProvider =
    FutureProvider.autoDispose<List<ComponentLicense>>((ref) async {
      final components = <String, Set<String>>{};
      await for (final entry in LicenseRegistry.licenses) {
        final text = entry.paragraphs
            .map((paragraph) => paragraph.text)
            .join('\n\n');
        for (final package in entry.packages) {
          components.putIfAbsent(package, () => {}).add(text);
        }
      }
      for (final font in const {
        '思源宋体 / Source Han Serif': 'SourceHanSerif',
        '思源黑体 / Source Han Sans': 'SourceHanSans',
        'Noto Sans CJK': 'NotoSans',
        '霞鹜臻楷 / LXGW ZhenKai': 'LXGWZhenKai',
        '霞鹜文楷 / LXGW WenKai': 'LXGWWenKai',
      }.entries) {
        components
            .putIfAbsent(font.key, () => {})
            .add(
              await rootBundle.loadString(
                'assets/font_licenses/${font.value}.txt',
              ),
            );
      }
      final names = components.keys.toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      return [
        for (final name in names)
          ComponentLicense(name, components[name]!.toList(growable: false)),
      ];
    });
