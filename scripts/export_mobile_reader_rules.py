"""Export public search/reading rules; leave desktop execution code untouched."""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STRING = r'@"(?:[^"]|"")*"|"(?:\\.|[^"\\])*"'


def block(text, name):
    match = re.search(r'\b' + name + r'\s*=\s*new\(\)\s*\{', text)
    if not match:
        return ''
    start = match.end()
    depth = 1
    for token in re.finditer(STRING + r'|[{}]', text[start:]):
        if token.group() == '{':
            depth += 1
        elif token.group() == '}':
            depth -= 1
            if not depth:
                return text[start:start + token.start()]
    raise ValueError(name)


def fields(text):
    values = {}
    for match in re.finditer(r'(\w+)\s*=\s*(' + STRING + r'|\w+(?:\.\w+)?)', text):
        key, raw = match.groups()
        if raw.startswith('@"'):
            value = raw[2:-1].replace('""', '"')
        elif raw.startswith('"'):
            value = json.loads(raw)
        else:
            value = {'true': True, 'false': False}.get(raw, raw.split('.')[-1])
        values[key[0].lower() + key[1:]] = value
    return values


source = (ROOT / 'src/Search/BookSourceCatalog.cs').read_text(encoding='utf-8-sig')
rules = []
for entry in re.split(r'\n        new\(\)\s*\n        \{', source)[1:]:
    head = fields(entry.split('Search =')[0])
    source_id = {'WodushuId': 'wodushu', 'Legacy18MhId': '18mh'}.get(head['id'], head['id'])
    base = re.search(r'BaseUri = new Uri\(("[^"]+")\)', entry)
    rules.append({
        'id': source_id, 'name': head['name'], 'baseUrl': json.loads(base.group(1)),
        'dynamic': source_id == '18mh', 'detail': fields(block(entry, 'Detail')),
        'catalog': fields(block(entry, 'Catalog')), 'chapter': fields(block(entry, 'Chapter')),
    })
    search_block = block(entry, 'Search')
    search = fields(search_block)
    search['formFields'] = {
        json.loads(key): json.loads(value)
        for key, value in re.findall(r'\(("(?:\\.|[^"\\])*"),\s*("(?:\\.|[^"\\])*")\)', search_block)
    }
    rules[-1]['search'] = search
    if source_id == 'ranwen8':
        # The desktop host redirects mobile searches and drops the POST body.
        # Use the same source's mobile endpoint and current mobile DOM directly.
        rules[-1]['search'].update({
            'uriTemplate': 'https://m.ranwen8.cc/search.html',
            'resultSelector': '.sort_list > li',
            'titleLinkSelector': 'span.s2 > a', 'authorSelector': 'span.s5',
        })
        rules[-1]['detail']['bookUrlPattern'] = r'^https://(?:www|m)\.ranwen8\.cc/book/([^/]+)/?$'
        rules[-1]['catalog'].update({
            'uriTemplate': 'https://m.ranwen8.cc/book/{bookId}/index_1.html',
            'itemSelector': '.chapter-list a[href]', 'nextPageSelector': 'select > option',
        })
        rules[-1]['chapter'].update({
            'titleSelector': '#chaptername, .bookname h1',
            'contentSelector': '#txt, #content', 'nextPageSelector': '#pb_next, #link-next',
        })
    if source_id == '18mh':
        rules[-1]['catalog']['itemSelector'] = 'a.jm-dt-ch[href], a.detail-page__catalog-item[href]'
        # Mobile can use the server-rendered chapter before falling back to JS.
        rules[-1]['chapter'] = {
            'contentSelector': 'main.app-content .article, .chapter-content, .reading-content, .read-content, #chapter-content, #content, article',
            'removeSelectors': 'script, style, .novel-unlock-mask, .novel-read-footer',
        }
# This source is mobile-only; desktop search/catalog definitions stay separate.
rules.append({
    'id': 'yeshe', 'name': '夜社', 'baseUrl': 'https://yeshezy1.com/',
    'dynamic': False,
    'detail': {'bookUrlPattern': r'^https://yeshezy1\.com/artdetail-(\d+)\.html$'},
    'catalog': {'itemSelector': '.videolist a.link[href]'},
    'chapter': {
        'contentSelector': '.picslist > .content',
        'removeSelectors': '.nextbtn, script, style, iframe, .btm_list_box',
    },
})

destination = ROOT / 'mobile/assets/reader_sources.json'
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text(json.dumps(rules, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
print(f'Exported {len(rules)} reading rules to {destination}')
