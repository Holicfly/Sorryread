import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../design_system/components.dart';
import '../data/reader_profile.dart';

class EditProfilePage extends ConsumerWidget {
  const EditProfilePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: const Text('编辑个人资料')),
    body: SafeArea(
      top: false,
      child: PageWidth(
        child: ref
            .watch(readerProfileProvider)
            .when(
              data: (profile) => _ProfileEditor(initial: profile),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, _) => Center(
                child: TextButton(
                  onPressed: () => ref.invalidate(readerProfileProvider),
                  child: const Text('资料加载失败，点击重试'),
                ),
              ),
            ),
      ),
    ),
  );
}

class _ProfileEditor extends ConsumerStatefulWidget {
  const _ProfileEditor({required this.initial});
  final ReaderProfile initial;

  @override
  ConsumerState<_ProfileEditor> createState() => _ProfileEditorState();
}

class _ProfileEditorState extends ConsumerState<_ProfileEditor> {
  late final _nickname = TextEditingController(text: widget.initial.nickname);
  late int? _avatarId = widget.initial.avatarId;
  bool _saving = false;

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    FocusScope.of(context).unfocus();
    try {
      await ref
          .read(readerProfileProvider.notifier)
          .save(_nickname.text, _avatarId);
      if (mounted) context.pop();
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('资料保存失败，请重试')));
    }
  }

  @override
  void dispose() {
    _nickname.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.listInset,
        12,
        AppSpacing.listInset,
        24,
      ),
      children: [
        SurfaceBlock(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Text('昵称', style: theme.textTheme.titleMedium),
              const SizedBox(width: 16),
              Expanded(
                child: TextField(
                  key: const Key('profile-nickname-input'),
                  controller: _nickname,
                  enabled: !_saving,
                  maxLength: 24,
                  textInputAction: TextInputAction.done,
                  style: theme.textTheme.bodyLarge,
                  decoration: InputDecoration(
                    hintText: '输入昵称',
                    counterText: '',
                    isDense: true,
                    filled: true,
                    fillColor: colors.onSurface.withValues(alpha: .045),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SurfaceBlock(
          child: LayoutBuilder(
            builder: (context, constraints) {
              const gap = 8.0;
              final columns = constraints.maxWidth >= 250 ? 3 : 2;
              final width =
                  (constraints.maxWidth - (columns - 1) * gap) / columns;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (var index = 0; index < presetAvatarNames.length; index++)
                    SizedBox(
                      width: width,
                      child: Semantics(
                        label: presetAvatarNames[index],
                        button: true,
                        selected: _avatarId == index + 1,
                        child: InkWell(
                          key: ValueKey('preset-avatar-${index + 1}'),
                          borderRadius: BorderRadius.circular(16),
                          splashFactory: NoSplash.splashFactory,
                          highlightColor: Colors.transparent,
                          onTap: _saving
                              ? null
                              : () => setState(() => _avatarId = index + 1),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Center(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: _avatarId == index + 1
                                        ? colors.primary
                                        : colors.outlineVariant,
                                    width: 2,
                                  ),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.all(4),
                                  child: CircleAvatar(
                                    radius: 29,
                                    foregroundImage: AssetImage(
                                      presetAvatarAsset(index + 1),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '正在保存…' : '保存'),
        ),
      ],
    );
  }
}
