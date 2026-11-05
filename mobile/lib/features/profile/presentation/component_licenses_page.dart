import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design_system/components.dart';
import '../data/app_information.dart';

class ComponentLicensesPage extends ConsumerWidget {
  const ComponentLicensesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: const Text('开源组件声明')),
    body: SafeArea(
      top: false,
      child: PageWidth(
        child: ref
            .watch(componentLicensesProvider)
            .when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, _) => Center(
                child: TextButton(
                  onPressed: () => ref.invalidate(componentLicensesProvider),
                  child: const Text('声明加载失败，点击重试'),
                ),
              ),
              data: (components) => ListView.separated(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.listInset,
                  16,
                  AppSpacing.listInset,
                  24,
                ),
                itemCount: components.length + 1,
                separatorBuilder: (_, index) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                      child: Text(
                        '感谢以下 ${components.length} 项开源组件与字体',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    );
                  }
                  final component = components[index - 1];
                  return SurfaceBlock(
                    padding: EdgeInsets.zero,
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 5,
                      ),
                      title: Text(component.name),
                      trailing: const Icon(
                        Icons.chevron_right_rounded,
                        size: 20,
                      ),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => _LicenseTextPage(component),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
      ),
    ),
  );
}

class _LicenseTextPage extends StatelessWidget {
  const _LicenseTextPage(this.component);
  final ComponentLicense component;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(component.name, maxLines: 1, overflow: TextOverflow.ellipsis),
    ),
    body: SafeArea(
      top: false,
      child: PageWidth(
        child: ListView.separated(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.listInset,
            16,
            AppSpacing.listInset,
            24,
          ),
          itemCount: component.texts.length,
          separatorBuilder: (_, index) => const SizedBox(height: 16),
          itemBuilder: (_, index) => SurfaceBlock(
            child: SelectableText(
              component.texts[index],
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ),
      ),
    ),
  );
}
