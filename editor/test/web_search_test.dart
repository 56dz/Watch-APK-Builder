import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:android_watch_editor/services/web_search.dart';

String b64url(String s) => base64Url.encode(utf8.encode(s)).replaceAll('=', '');

Future<List<InternetAddress>> publicDns(String host) async => [
  InternetAddress('93.184.216.34'),
];

void main() {
  group('解析', () {
    test('Bing 跳转链接还原真实地址', () {
      final real = 'https://example.com/a?b=1';
      final href =
          'https://www.bing.com/ck/a?!&amp;&amp;p=x&amp;u=a1${b64url(real)}&amp;ntb=1';
      expect(extractBingUrl(href), real);
      expect(extractBingUrl('https://foo.com/x'), 'https://foo.com/x');
    });

    test('Bing 结果解析并做相关性检查', () {
      const html = '''
<ol id="b_results">
<li class="b_algo"><h2><a href="https://www.hltv.org/matches">CS2 matches &amp; results | HLTV</a></h2><div class="b_caption"><p>Upcoming CS2 matches</p></div></li>
<li class="b_algo"><h2><a href="https://liquipedia.net/counterstrike">Counter-Strike CS2 matches</a></h2><p>Tournaments</p></li>
</ol>''';
      final r = parseBing('CS2 matches', html, 8);
      expect(r.length, 2);
      expect(r.first.title, 'CS2 matches & results | HLTV');
      expect(r.first.url, 'https://www.hltv.org/matches');
      expect(parseBing('安卓 手表 屏幕', html, 8), isEmpty);
    });

    test('DuckDuckGo html 解析 uddg 链接', () {
      const html = '''
<div class="result results_links results_links_deep web-result">
 <div class="links_main links_deep result__body">
  <h2 class="result__title"><a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fdeveloper.android.com%2Ftraining%2Fwearables&amp;rut=abc">Wear OS <b>round</b> screen</a></h2>
  <a class="result__snippet" href="x">Build apps for round screen watches</a>
 </div>
</div>''';
      final r = parseDdgHtml('wear round screen', html, 8);
      expect(r.single.url, 'https://developer.android.com/training/wearables');
      expect(r.single.title, 'Wear OS round screen');
      expect(r.single.snippet, 'Build apps for round screen watches');
    });

    test('DuckDuckGo lite 解析', () {
      const html = '''
<table><tr><td><a rel="nofollow" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fa.com%2Fflutter" class='result-link'>Flutter http package</a></td></tr>
<tr><td class='result-snippet'>Flutter http package docs</td></tr></table>''';
      final r = parseDdgLite('flutter http', html, 8);
      expect(r.single.url, 'https://a.com/flutter');
      expect(r.single.snippet, 'Flutter http package docs');
    });

    test('SearXNG JSON 解析', () {
      final body = jsonEncode({
        'results': [
          {'url': 'https://x.com/1', 'title': '圆屏手表适配', 'content': '圆屏适配经验'},
          {'url': 'https://x.com/1', 'title': '重复', 'content': ''},
        ],
      });
      final r = parseSearxng('圆屏手表', body, 8);
      expect(r.length, 1);
    });

    test('中文查询词切二元组', () {
      expect(queryTokens('圆屏手表'), containsAll(['圆屏', '屏手', '手表']));
      expect(queryTokens('CS2 赛事'), containsAll(['cs2', '赛事']));
    });

    test('HTML 转文本去掉脚本样式', () {
      const html =
          '<html><head><title>T</title><style>a{}</style></head><body><script>x()</script><h1>标题</h1><p>第一段&amp;内容</p><ul><li>甲</li><li>乙</li></ul></body></html>';
      final t = htmlToText(html);
      expect(t, contains('# 标题'));
      expect(t, contains('第一段&内容'));
      expect(t, contains('- 甲'));
      expect(t, isNot(contains('x()')));
      expect(t, isNot(contains('a{}')));
    });
  });

  group('私网地址拦截', () {
    test('IPv4 / IPv6', () {
      for (final a in [
        '127.0.0.1',
        '10.1.2.3',
        '172.16.0.1',
        '192.168.1.1',
        '169.254.169.254',
        '100.64.0.1',
        '0.0.0.0',
        '::1',
        'fe80::1',
        'fd00::1',
        '::ffff:192.168.1.1',
      ]) {
        expect(isPublicAddress(InternetAddress(a)), isFalse, reason: a);
      }
      for (final a in ['8.8.8.8', '93.184.216.34', '2606:4700::1111']) {
        expect(isPublicAddress(InternetAddress(a)), isTrue, reason: a);
      }
    });

    test('fetch 拒绝内网与本机', () async {
      final web = WebSearch(
        client: MockClient((_) async => http.Response('no', 200)),
        resolve: (_) async => [InternetAddress('192.168.0.5')],
      );
      expect(
        () => web.fetch('http://router.lan/'),
        throwsA(isA<WebException>()),
      );
      expect(
        () => web.fetch('http://127.0.0.1:8080/'),
        throwsA(isA<WebException>()),
      );
      expect(() => web.fetch('file:///c:/x'), throwsA(isA<WebException>()));
    });

    test('重定向到内网被拦截', () async {
      final web = WebSearch(
        client: MockClient(
          (_) async => http.Response(
            '',
            302,
            headers: {'location': 'http://10.0.0.1/admin'},
          ),
        ),
        resolve: publicDns,
      );
      expect(
        () => web.fetch('https://example.com/'),
        throwsA(isA<WebException>()),
      );
    });
  });

  test('fetch 返回正文并截断', () async {
    final web = WebSearch(
      client: MockClient(
        (_) async => http.Response.bytes(
          utf8.encode(
            '<html><head><title>页面</title></head><body><p>${'字' * 3000}</p></body></html>',
          ),
          200,
          headers: {'content-type': 'text/html; charset=utf-8'},
        ),
      ),
      resolve: publicDns,
    );
    final f = await web.fetch('https://example.com/', maxChars: 1000);
    expect(f.title, '页面');
    expect(f.text.length, 1000);
    expect(f.truncated, isTrue);
    expect(formatFetch(f), contains('<untrusted-web-content>'));
  });

  test('搜索被拦截时自动回退到下一个引擎', () async {
    final hosts = <String>[];
    final web = WebSearch(
      client: MockClient((req) async {
        hosts.add(req.url.host);
        if (req.url.host == 'www.bing.com') {
          return http.Response('<html>captcha</html>', 200);
        }
        return http.Response(
          '<div class="result results_links"><a class="result__a" href="https://hltv.org/x">CS2 赛事 比分</a><a class="result__snippet">CS2 赛事数据</a></div>',
          200,
          headers: {'content-type': 'text/html; charset=utf-8'},
        );
      }),
      resolve: publicDns,
    );
    final o = await web.search('CS2 赛事');
    expect(o.engine, 'ddg');
    expect(o.results.single.url, 'https://hltv.org/x');
    expect(o.notes.single, contains('Bing'));
    expect(hosts.first, 'www.bing.com');
    final text = formatSearch('CS2 赛事', o);
    expect(text, contains('<untrusted-web-content>'));
    expect(text, contains('https://hltv.org/x'));
  });

  test('首选引擎优先，全部失败时抛错', () async {
    final hosts = <String>[];
    final web = WebSearch(
      client: MockClient((req) async {
        hosts.add(req.url.host);
        return http.Response('err', 500);
      }),
      resolve: publicDns,
    );
    await expectLater(
      web.search('abc test', engine: 'ddg-lite'),
      throwsA(isA<WebException>()),
    );
    expect(hosts.first, 'lite.duckduckgo.com');
    expect(hosts, contains('www.bing.com'));
    expect(hosts, contains('priv.au'));
  });
}
