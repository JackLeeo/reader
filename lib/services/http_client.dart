// HTTP客户端，支持书源自定义Header
import 'package:dio/dio.dart';

import '../models/book_source.dart';

class HttpClient {
  final Dio _dio;

  HttpClient() : _dio = Dio() {
    _dio.options
      ..connectTimeout = const Duration(seconds: 15)
      ..receiveTimeout = const Duration(seconds: 20)
      ..headers = {
        'User-Agent':
            'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1',
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9,en-US;q=0.8,en;q=0.7',
      };
  }

  /// 用书源的header获取内容
  Future<Response<String>> get(
    String url, {
    BookSource? source,
    Map<String, String>? extraHeaders,
  }) async {
    final headers = <String, String>{};
    if (source != null) {
      headers.addAll(source.header);
    }
    if (extraHeaders != null) {
      headers.addAll(extraHeaders);
    }

    return _dio.get<String>(
      url,
      options: Options(
        responseType: ResponseType.plain,
        headers: headers,
        followRedirects: true,
        validateStatus: (s) => s != null && s < 500,
      ),
    );
  }

  /// 直接获取二进制（图片等）
  Future<Response<List<int>>> getBytes(String url) async {
    return _dio.get<List<int>>(
      url,
      options: Options(responseType: ResponseType.bytes),
    );
  }
}
