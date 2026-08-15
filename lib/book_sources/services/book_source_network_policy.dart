import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../protocol/book_source_protocol.dart';

typedef BookSourceAddressLookup =
    Future<List<InternetAddress>> Function(String host);

class BookSourceNetworkPolicy {
  const BookSourceNetworkPolicy({
    BookSourceAddressLookup? lookup,
    this.allowPrivateNetwork = false,
    this.allowSyntheticDns = false,
  }) : _lookup = lookup ?? InternetAddress.lookup;

  final BookSourceAddressLookup _lookup;
  final bool allowPrivateNetwork;
  final bool allowSyntheticDns;

  /// 库级 DNS 缓存与去重：每次请求 resolve 至少触发一次 lookup，而
  /// 聚合搜索/发现页会对上百个源并发校验+建连，同一 host 会被解析
  /// 多次并大量占用系统 DNS，是大面积超时的主因之一。缓存为库级
  /// 静态：const 策略实例间共享；仅默认 lookup 才启用，测试注入的
  /// 自定义 lookup 不经过缓存，避免相互污染。
  static const Duration _dnsCacheTtl = Duration(minutes: 5);
  static const int _dnsCacheMaxEntries = 512;
  static final Map<String, _DnsCacheEntry> _dnsCache = {};
  static final Map<String, Future<List<InternetAddress>>> _dnsInFlight = {};

  Future<void> validate(Uri uri) async {
    await resolve(uri);
  }

  Future<List<InternetAddress>> resolve(Uri uri) async {
    if (!uri.hasAuthority || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const BookSourceProtocolException(
        'Book source targets must use HTTP or HTTPS.',
      );
    }
    final literal = InternetAddress.tryParse(uri.host);
    final addresses = literal == null
        ? await _resolveHost(uri.host)
        : [literal];
    if (addresses.isEmpty ||
        addresses.any(
          (address) =>
              _isAlwaysBlockedAddress(address) ||
              (!allowPrivateNetwork &&
                  isBlockedAddress(
                    address,
                    allowSyntheticDns: allowSyntheticDns,
                  )),
        )) {
      throw const BookSourceProtocolException(
        'This address is not allowed as a book source target.',
      );
    }
    return addresses;
  }

  Future<List<InternetAddress>> _resolveHost(String host) {
    // 自定义 lookup（测试注入）不走共享缓存。
    if (_lookup != InternetAddress.lookup) return _lookup(host);
    final cached = _dnsCache[host];
    if (cached != null) {
      if (cached.expiresAt.isAfter(DateTime.now())) {
        return Future.value(cached.addresses);
      }
      _dnsCache.remove(host);
    }
    final inFlight = _dnsInFlight[host];
    if (inFlight != null) return inFlight;
    final future = _resolveWithDohRace(host);
    _dnsInFlight[host] = future;
    // 回调必须是 void 语句体。若写成 `() => _dnsInFlight.remove(host)`,
    // 返回值是刚存入的 future 本身, whenComplete 会把它当 FutureOr
    // 等待, 形成 "future 等待自己完成" 的自引用死锁——表现为所有冷
    // DNS 解析永久挂起、聚合搜索大面积超时。
    // 包装 future 的结果调用方不消费, 必须 ignore 掉, 否则解析失败时
    // 它会以无监听错误完成, 变成 unhandled async error。
    future
        .whenComplete(() {
          _dnsInFlight.remove(host);
        })
        .ignore();
    return future;
  }

  /// 系统解析与公共 DoH (223.5.5.5) 竞速，先成功者胜出。
  ///
  /// 动机：部分网络环境下系统 DNS 服务器无响应或极慢（实测未缓存域名
  /// 解析可达 12s+），直接拖垮聚合搜索；运营商劫持场景下 DoH 也能给出
  /// 干净结果。任一通道失败/超时都被折叠为"永不完成"，让另一条通道独
  /// 立胜出；两条通道都失败时由整体 6s 硬上限兜底报错，绝不永久悬挂。
  /// 系统解析侧的分支超时仅在真实运行环境启用（widget 测试环境下真实
  /// DNS 查询可能不完成，超时定时器会在 teardown 时以 pending timer 报
  /// 错），整体硬上限在两种环境下都会生效。
  Future<List<InternetAddress>> _resolveWithDohRace(String host) async {
    Future<List<InternetAddress>> never() =>
        Completer<List<InternetAddress>>().future;

    Future<List<InternetAddress>> foldNever(
      Future<List<InternetAddress>> future, [
      Duration? cap,
    ]) {
      final capped = cap == null ? future : future.timeout(cap, onTimeout: never);
      return capped.catchError((Object _) => never());
    }

    final system = foldNever(
      _lookup(host),
      _dnsTimeoutEnabled ? const Duration(seconds: 5) : null,
    );
    final doh = foldNever(_dohResolve(host), const Duration(seconds: 4));
    final addresses = await Future.any([system, doh]).timeout(
      const Duration(seconds: 6),
      onTimeout: () => throw const SocketException(
        'DNS resolution timed out (system resolver and DoH both failed)',
      ),
    );
    if (addresses.isEmpty) {
      throw const SocketException('DNS resolution produced no addresses');
    }
    _storeDns(host, addresses);
    return addresses;
  }

  /// AliDNS DoH JSON API（IP 直连，无递归解析问题）。
  static Future<List<InternetAddress>> _dohResolve(String host) async {
    final client = _dohClient;
    if (client == null) throw const SocketException('DoH client disabled');
    final request = await client.getUrl(
      Uri.https('223.5.5.5', '/resolve', {'name': host, 'type': '1'}),
    );
    final response = await request.close();
    if (response.statusCode != 200) {
      throw const SocketException('DoH returned a non-200 status');
    }
    final body = await response.transform(utf8.decoder).join();
    final decoded = jsonDecode(body);
    final answer = decoded is Map ? decoded['Answer'] : null;
    if (answer is! List) throw const SocketException('DoH has no answer');
    final addresses = <InternetAddress>[];
    for (final entry in answer) {
      if (entry is Map && entry['type'] == 1 && entry['data'] is String) {
        final parsed = InternetAddress.tryParse(entry['data'] as String);
        if (parsed != null) addresses.add(parsed);
      }
    }
    if (addresses.isEmpty) throw const SocketException('DoH has no A record');
    return addresses;
  }

  static final HttpClient? _dohClient = _createDohClient();

  static HttpClient _createDohClient() {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 3);
    client.idleTimeout = const Duration(seconds: 30);
    return client;
  }

  static final bool _dnsTimeoutEnabled = !Platform.environment.containsKey(
    'FLUTTER_TEST',
  );

  static void _storeDns(String host, List<InternetAddress> addresses) {
    if (_dnsCache.length >= _dnsCacheMaxEntries) _dnsCache.clear();
    _dnsCache[host] = _DnsCacheEntry(
      addresses: List.unmodifiable(addresses),
      expiresAt: DateTime.now().add(_dnsCacheTtl),
    );
  }

  HttpClient createPinnedHttpClient() {
    final client = HttpClient();
    client.connectionFactory = (uri, proxyHost, proxyPort) async {
      final targetHost = proxyHost ?? uri.host;
      final targetPort = proxyPort ?? uri.port;
      final targetUri = proxyHost == null
          ? uri
          : Uri(scheme: 'http', host: targetHost, port: targetPort);
      final addresses = await resolve(targetUri);
      // IPv4 优先: DNS 常把 AAAA 记录排在前面, 而移动/家用网络普遍
      // 存在"有 IPv6 地址但路由不通"的情况, 单连接 startConnect 不像
      // curl 有 Happy Eyeballs 回落, 会一直卡到超时——这是聚合搜索
      // 大面积超时的根因。IPv6-only 环境仍回退到首个地址。
      final address = addresses.firstWhere(
        (candidate) => candidate.type == InternetAddressType.IPv4,
        orElse: () => addresses.first,
      );
      final task = await Socket.startConnect(address, targetPort);
      // 自定义 connectionFactory 下 HttpClient.connectionTimeout 不会
      // 生效，黑洞站点会让请求永久挂起。ConnectionTask 是 final 类无法
      // 包装，这里挂一个看门狗：6s 内未建连成功就 cancel 掉任务，让
      // task.socket 以错误完成；已建连成功时 cancel 是空操作。
      final watchdog = Timer(const Duration(seconds: 6), task.cancel);
      // 派生 future 必须忽略错误: 连接失败时 task.socket 以错误完成,
      // whenComplete 的返回值若无人消费会在外层 zone 变成 uncaught
      // error —— 在 dio 拦截器 zone 里会触发 handler 被重复 complete
      // ("Bad state: The handler has already been called")。
      task.socket.whenComplete(watchdog.cancel).ignore();
      return task;
    };
    return client;
  }

  static bool isBlockedAddress(
    InternetAddress address, {
    bool allowSyntheticDns = false,
  }) {
    if (address.isLoopback || address.isLinkLocal || address.isMulticast) {
      return true;
    }

    final bytes = address.rawAddress;
    if (bytes.length == 4) {
      return _isBlockedIpv4(bytes, allowSyntheticDns: allowSyntheticDns);
    }
    if (bytes.length != 16) return true;

    // IPv4-mapped IPv6 addresses must inherit the IPv4 restrictions.
    final isIpv4Mapped =
        bytes.take(10).every((byte) => byte == 0) &&
        bytes[10] == 0xff &&
        bytes[11] == 0xff;
    if (isIpv4Mapped) {
      return _isBlockedIpv4(
        bytes.sublist(12),
        allowSyntheticDns: allowSyntheticDns,
      );
    }

    // Unspecified, loopback, and unique-local (fc00::/7) addresses.
    if (bytes.every((byte) => byte == 0) ||
        (bytes.take(15).every((byte) => byte == 0) && bytes[15] == 1) ||
        (bytes[0] & 0xfe) == 0xfc) {
      return true;
    }
    return false;
  }

  static bool _isAlwaysBlockedAddress(InternetAddress address) {
    if (address.isMulticast) return true;
    final bytes = address.rawAddress;
    if (bytes.every((byte) => byte == 0)) return true;
    return bytes.length == 4 && bytes[0] >= 224;
  }

  static bool _isBlockedIpv4(
    List<int> bytes, {
    bool allowSyntheticDns = false,
  }) {
    final first = bytes[0];
    final second = bytes[1];
    return first == 0 ||
        first == 10 ||
        first == 127 ||
        (first == 100 && (second & 0xc0) == 0x40) ||
        (first == 169 && second == 254) ||
        (first == 172 && (second & 0xf0) == 16) ||
        (first == 192 && second == 168) ||
        (!allowSyntheticDns &&
            first == 198 &&
            (second == 18 || second == 19)) ||
        first >= 224;
  }

  static Uri redirectTarget(Uri current, String? location) {
    if (location == null || location.trim().isEmpty) {
      throw const BookSourceProtocolException(
        'Book source redirect is missing its target.',
      );
    }
    final target = current.resolve(location.trim());
    if (target.scheme != 'http' && target.scheme != 'https') {
      throw const BookSourceProtocolException(
        'Book source redirects must use HTTP or HTTPS.',
      );
    }
    if (current.scheme == 'https' && target.scheme == 'http') {
      throw const BookSourceProtocolException(
        'Book source redirects cannot downgrade HTTPS to HTTP.',
      );
    }
    return target;
  }
}

class _DnsCacheEntry {
  const _DnsCacheEntry({required this.addresses, required this.expiresAt});

  final List<InternetAddress> addresses;
  final DateTime expiresAt;
}
