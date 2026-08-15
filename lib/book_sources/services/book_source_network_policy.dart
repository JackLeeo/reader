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
    // 系统 DNS 解析器在无响应时会长时间内部重试，这里强制 5s 超时，
    // 避免聚合搜索时单个域名拖垮整体进度。widget 测试环境下真实 DNS
    // 查询不会完成，超时定时器会在 teardown 时以 pending timer 报错，
    // 因此仅在真实运行时启用该上限。
    final lookup = _dnsTimeoutEnabled
        ? _lookup(host).timeout(const Duration(seconds: 5))
        : _lookup(host);
    final future = lookup.then((addresses) {
      if (addresses.isNotEmpty) _storeDns(host, addresses);
      return addresses;
    }).whenComplete(() => _dnsInFlight.remove(host));
    _dnsInFlight[host] = future;
    return future;
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
      return Socket.startConnect(addresses.first, targetPort);
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
