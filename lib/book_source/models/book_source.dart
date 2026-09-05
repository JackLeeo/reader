import 'dart:convert';

/// 官方 `BookSource`（书源）JSON schema 对齐的数据模型。
///
/// 字段命名与官方 `io.legado.app.data.entities.BookSource` 一致，
/// 未知字段被忽略，缺失字段取默认值，便于直接 `jsonDecode` 书源备份。
class BookSource {
  BookSource({
    this.bookSourceUrl = '',
    this.bookSourceName = '',
    this.bookSourceGroup,
    this.bookSourceType = 0,
    this.bookUrlPattern,
    this.customOrder = 0,
    this.enabled = true,
    this.enabledExplore = true,
    this.jsLib,
    this.enabledCookieJar = true,
    this.concurrentRate,
    this.header,
    this.loginUrl,
    this.loginUi,
    this.loginCheckJs,
    this.coverDecodeJs,
    this.bookSourceComment,
    this.variableComment,
    this.lastUpdateTime = 0,
    this.respondTime = 180000,
    this.weight = 0,
    this.exploreUrl,
    this.exploreScreen,
    this.ruleExplore,
    this.searchUrl,
    this.ruleSearch,
    this.ruleBookInfo,
    this.ruleToc,
    this.ruleContent,
    this.ruleReview,
    this.mainJs,
    this.eventListener = false,
    this.customButton = false,
    List<String>? groups,
  }) : groups = groups ?? _parseGroups(bookSourceGroup);

  /// 地址（http/https），作为唯一主键
  final String bookSourceUrl;

  /// 名称
  final String bookSourceName;

  /// 分组（逗号分隔，人工管理用）
  final String? bookSourceGroup;

  /// 类型：0 文本，1 音频，2 图片，3 文件，4 视频
  final int bookSourceType;

  /// 详情页 url 正则
  final String? bookUrlPattern;

  final int customOrder;

  /// 是否启用（聚合搜索只搜启用源）
  final bool enabled;

  final bool enabledExplore;

  /// JS 库
  final String? jsLib;

  /// 是否启用 CookieJar 自动保存 cookie
  final bool? enabledCookieJar;

  /// 并发率（如 1000/1s）
  final String? concurrentRate;

  /// 请求头（多行 `key: value`）
  final String? header;

  final String? loginUrl;
  final String? loginUi;
  final String? loginCheckJs;
  final String? coverDecodeJs;
  final String? bookSourceComment;
  final String? variableComment;
  final int lastUpdateTime;
  final int respondTime;
  final int weight;

  /// 发现 url
  final String? exploreUrl;
  final String? exploreScreen;
  final Map<String, dynamic>? ruleExplore;

  final String? searchUrl;
  final SearchRule? ruleSearch;
  final BookInfoRule? ruleBookInfo;
  final TocRule? ruleToc;
  final ContentRule? ruleContent;
  final Map<String, dynamic>? ruleReview;

  /// 纯 JS 单文件书源主脚本
  final String? mainJs;

  /// 是否监听事件来执行回调规则（官方 `eventListener`）。
  final bool eventListener;

  /// 是否由书源控制的自定义按钮（官方 `customButton`）。
  final bool customButton;

  /// 分组展开后的名称集
  final List<String> groups;

  bool get isTextSource => bookSourceType == 0;
  bool get isJsSource => (mainJs ?? '').isNotEmpty;

  /// 是否音频/听书源（type=1）。
  bool get isAudioSource => bookSourceType == 1;

  /// 是否图片/漫画源（type=2）。
  bool get isImageSource => bookSourceType == 2;

  /// 是否视频源（type=4）。
  bool get isVideoSource => bookSourceType == 4;

  /// 是否任意媒体源（非文本：音频/图片/文件/视频）。
  bool get isMediaSource => bookSourceType != 0;

  /// 是否可被“发现”页浏览（配置了发现地址）。
  bool get isExploreSource =>
      enabledExplore && (exploreUrl ?? '').trim().isNotEmpty;

  static List<String> _parseGroups(String? g) {
    if (g == null) return const [];
    return g
        .split(RegExp(r'[,&，、]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  BookSource copyWith({
    bool? enabled,
    bool? enabledExplore,
    List<String>? groups,
  }) {
    final newEnabled = enabled ?? this.enabled;
    final newExplore = enabledExplore ?? this.enabledExplore;
    final newGroups = groups ?? this.groups;
    return BookSource(
      bookSourceUrl: bookSourceUrl,
      bookSourceName: bookSourceName,
      bookSourceGroup: newGroups.join(','),
      bookSourceType: bookSourceType,
      bookUrlPattern: bookUrlPattern,
      customOrder: customOrder,
      enabled: newEnabled,
      enabledExplore: newExplore,
      jsLib: jsLib,
      enabledCookieJar: enabledCookieJar,
      concurrentRate: concurrentRate,
      header: header,
      loginUrl: loginUrl,
      loginUi: loginUi,
      loginCheckJs: loginCheckJs,
      coverDecodeJs: coverDecodeJs,
      bookSourceComment: bookSourceComment,
      variableComment: variableComment,
      lastUpdateTime: lastUpdateTime,
      respondTime: respondTime,
      weight: weight,
      exploreUrl: exploreUrl,
      exploreScreen: exploreScreen,
      ruleExplore: ruleExplore,
      searchUrl: searchUrl,
      ruleSearch: ruleSearch,
      ruleBookInfo: ruleBookInfo,
      ruleToc: ruleToc,
      ruleContent: ruleContent,
      ruleReview: ruleReview,
      mainJs: mainJs,
      eventListener: eventListener,
      customButton: customButton,
      groups: newGroups,
    );
  }

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'bookSourceUrl': bookSourceUrl,
      'bookSourceName': bookSourceName,
      'bookSourceType': bookSourceType,
      'customOrder': customOrder,
      'enabled': enabled,
      'enabledExplore': enabledExplore,
      'lastUpdateTime': lastUpdateTime,
      'respondTime': respondTime,
      'weight': weight,
      'searchUrl': searchUrl,
      'bookUrlPattern': bookUrlPattern,
      'coverDecodeJs': coverDecodeJs,
      'loginCheckJs': loginCheckJs,
      'variableComment': variableComment,
      'jsLib': jsLib,
      'mainJs': mainJs,
      'exploreUrl': exploreUrl,
      'exploreScreen': exploreScreen,
      'ruleExplore': ruleExplore,
      'ruleSearch': ruleSearch?.toJson(),
      'ruleBookInfo': ruleBookInfo?.toJson(),
      'ruleToc': ruleToc?.toJson(),
      'ruleContent': ruleContent?.toJson(),
      'ruleReview': ruleReview,
      'eventListener': eventListener,
      'customButton': customButton,
    };
    // 可空字段，非空才写，保持备份整洁
    _putIfNotNull(m, 'bookSourceGroup', bookSourceGroup);
    _putIfNotNull(m, 'enabledCookieJar', enabledCookieJar);
    _putIfNotNull(m, 'concurrentRate', concurrentRate);
    _putIfNotNull(m, 'header', header);
    _putIfNotNull(m, 'loginUrl', loginUrl);
    _putIfNotNull(m, 'loginUi', loginUi);
    _putIfNotNull(m, 'bookSourceComment', bookSourceComment);
    final needDelete = m.keys.where((k) => m[k] == null).toList();
    for (final k in needDelete) {
      m.remove(k);
    }
    return m;
  }

  static void _putIfNotNull(Map<String, dynamic> m, String k, dynamic v) {
    if (v != null) m[k] = v;
  }

  static BookSource fromJson(Map<String, dynamic> json) {
    return BookSource(
      bookSourceUrl: _str(json, 'bookSourceUrl'),
      bookSourceName: _str(json, 'bookSourceName'),
      bookSourceGroup: json['bookSourceGroup'] as String?,
      bookSourceType: _int(json, 'bookSourceType', 0),
      bookUrlPattern: json['bookUrlPattern'] as String?,
      customOrder: _int(json, 'customOrder', 0),
      enabled: json['enabled'] as bool? ?? true,
      enabledExplore: json['enabledExplore'] as bool? ?? true,
      jsLib: json['jsLib'] as String?,
      enabledCookieJar: json['enabledCookieJar'] as bool? ?? true,
      concurrentRate: json['concurrentRate'] as String?,
      header: json['header'] as String?,
      loginUrl: json['loginUrl'] as String?,
      loginUi: json['loginUi'] as String?,
      loginCheckJs: json['loginCheckJs'] as String?,
      coverDecodeJs: json['coverDecodeJs'] as String?,
      bookSourceComment: json['bookSourceComment'] as String?,
      variableComment: json['variableComment'] as String?,
      lastUpdateTime: _int(json, 'lastUpdateTime', 0),
      respondTime: _int(json, 'respondTime', 180000),
      weight: _int(json, 'weight', 0),
      exploreUrl: json['exploreUrl'] as String?,
      exploreScreen: json['exploreScreen'] as String?,
      ruleExplore: json['ruleExplore'] as Map<String, dynamic>?,
      searchUrl: json['searchUrl'] as String?,
      ruleSearch: _rule(json, 'ruleSearch', SearchRule.fromJson),
      ruleBookInfo: _rule(json, 'ruleBookInfo', BookInfoRule.fromJson),
      ruleToc: _rule(json, 'ruleToc', TocRule.fromJson),
      ruleContent: _rule(json, 'ruleContent', ContentRule.fromJson),
      ruleReview: json['ruleReview'] as Map<String, dynamic>?,
      mainJs: json['mainJs'] as String?,
      eventListener: json['eventListener'] as bool? ?? false,
      customButton: json['customButton'] as bool? ?? false,
    );
  }

  static String _str(Map<String, dynamic> m, String k) =>
      m[k]?.toString() ?? '';

  static int _int(Map<String, dynamic> m, String k, int def) {
    final v = m[k];
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? def;
    return def;
  }

  static T? _rule<T>(Map<String, dynamic> m, String key, T Function(Map<String, dynamic>) from) {
    final raw = m[key];
    if (raw == null) return null;
    if (raw is Map<String, dynamic>) return from(raw);
    if (raw is Map) return from(Map<String, dynamic>.from(raw));
    if (raw is String) {
      try {
        final dec = jsonDecode(raw);
        if (dec is Map) return from(Map<String, dynamic>.from(dec));
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// 解析请求头（多行 `key: value`）为 map。
  Map<String, String> parseHeader() {
    final h = header;
    if (h == null || h.trim().isEmpty) return const {};
    // 官方 header 常以 JSON 对象存储，如 {"User-Agent":"..."}，先尝试 JSON 解析。
    final t0 = h.trim();
    if (t0.startsWith('{') || t0.startsWith('[')) {
      try {
        final decoded = jsonDecode(t0);
        if (decoded is Map) {
          return decoded
              .map((k, v) => MapEntry(k.toString(), v.toString()));
        } else if (decoded is List) {
          // 某些书源用数组形式给出多组 `键:值` 段，合并解析。
          final out = <String, String>{};
          for (final e in decoded) {
            final s = e.toString().trim();
            final i = s.indexOf(':');
            if (i <= 0) continue;
            out[s.substring(0, i).replaceAll('"', '').trim()] =
                s.substring(i + 1).replaceAll('"', '').trim();
          }
          return out;
        }
      } catch (_) {}
    }
    final out = <String, String>{};
    for (final line in h.split('\n')) {
      final t = line.trim();
      if (t.isEmpty) continue;
      final i = t.indexOf(':');
      if (i <= 0) continue;
      out[t.substring(0, i).replaceAll('"', '').trim()] =
          t.substring(i + 1).trim();
    }
    return out;
  }

  @override
  bool operator ==(Object other) =>
      other is BookSource && other.bookSourceUrl == bookSourceUrl;

  @override
  int get hashCode => bookSourceUrl.hashCode;

  /// 书源主页的 host（无协议端口），用于防盗链 Referer 比对。
  String get host {
    try {
      final u = Uri.parse(bookSourceUrl);
      if (u.host.isNotEmpty) return u.host.toLowerCase();
    } catch (_) {}
    return bookSourceUrl.trim().toLowerCase();
  }

  /// 书源主页 origin（scheme://host[:port]），作为防盗链 Referer 来源。
  String get origin {
    try {
      final u = Uri.parse(bookSourceUrl);
      return u.replace(path: '', query: null, fragment: null).toString();
    } catch (_) {
      return bookSourceUrl;
    }
  }

  @override
  String toString() => bookSourceName;
}

/// 搜索结果规则（官方 `SearchRule`，含 `BookListRule` 公共字段）。
class SearchRule {
  SearchRule({
    this.checkKeyWord,
    this.bookList,
    this.name,
    this.author,
    this.intro,
    this.kind,
    this.lastChapter,
    this.updateTime,
    this.bookUrl,
    this.coverUrl,
    this.wordCount,
  });

  final String? checkKeyWord;
  final String? bookList;
  final String? name;
  final String? author;
  final String? intro;
  final String? kind;
  final String? lastChapter;
  final String? updateTime;
  final String? bookUrl;
  final String? coverUrl;
  final String? wordCount;

  factory SearchRule.fromJson(Map<String, dynamic> j) => SearchRule(
        checkKeyWord: j['checkKeyWord'] as String?,
        bookList: j['bookList'] as String?,
        name: j['name'] as String?,
        author: j['author'] as String?,
        intro: j['intro'] as String?,
        kind: j['kind'] as String?,
        lastChapter: j['lastChapter'] as String?,
        updateTime: j['updateTime'] as String?,
        bookUrl: j['bookUrl'] as String?,
        coverUrl: j['coverUrl'] as String?,
        wordCount: j['wordCount'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'checkKeyWord': checkKeyWord,
        'bookList': bookList,
        'name': name,
        'author': author,
        'intro': intro,
        'kind': kind,
        'lastChapter': lastChapter,
        'updateTime': updateTime,
        'bookUrl': bookUrl,
        'coverUrl': coverUrl,
        'wordCount': wordCount,
      };
}

/// 书籍信息页规则（官方 `BookInfoRule`）。
class BookInfoRule {
  BookInfoRule({
    this.init,
    this.name,
    this.author,
    this.intro,
    this.kind,
    this.lastChapter,
    this.updateTime,
    this.coverUrl,
    this.tocUrl,
    this.wordCount,
    this.canReName,
    this.downloadUrls,
  });

  final String? init;
  final String? name;
  final String? author;
  final String? intro;
  final String? kind;
  final String? lastChapter;
  final String? updateTime;
  final String? coverUrl;
  final String? tocUrl;
  final String? wordCount;
  final String? canReName;
  final String? downloadUrls;

  factory BookInfoRule.fromJson(Map<String, dynamic> j) => BookInfoRule(
        init: j['init'] as String?,
        name: j['name'] as String?,
        author: j['author'] as String?,
        intro: j['intro'] as String?,
        kind: j['kind'] as String?,
        lastChapter: j['lastChapter'] as String?,
        updateTime: j['updateTime'] as String?,
        coverUrl: j['coverUrl'] as String?,
        tocUrl: j['tocUrl'] as String?,
        wordCount: j['wordCount'] as String?,
        canReName: j['canReName'] as String?,
        downloadUrls: j['downloadUrls'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'init': init,
        'name': name,
        'author': author,
        'intro': intro,
        'kind': kind,
        'lastChapter': lastChapter,
        'updateTime': updateTime,
        'coverUrl': coverUrl,
        'tocUrl': tocUrl,
        'wordCount': wordCount,
        'canReName': canReName,
        'downloadUrls': downloadUrls,
      };
}

/// 目录页规则（官方 `TocRule`）。
class TocRule {
  TocRule({
    this.preUpdateJs,
    this.chapterList,
    this.chapterName,
    this.chapterUrl,
    this.formatJs,
    this.isVolume,
    this.isVip,
    this.isPay,
    this.updateTime,
    this.nextTocUrl,
  });

  final String? preUpdateJs;
  final String? chapterList;
  final String? chapterName;
  final String? chapterUrl;
  final String? formatJs;
  final String? isVolume;
  final String? isVip;
  final String? isPay;
  final String? updateTime;
  final String? nextTocUrl;

  factory TocRule.fromJson(Map<String, dynamic> j) => TocRule(
        preUpdateJs: j['preUpdateJs'] as String?,
        chapterList: j['chapterList'] as String?,
        chapterName: j['chapterName'] as String?,
        chapterUrl: j['chapterUrl'] as String?,
        formatJs: j['formatJs'] as String?,
        isVolume: j['isVolume'] as String?,
        isVip: j['isVip'] as String?,
        isPay: j['isPay'] as String?,
        updateTime: j['updateTime'] as String?,
        nextTocUrl: j['nextTocUrl'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'preUpdateJs': preUpdateJs,
        'chapterList': chapterList,
        'chapterName': chapterName,
        'chapterUrl': chapterUrl,
        'formatJs': formatJs,
        'isVolume': isVolume,
        'isVip': isVip,
        'isPay': isPay,
        'updateTime': updateTime,
        'nextTocUrl': nextTocUrl,
      };
}

/// 正文规则（官方 `ContentRule`）。
class ContentRule {
  ContentRule({
    this.content,
    this.subContent,
    this.title,
    this.nextContentUrl,
    this.webJs,
    this.sourceRegex,
    this.replaceRegex,
    this.imageStyle,
    this.imageDecode,
    this.payAction,
    this.callBackJs,
  });

  final String? content;
  final String? subContent;
  final String? title;
  final String? nextContentUrl;
  final String? webJs;
  final String? sourceRegex;
  final String? replaceRegex;
  final String? imageStyle;
  final String? imageDecode;
  final String? payAction;
  final String? callBackJs;

  factory ContentRule.fromJson(Map<String, dynamic> j) => ContentRule(
        content: j['content'] as String?,
        subContent: j['subContent'] as String?,
        title: j['title'] as String?,
        nextContentUrl: j['nextContentUrl'] as String?,
        webJs: j['webJs'] as String?,
        sourceRegex: j['sourceRegex'] as String?,
        replaceRegex: j['replaceRegex'] as String?,
        imageStyle: j['imageStyle'] as String?,
        imageDecode: j['imageDecode'] as String?,
        payAction: j['payAction'] as String?,
        callBackJs: j['callBackJs'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'content': content,
        'subContent': subContent,
        'title': title,
        'nextContentUrl': nextContentUrl,
        'webJs': webJs,
        'sourceRegex': sourceRegex,
        'replaceRegex': replaceRegex,
        'imageStyle': imageStyle,
        'imageDecode': imageDecode,
        'payAction': payAction,
        'callBackJs': callBackJs,
      };
}