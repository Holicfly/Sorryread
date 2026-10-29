import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart';
import 'package:sorryread_mobile/features/reader/data/reader_selectors.dart';

void main() {
  test('structural CSS indices ignore text nodes, match the whole ancestor compound, and preserve sibling order', () {
    final document = parse(
      '''<div class="outer"><dl>\n<dt>最新</dt>\n<dd><a>广告</a></dd>\n<dt>正文</dt>\n<dd><a href="1">第一章</a></dd>\n<dd><a href="2">第二章</a></dd></dl><div class="section-opt">\n<a>上一页</a>\n<span>占位</span><a>目录</a>\n<a href="3">下一页</a></div></div><div><div><a>不能混入</a></div></div>''',
    );
    expect(
      readerSelect(
        document,
        '.outer > dl > dt:nth-of-type(2) ~ dd > a',
      ).map((e) => e.text),
      ['第一章', '第二章'],
    );
    expect(
      readerSelect(document, '.section-opt a:nth-of-type(3)').single.text,
      '下一页',
    );
    expect(
      readerSelect(document, '.section-opt > a:nth-child(4)').single.text,
      '下一页',
    );
    expect(
      readerSelect(document, '.section-opt > a:not([href])').map((e) => e.text),
      ['上一页', '目录'],
    );
    expect(readerSelect(document, '.outer > dl dd a').map((e) => e.text), [
      '广告',
      '第一章',
      '第二章',
    ]);
  });
}
