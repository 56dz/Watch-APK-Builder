// 免费联网搜索与网页抓取。
//
// 移植自 dsh-free-search（https://github.com/DDDMUC/dsh-free-search，MIT License），
// 只保留不需要 API Key 的引擎：Bing、DuckDuckGo（html / lite）、SearXNG 公共实例，
// 按顺序自动回退；网页抓取为直连 + 私网地址拦截（SSRF 防护）+ HTML 转纯文本。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class WebResult {
  final String url;
  final String title;
  final String snippet;
  const WebResult({required this.url, this.title = '', this.snippet = ''});
}

class SearchOutcome {
  final String engine;
  final List<WebResult> results;

  /// 各引擎失败原因（回退时记录）。
  final List<String> notes;
  const SearchOutcome(this.engine, this.results, this.notes);
}

class FetchOutcome {
  final String url;
  final int statusCode;
  final String contentType;
  final String title;
  final String text;
  final bool truncated;
  const FetchOutcome({
    required this.url,
    required this.statusCode,
    required this.contentType,
    required this.title,
    required this.text,
    required this.truncated,
  });
}

class WebException implements Exception {
  final String message;
  const WebException(this.message);
  @override
  String toString() => message;
}

/// 引擎 id → 显示名。'auto' 表示按默认顺序回退。
const searchEngines = <String, String>{
  'auto': '自动（依次尝试）',
  'bing': 'Bing',
  'ddg': 'DuckDuckGo',
  'ddg-lite': 'DuckDuckGo Lite',
  'searxng': 'SearXNG',
};

const _fallbackOrder = ['bing', 'ddg', 'ddg-lite', 'searxng'];

const searxngInstances = [
  'https://opnxng.com',
  'https://priv.au',
  'https://searx.be',
  'https://searx.tiekoetter.com',
  'https://search.inetol.net',
  'https://paulgo.io',
];

const userAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36';
const acceptLanguage = 'zh-CN,zh;q=0.9,en;q=0.8';

/// 主机名解析（测试可替换）。
typedef HostResolver = Future<List<InternetAddress>> Function(String host);

Future<List<InternetAddress>> _systemLookup(String host) =>
    InternetAddress.lookup(host);

class WebSearch {
  final http.Client client;
  final Duration timeout;
  final HostResolver resolve;

  WebSearch({
    required this.client,
    this.timeout = const Duration(seconds: 12),
    this.resolve = _systemLookup,
  });

  /// 搜索：首选引擎失败或 0 结果时依次换下一个引擎；全部失败才抛 [WebException]。
  Future<SearchOutcome> search(
    String query, {
    int maxResults = 8,
    String engine = 'auto',
  }) async {
    final q = query.trim();
    if (q.isEmpty) throw const WebException('搜索词为空');
    final max = maxResults.clamp(1, 20);
    final order = <String>[
      if (_fallbackOrder.contains(engine)) engine,
      ..._fallbackOrder.where((e) => e != engine),
    ];
    final notes = <String>[];
    for (final e in order) {
      try {
        final r = await _run(e, q, max);
        if (r.isNotEmpty) return SearchOutcome(e, r, notes);
        notes.add('${searchEngines[e]}：0 条相关结果');
      } catch (err) {
        notes.add('${searchEngines[e]}：${shortText('$err')}');
      }
    }
    throw WebException('所有搜索引擎都失败了：${notes.join('；')}');
  }

  Future<List<WebResult>> _run(String engine, String q, int max) =>
      switch (engine) {
        'bing' => searchBing(q, max),
        'ddg' => searchDdgHtml(q, max),
        'ddg-lite' => searchDdgLite(q, max),
        _ => searchSearxng(q, max),
      };

  Future<String> _getText(Uri uri, {Map<String, String>? headers}) async {
    final req = http.Request('GET', uri)
      ..headers.addAll({
        'User-Agent': userAgent,
        'Accept-Language': acceptLanguage,
        ...?headers,
      });
    final resp = await client.send(req).timeout(timeout);
    final body = await resp.stream.bytesToString().timeout(timeout);
    if (resp.statusCode == 202 ||
        RegExp(
          r'anomaly|captcha|unusual traffic|robot check',
          caseSensitive: false,
        ).hasMatch(body.length > 4000 ? body.substring(0, 4000) : body)) {
      throw const WebException('被反爬验证拦截（通常是暂时的）');
    }
    if (resp.statusCode != 200) throw WebException('HTTP ${resp.statusCode}');
    return body;
  }

  Future<List<WebResult>> searchBing(String q, int max) async {
    final html = await _getText(Uri.https('www.bing.com', '/search', {'q': q}));
    return parseBing(q, html, max);
  }

  Future<List<WebResult>> searchDdgHtml(String q, int max) async {
    final html = await _getText(
      Uri.https('html.duckduckgo.com', '/html/', {'q': q}),
    );
    return parseDdgHtml(q, html, max);
  }

  Future<List<WebResult>> searchDdgLite(String q, int max) async {
    final html = await _getText(
      Uri.https('lite.duckduckgo.com', '/lite/', {'q': q}),
    );
    return parseDdgLite(q, html, max);
  }

  /// 所有公共实例并发请求，取第一个有相关结果的（实例常常很慢或挂掉）。
  Future<List<WebResult>> searchSearxng(String q, int max) async {
    final errors = <String>[];
    final done = Completer<List<WebResult>>();
    var pending = searxngInstances.length;
    for (final base in searxngInstances) {
      () async {
        try {
          final body = await _getText(
            Uri.parse('$base/search')
                .replace(queryParameters: {'q': q, 'format': 'json'}),
            headers: {'Accept': 'application/json'},
          );
          final r = parseSearxng(q, body, max);
          if (r.isNotEmpty && !done.isCompleted) done.complete(r);
          if (r.isEmpty) errors.add('${Uri.parse(base).host}：无相关结果');
        } catch (e) {
          errors.add('${Uri.parse(base).host}：${shortText('$e', 40)}');
        } finally {
          pending--;
          if (pending == 0 && !done.isCompleted) {
            done.completeError(
              WebException('实例都失败了（${shortText(errors.join('，'), 200)}）'),
            );
          }
        }
      }();
    }
    return done.future;
  }

  /// 抓取网页并转成纯文本。只允许 http/https 公网地址，最多跟随 5 次重定向。
  Future<FetchOutcome> fetch(String url, {int maxChars = 20000}) async {
    var uri = Uri.tryParse(url.trim());
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      throw WebException('只支持 http/https 网址：$url');
    }
    for (var hop = 0; hop <= 5; hop++) {
      await assertPublicHost(uri!);
      final req = http.Request('GET', uri)
        ..followRedirects = false
        ..headers.addAll({
          'User-Agent': userAgent,
          'Accept-Language': acceptLanguage,
          'Accept':
              'text/html,application/xhtml+xml,application/json,text/plain;q=0.9,*'
              '/*;q=0.5',
        });
      final resp = await client.send(req).timeout(timeout);
      if (resp.statusCode >= 300 && resp.statusCode < 400) {
        final loc = resp.headers['location'];
        await resp.stream.drain<void>();
        if (loc == null) {
          throw WebException('重定向缺少 Location（HTTP ${resp.statusCode}）');
        }
        uri = uri.resolve(loc);
        if (!(uri.isScheme('http') || uri.isScheme('https'))) {
          throw WebException('重定向到不支持的协议：$uri');
        }
        continue;
      }
      final type = resp.headers['content-type'] ?? '';
      final bytes = await readLimited(
        resp.stream,
        3 * 1024 * 1024,
      ).timeout(timeout);
      final raw = utf8.decode(bytes, allowMalformed: true);
      final isHtml =
          type.contains('html') ||
          (type.isEmpty && raw.trimLeft().startsWith('<'));
      if (!isHtml &&
          type.isNotEmpty &&
          !RegExp(r'text/|json|xml|javascript').hasMatch(type)) {
        throw WebException('不是文本内容（$type），无法读取');
      }
      final title = isHtml
          ? stripTags(
              RegExp(
                    r'<title[^>]*>([\s\S]*?)</title>',
                    caseSensitive: false,
                  ).firstMatch(raw)?.group(1) ??
                  '',
            )
          : '';
      var text = isHtml ? htmlToText(raw) : raw.trim();
      final truncated = text.length > maxChars;
      if (truncated) text = text.substring(0, maxChars);
      return FetchOutcome(
        url: uri.toString(),
        statusCode: resp.statusCode,
        contentType: type,
        title: title,
        text: text,
        truncated: truncated,
      );
    }
    throw const WebException('重定向次数过多');
  }

  /// 拒绝回环、私网、链路本地、云元数据等地址。
  Future<void> assertPublicHost(Uri uri) async {
    final host = uri.host;
    if (host.isEmpty) throw const WebException('网址缺少主机名');
    if (host == 'localhost' || host.endsWith('.localhost')) {
      throw WebException('禁止访问本机地址：$host');
    }
    final literal = InternetAddress.tryParse(host);
    final addrs = literal != null ? [literal] : await resolve(host);
    if (addrs.isEmpty) throw WebException('无法解析主机名：$host');
    for (final a in addrs) {
      if (!isPublicAddress(a)) {
        throw WebException('禁止访问内网或本机地址：$host（${a.address}）');
      }
    }
  }
}

Future<List<int>> readLimited(Stream<List<int>> s, int limit) async {
  final out = BytesBuilder(copy: false);
  await for (final chunk in s) {
    out.add(chunk);
    if (out.length >= limit) break;
  }
  return out.takeBytes();
}

List<WebResult> parseBing(String q, String html, int max) {
  final out = <WebResult>[];
  // 结果块内可能嵌套 <li>，按每个结果的起点切块，而不是找最近的 </li>。
  final starts = RegExp(r'<li class="b_algo"').allMatches(html).toList();
  for (var i = 0; i < starts.length; i++) {
    final end = i + 1 < starts.length ? starts[i + 1].start : html.length;
    final block = html.substring(starts[i].start, end);
    // 标题链接在 <h2> 里；前面可能还有站点图标链接。
    final title = RegExp(
      r'<h2[^>]*>[\s\S]*?<a[^>]*href="(https?://[^"]+)"[^>]*>([\s\S]*?)</a>',
    ).firstMatch(block);
    final href = title == null
        ? RegExp(r'<a[^>]*href="(https?://[^"]+)"').firstMatch(block)?.group(1)
        : title.group(1);
    if (href == null) continue;
    final snippet = RegExp(r'<p[^>]*>([\s\S]*?)</p>').firstMatch(block);
    out.add(
      WebResult(
        url: extractBingUrl(href),
        title: stripTags(title?.group(2) ?? ''),
        snippet: stripTags(snippet?.group(1) ?? ''),
      ),
    );
  }
  final r = uniqueResults(out, max);
  // Bing 无结果时会返回一张无关的缓存页，判为 0 结果交给回退。
  return looksRelevant(q, r) ? r : const [];
}

List<WebResult> parseDdgHtml(String q, String html, int max) {
  final out = <WebResult>[];
  final anchors = RegExp(r'<a[^>]*class="result__a"[^>]*>[\s\S]*?</a>')
      .allMatches(html)
      .toList();
  for (var i = 0; i < anchors.length; i++) {
    final a = anchors[i].group(0)!;
    final url = extractDdgUrl(
      RegExp(r'href="([^"]*)"').firstMatch(a)?.group(1),
    );
    if (url == null) continue;
    final end = i + 1 < anchors.length ? anchors[i + 1].start : html.length;
    final rest = html.substring(anchors[i].end, end);
    final snippet = RegExp(r'class="result__snippet"[^>]*>([\s\S]*?)</a>')
        .firstMatch(rest);
    out.add(
      WebResult(
        url: url,
        title: stripTags(
          RegExp(r'>([\s\S]*?)</a>$').firstMatch(a)?.group(1) ?? '',
        ),
        snippet: stripTags(snippet?.group(1) ?? ''),
      ),
    );
  }
  final r = uniqueResults(out, max);
  return looksRelevant(q, r) ? r : const [];
}

List<WebResult> parseDdgLite(String q, String html, int max) {
  final links = RegExp(
    r'''<a[^>]*class=['"]result-link['"][^>]*>[\s\S]*?</a>''',
  ).allMatches(html).map((m) => m.group(0)!).toList();
  final snippets = RegExp(
    r'''class=['"]result-snippet['"][^>]*>([\s\S]*?)</td>''',
  ).allMatches(html).map((m) => m.group(1)!).toList();
  final out = <WebResult>[];
  for (var i = 0; i < links.length; i++) {
    final url = extractDdgUrl(
      RegExp(r'''href=['"]([^'"]*)['"]''').firstMatch(links[i])?.group(1),
    );
    if (url == null) continue;
    out.add(
      WebResult(
        url: url,
        title: stripTags(
          RegExp(r'>([\s\S]*?)</a>$').firstMatch(links[i])?.group(1) ?? '',
        ),
        snippet: i < snippets.length ? stripTags(snippets[i]) : '',
      ),
    );
  }
  final r = uniqueResults(out, max);
  return looksRelevant(q, r) ? r : const [];
}

List<WebResult> parseSearxng(String q, String body, int max) {
  final j = jsonDecode(body);
  final list = j is Map ? j['results'] : null;
  if (list is! List) throw const WebException('返回格式无效');
  final out = [
    for (final r in list.whereType<Map>())
      if (r['url'] is String)
        WebResult(
          url: r['url'] as String,
          title: '${r['title'] ?? ''}',
          snippet: '${r['content'] ?? ''}',
        ),
  ];
  final r = uniqueResults(out, max);
  return looksRelevant(q, r) ? r : const [];
}

bool isPublicAddress(InternetAddress a) {
  final b = a.rawAddress;
  if (a.type == InternetAddressType.IPv4) return _publicV4(b);
  if (b.length != 16) return false;
  final allZero = b.sublist(0, 15).every((x) => x == 0);
  if (allZero && (b[15] == 0 || b[15] == 1)) return false; // :: / ::1
  final mapped =
      b.sublist(0, 10).every((x) => x == 0) && b[10] == 0xff && b[11] == 0xff;
  if (mapped) return _publicV4(b.sublist(12));
  if ((b[0] & 0xfe) == 0xfc) return false; // fc00::/7
  if (b[0] == 0xfe && (b[1] & 0xc0) == 0x80) return false; // fe80::/10
  if (b[0] == 0xff) return false; // 组播
  if (b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8) {
    return false; // 文档地址
  }
  return true;
}

bool _publicV4(List<int> p) {
  final a = p[0], b = p[1], c = p[2];
  if (a == 0 || a == 10 || a == 127) return false;
  if (a == 169 && b == 254) return false;
  if (a == 172 && b >= 16 && b <= 31) return false;
  if (a == 192 && b == 168) return false;
  if (a == 100 && b >= 64 && b <= 127) return false;
  if (a == 192 && b == 0 && (c == 0 || c == 2)) return false;
  if (a == 198 && (b == 18 || b == 19)) return false;
  if (a == 198 && b == 51 && c == 100) return false;
  if (a == 203 && b == 0 && c == 113) return false;
  if (a >= 224) return false;
  return true;
}

String decodeEntities(String s) => s
    .replaceAllMapped(
      RegExp(r'&#[xX]([0-9a-fA-F]+);'),
      (m) => _char(int.tryParse(m.group(1)!, radix: 16)),
    )
    .replaceAllMapped(
      RegExp(r'&#(\d+);'),
      (m) => _char(int.tryParse(m.group(1)!)),
    )
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&ensp;', ' ')
    .replaceAll('&emsp;', ' ')
    .replaceAll('&middot;', '·')
    .replaceAll('&amp;', '&');

String _char(int? code) {
  if (code == null || code <= 0 || code > 0x10FFFF) return '';
  if (code >= 0xD800 && code <= 0xDFFF) return '';
  return String.fromCharCode(code);
}

String stripTags(String html) => decodeEntities(
  html.replaceAll(RegExp(r'<[^>]+>'), ' ').replaceAll(RegExp(r'\s+'), ' '),
).replaceAll(RegExp(r'\s+'), ' ').trim();

/// HTML → 可读纯文本：去掉脚本/样式/注释，块级元素换行，链接保留文字。
String htmlToText(String html) {
  var s = html
      .replaceAll(RegExp(r'<!--[\s\S]*?-->'), '')
      .replaceAll(
        RegExp(
          r'<(script|style|noscript|template|svg|head)\b[^>]*>[\s\S]*?</\1>',
          caseSensitive: false,
        ),
        '',
      );
  final body = RegExp(
    r'<body[^>]*>([\s\S]*)</body>',
    caseSensitive: false,
  ).firstMatch(s);
  if (body != null) s = body.group(1)!;
  s = s
      .replaceAll(RegExp(r'<br\s*\/?>', caseSensitive: false), '\n')
      .replaceAllMapped(
        RegExp(r'<h([1-6])\b[^>]*>', caseSensitive: false),
        (m) => '\n\n${'#' * int.parse(m.group(1)!)} ',
      )
      .replaceAll(RegExp(r'<li\b[^>]*>', caseSensitive: false), '\n- ')
      .replaceAll(RegExp(r'<(td|th)\b[^>]*>', caseSensitive: false), ' | ')
      .replaceAll(
        RegExp(
          r'</?(p|div|section|article|header|footer|main|nav|aside|ul|ol|table|tr|h[1-6]|pre|blockquote|dl|dt|dd|figure|form)\b[^>]*>',
          caseSensitive: false,
        ),
        '\n',
      )
      .replaceAll(RegExp(r'<[^>]+>'), '');
  s = decodeEntities(s);
  final out = StringBuffer();
  var blank = false;
  for (final raw in s.split('\n')) {
    final l = raw.replaceAll(RegExp(r'[ \t\r\f\v\u00a0]+'), ' ').trim();
    if (l.isEmpty || l == '|' || l == '-') {
      blank = true;
      continue;
    }
    if (out.isNotEmpty) out.write(blank ? '\n\n' : '\n');
    out.write(l);
    blank = false;
  }
  return out.toString();
}

/// Bing 会把结果包成 bing.com/ck/a 跳转链接，真实地址在 u 参数（a1 + base64url）。
String extractBingUrl(String href) {
  final url = decodeEntities(href);
  if (!RegExp(
    r'^https?://(www\.)?bing\.com/ck/a',
    caseSensitive: false,
  ).hasMatch(url)) {
    return url;
  }
  try {
    final u = Uri.parse(url).queryParameters['u'];
    if (u == null) return url;
    var b64 = (u.startsWith('a1') ? u.substring(2) : u)
        .replaceAll('-', '+')
        .replaceAll('_', '/');
    while (b64.length % 4 != 0) {
      b64 += '=';
    }
    final decoded = utf8.decode(base64.decode(b64), allowMalformed: true);
    return RegExp(r'^https?://').hasMatch(decoded) ? decoded : url;
  } catch (_) {
    return url;
  }
}

String? extractDdgUrl(String? rel) {
  if (rel == null || rel.isEmpty) return null;
  final r = decodeEntities(rel);
  final m = RegExp(r'uddg=([^&]+)').firstMatch(r);
  if (m != null) {
    try {
      return Uri.decodeComponent(m.group(1)!);
    } catch (_) {
      return m.group(1);
    }
  }
  if (r.contains('duckduckgo.com/y.js')) return null; // 广告
  if (r.startsWith('//')) return 'https:$r';
  if (!r.startsWith('http')) return null;
  return r;
}

List<WebResult> uniqueResults(List<WebResult> list, int limit) {
  final seen = <String>{};
  final out = <WebResult>[];
  for (final r in list) {
    if (r.url.isEmpty || !seen.add(r.url)) continue;
    out.add(r);
    if (out.length >= limit) break;
  }
  return out;
}

/// 查询词：中文取二元组，拉丁/数字取长度 ≥2 的词。
List<String> queryTokens(String query) {
  final tokens = <String>{};
  for (final m in RegExp(r'[\u4e00-\u9fff]+').allMatches(query)) {
    final run = m.group(0)!;
    if (run.length == 1) continue;
    for (var i = 0; i + 1 < run.length; i++) {
      tokens.add(run.substring(i, i + 2));
    }
  }
  for (final w in query.toLowerCase().split(RegExp(r'[^a-z0-9]+'))) {
    if (w.length >= 2) tokens.add(w);
  }
  return tokens.toList();
}

/// 结果和查询词几乎没有重叠时视为无效页（引擎返回了缓存/热门页）。
bool looksRelevant(String query, List<WebResult> results) {
  if (results.isEmpty) return false;
  final tokens = queryTokens(query);
  if (tokens.isEmpty) return true;
  final strong = tokens.where((t) => !RegExp(r'^\d+$').hasMatch(t)).toList();
  final usable = strong.isNotEmpty ? strong : tokens;
  final titleStrong = usable
      .where((t) => RegExp(r'[\u4e00-\u9fff]').hasMatch(t) || t.length >= 4)
      .toList();
  final titleTokens = titleStrong.isNotEmpty ? titleStrong : usable;
  final matched = <String>{};
  var titleHit = false;
  var relevant = 0;
  for (final r in results) {
    final title = r.title.toLowerCase();
    final hay = '$title ${r.snippet} ${r.url}'.toLowerCase();
    final hits = usable.where(hay.contains).toList();
    if (hits.isEmpty) continue;
    relevant++;
    matched.addAll(hits);
    if (titleTokens.any(title.contains)) titleHit = true;
  }
  final enoughSources = relevant >= (results.length / 3).ceil();
  final enoughTokens =
      matched.length >= (usable.length < 2 ? usable.length : 2) ||
      matched.length / usable.length >= 0.5;
  return enoughSources && enoughTokens && titleHit;
}

String shortText(String s, [int max = 120]) {
  final one = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return one.length > max ? '${one.substring(0, max)}…' : one;
}

/// 外部内容边界标记，正文中出现的同名结束标记会被去掉，防止提前闭合。
String _guard(String s) => s.replaceAll('</untrusted-web-content>', '');

/// 把搜索结果格式化给模型（外部数据放在边界标记内）。
String formatSearch(String query, SearchOutcome o) {
  final b = StringBuffer()
    ..writeln('搜索“$query”，引擎：${searchEngines[o.engine] ?? o.engine}');
  if (o.notes.isNotEmpty) b.writeln('（回退记录：${o.notes.join('；')}）');
  b.writeln('<untrusted-web-content>');
  for (var i = 0; i < o.results.length; i++) {
    final r = o.results[i];
    var snip = r.snippet.trim();
    if (snip.length > 300) snip = '${snip.substring(0, 300)}…';
    b
      ..writeln('${i + 1}. ${_guard(r.title.isEmpty ? r.url : r.title)}')
      ..writeln('   ${_guard(r.url)}');
    if (snip.isNotEmpty) b.writeln('   ${_guard(snip)}');
  }
  b.write('</untrusted-web-content>');
  return b.toString();
}

String formatFetch(FetchOutcome f) {
  final text = _guard(f.text);
  final type = f.contentType.isEmpty ? '' : '，${f.contentType}';
  final title = f.title.isEmpty ? '' : '标题：${_guard(f.title)}\n';
  final body = text.isEmpty ? '（页面没有可读文本，可能需要 JavaScript 渲染）' : text;
  final more = f.truncated ? '\n（正文过长已截断，可调大 max_chars）' : '';
  return '网址：${f.url}（HTTP ${f.statusCode}$type）\n$title'
      '<untrusted-web-content>\n$body\n</untrusted-web-content>$more';
}
