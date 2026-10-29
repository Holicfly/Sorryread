import 'package:csslib/parser.dart' as css;
import 'package:csslib/parser.dart' show TokenKind;
import 'package:csslib/visitor.dart';
import 'package:html/dom.dart';

typedef _Compound = ({int relation, List<SimpleSelector> conditions});
final _selectors = <String, List<List<_Compound>>>{};

/// CSS subset used by the code-owned desktop reading rules. Structural indices
/// count element siblings, never whitespace text nodes.
List<Element> readerSelect(Document document, String selector) {
  return _selectCandidates(document.querySelectorAll('*'), selector);
}

List<Element> readerSelectWithin(Element element, String selector) =>
    _selectCandidates(element.querySelectorAll('*'), selector);

List<Element> _selectCandidates(List<Element> candidates, String selector) {
  if (selector.isEmpty) return [];
  final groups = _selectors.putIfAbsent(selector, () {
    final errors = <css.Message>[];
    final parsed = css.parseSelectorGroup(selector, errors: errors);
    if (parsed == null || errors.isNotEmpty) {
      throw FormatException('无效书源选择器：$selector');
    }
    return parsed.selectors.map((s) {
      final compounds = <_Compound>[];
      for (final sequence in s.simpleSelectorSequences) {
        if (compounds.isEmpty ||
            sequence.combinator != TokenKind.COMBINATOR_NONE) {
          compounds.add((
            relation: sequence.combinator,
            conditions: <SimpleSelector>[],
          ));
        }
        compounds.last.conditions.add(sequence.simpleSelector);
      }
      return compounds;
    }).toList();
  });
  return candidates
      .where((e) => groups.any((g) => _matchesGroup(e, g, g.length - 1)))
      .toList();
}

bool _matchesGroup(Element? element, List<_Compound> groups, int i) {
  if (element == null ||
      !groups[i].conditions.every((s) => _matches(element, s))) {
    return false;
  }
  if (i == 0) return true;
  switch (groups[i].relation) {
    case TokenKind.COMBINATOR_GREATER:
      return _matchesGroup(element.parent, groups, i - 1);
    case TokenKind.COMBINATOR_PLUS:
      return _matchesGroup(element.previousElementSibling, groups, i - 1);
    case TokenKind.COMBINATOR_TILDE:
      for (
        var n = element.previousElementSibling;
        n != null;
        n = n.previousElementSibling
      ) {
        if (_matchesGroup(n, groups, i - 1)) return true;
      }
      return false;
    case TokenKind.COMBINATOR_DESCENDANT:
      for (var n = element.parent; n != null; n = n.parent) {
        if (_matchesGroup(n, groups, i - 1)) return true;
      }
      return false;
    default:
      throw const FormatException('不支持的书源组合选择器');
  }
}

bool _matches(Element element, SimpleSelector selector) {
  if (selector is ElementSelector) {
    return selector.isWildcard ||
        element.localName == selector.name.toLowerCase();
  }
  if (selector is IdSelector) return element.id == selector.name;
  if (selector is ClassSelector) return element.classes.contains(selector.name);
  if (selector is NegationSelector) {
    return !_matches(element, selector.negationArg!);
  }
  if (selector is AttributeSelector) {
    final value = element.attributes[selector.name.toLowerCase()];
    if (value == null) return false;
    final expected = '${selector.value}';
    return switch (selector.operatorKind) {
      TokenKind.NO_MATCH => true,
      TokenKind.EQUALS => value == expected,
      TokenKind.INCLUDES => value.split(RegExp(r'\s+')).contains(expected),
      TokenKind.DASH_MATCH =>
        value == expected || value.startsWith('$expected-'),
      TokenKind.PREFIX_MATCH => value.startsWith(expected),
      TokenKind.SUFFIX_MATCH => value.endsWith(expected),
      TokenKind.SUBSTRING_MATCH => value.contains(expected),
      _ => throw const FormatException('不支持的书源属性选择器'),
    };
  }
  if (selector is PseudoClassFunctionSelector) {
    final type = selector.name;
    if (![
      'nth-child',
      'nth-of-type',
      'nth-last-child',
      'nth-last-of-type',
    ].contains(type)) {
      throw FormatException('不支持的书源伪类：$type');
    }
    final siblings =
        element.parent?.children
            .where(
              (e) =>
                  !type.contains('of-type') || e.localName == element.localName,
            )
            .toList() ??
        [element];
    final index = type.contains('last')
        ? siblings.length - siblings.indexOf(element)
        : siblings.indexOf(element) + 1;
    final expression = selector.expression.span.text
        .replaceAll(' ', '')
        .toLowerCase();
    if (expression == 'odd') return index.isOdd;
    if (expression == 'even') return index.isEven;
    final number = int.tryParse(expression);
    if (number != null) return index == number;
    final formula = RegExp(r'^([+-]?\d*)n([+-]\d+)?$').firstMatch(expression);
    if (formula == null) throw const FormatException('不支持的书源索引表达式');
    final a = switch (formula.group(1)) {
          '' || '+' => 1,
          '-' => -1,
          final n => int.parse(n!),
        },
        b = int.parse(formula.group(2) ?? '0');
    return a == 0 ? index == b : (index - b) * a >= 0 && (index - b) % a == 0;
  }
  if (selector is PseudoClassSelector) {
    return switch (selector.name) {
      'first-child' => element.previousElementSibling == null,
      'last-child' => element.nextElementSibling == null,
      'only-child' =>
        element.previousElementSibling == null &&
            element.nextElementSibling == null,
      'empty' => element.nodes.every(
        (n) => n is! Element && (n is! Text || n.data.isEmpty),
      ),
      _ => throw FormatException('不支持的书源伪类：${selector.name}'),
    };
  }
  throw const FormatException('不支持的书源选择器');
}
