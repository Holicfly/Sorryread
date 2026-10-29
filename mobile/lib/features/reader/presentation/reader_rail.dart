import 'package:flutter/material.dart';

/// A shared inset track and a single animated selection, rather than chip blocks.
class ReaderRail extends StatelessWidget {
  const ReaderRail({
    super.key,
    required this.labels,
    required this.index,
    required this.onChanged,
  });
  final List<String> labels;
  final int index;
  final ValueChanged<int> onChanged;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final height = 44.0 * scale.clamp(1, 1.7);
        return Container(
          height: height,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: colors.primaryContainer,
            borderRadius: BorderRadius.circular(30),
            boxShadow: [
              BoxShadow(
                color: colors.onSurface.withValues(alpha: .06),
                blurRadius: 4,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          child: Stack(
            children: [
              AnimatedAlign(
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
                alignment: Alignment(
                  labels.length == 1 ? 0 : -1 + 2 * index / (labels.length - 1),
                  0,
                ),
                child: FractionallySizedBox(
                  widthFactor: 1 / labels.length,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.secondaryContainer,
                      borderRadius: BorderRadius.circular(26),
                      boxShadow: [
                        BoxShadow(
                          color: colors.onSurface.withValues(alpha: .09),
                          blurRadius: 4,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
              Row(
                children: [
                  for (var i = 0; i < labels.length; i++)
                    Expanded(
                      child: Semantics(
                        selected: index == i,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(26),
                          onTap: () => onChanged(i),
                          child: Center(
                            child: Text(
                              labels[i],
                              maxLines: 1,
                              style: TextStyle(
                                fontSize: 13,
                                color: colors.onSurface,
                                fontWeight: index == i
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                              ),
                            ),
                          ),
                        ),
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
}
