import 'package:flutter/material.dart';

class DiscoverSearchField extends StatelessWidget {
  const DiscoverSearchField({
    super.key,
    required this.controller,
    required this.hint,
    required this.onSubmitted,
    this.enabled = true,
    this.onCleared,
  });
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onSubmitted;
  final bool enabled;
  final VoidCallback? onCleared;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return TextField(
      key: const Key('discover-search-input'),
      controller: controller,
      enabled: enabled,
      textInputAction: TextInputAction.search,
      onSubmitted: onSubmitted,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: colors.onSurfaceVariant, fontSize: 14),
        prefixIcon: const Icon(Icons.search_rounded),
        suffixIcon: IconButton(
          tooltip: '清空输入',
          onPressed: () {
            controller.clear();
            onCleared?.call();
          },
          icon: const Icon(Icons.close_rounded, size: 18),
        ),
        filled: true,
        fillColor: colors.onSurface.withValues(alpha: .045),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(32),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 15,
        ),
      ),
    );
  }
}
