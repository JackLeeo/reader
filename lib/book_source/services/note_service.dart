import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 一条阅读笔记（对齐官方“笔记”语义：绑定「书籍 + 章节」的一段文本）。
class ReadingNote {
  ReadingNote({
    required this.bookKey,
    required this.bookName,
    required this.chapterIndex,
    required this.chapterTitle,
    required this.text,
    required this.time,
  });

  /// 书籍唯一键：`源|bookUrl`，本地书为 `local|key`。
  final String bookKey;

  /// 书名（展示用）。
  final String bookName;

  /// 章节下标。
  final int chapterIndex;

  /// 章节标题。
  final String chapterTitle;

  /// 笔记正文。
  String text;

  /// 创建/更新时间（毫秒时间戳）。
  int time;

  factory ReadingNote.fromJson(Map<String, dynamic> m) => ReadingNote(
        bookKey: (m['bookKey'] as String?) ?? '',
        bookName: (m['bookName'] as String?) ?? '',
        chapterIndex: ((m['chapterIndex'] as num?) ?? 0).toInt(),
        chapterTitle: (m['chapterTitle'] as String?) ?? '',
        text: (m['text'] as String?) ?? '',
        time: ((m['time'] as num?) ?? 0).toInt(),
      );

  Map<String, dynamic> toJson() => {
        'bookKey': bookKey,
        'bookName': bookName,
        'chapterIndex': chapterIndex,
        'chapterTitle': chapterTitle,
        'text': text,
        'time': time,
      };
}

/// 阅读笔记服务：按「书籍 + 章节」保存笔记，归属书籍分组展示。
///
/// 持久化于 SharedPreferences（`reading_notes_v1`），纯内存 + 异步落盘，
/// 不抛异常。同一章节只会保存一条笔记（新增=覆盖，保持与官方「本章笔记」一致）。
class NoteService {
  NoteService._();

  static final NoteService instance = NoteService._();

  static const String _prefsKey = 'reading_notes_v1';

  final List<ReadingNote> _notes = [];
  bool initialized = false;

  List<ReadingNote> get notes => List.unmodifiable(_notes);

  Future<void> init() async {
    if (initialized) return;
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_prefsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        _notes
          ..clear()
          ..addAll((jsonDecode(raw) as List)
              .map((e) => ReadingNote.fromJson(e as Map<String, dynamic>)));
      } catch (_) {
        _notes.clear();
      }
    }
    initialized = true;
  }

  /// 写入/覆盖某章的笔记。
  Future<void> saveNote(ReadingNote note) async {
    final idx =
        _notes.indexWhere((n) => n.bookKey == note.bookKey && n.chapterIndex == note.chapterIndex);
    if (idx >= 0) {
      _notes[idx] = note;
    } else {
      _notes.add(note);
    }
    await _save();
  }

  /// 删除某章笔记。
  Future<void> removeNote(String bookKey, int chapterIndex) async {
    _notes.removeWhere(
        (n) => n.bookKey == bookKey && n.chapterIndex == chapterIndex);
    await _save();
  }

  /// 删除某本书的全部笔记。
  Future<void> removeBook(String bookKey) async {
    _notes.removeWhere((n) => n.bookKey == bookKey);
    await _save();
  }

  /// 取某章笔记（无则 null）。
  ReadingNote? forChapter(String bookKey, int chapterIndex) {
    for (final n in _notes) {
      if (n.bookKey == bookKey && n.chapterIndex == chapterIndex) return n;
    }
    return null;
  }

  /// 取某本书的笔记（按章节排序）。
  List<ReadingNote> forBook(String bookKey) {
    final out = _notes.where((n) => n.bookKey == bookKey).toList()
      ..sort((a, b) => a.chapterIndex.compareTo(b.chapterIndex));
    return out;
  }

  /// 全部笔记，按书分组返回 `(书名, 笔记列表)`。
  List<(String, List<ReadingNote>)> grouped() {
    final map = <String, List<ReadingNote>>{};
    for (final n in _notes) {
      map.putIfAbsent(n.bookName, () => []).add(n);
    }
    final out = map.entries
        .map((e) => (e.key, e.value))
        .toList()
      ..sort((a, b) => b.$2.first.time.compareTo(a.$2.first.time));
    return out;
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
        _prefsKey, jsonEncode(_notes.map((n) => n.toJson()).toList()));
  }
}