# yuedu_hd vs open-reading-main 书源引擎与阅读链路对比报告

> 目的：定位"发现页能显示、点击书籍详情阅读仍然失败"的根因，并给出两个项目的功能/业务逻辑全量差异。
> 基准：yuedu_hd @ D:\gz\yuedu_hd（三目阅读）｜open-reading-main @ D:\gz\open-reading-main（本仓库）
> 日期：2026-08-15

---

## 1. 项目定位与总体架构

| 维度 | yuedu_hd（三目阅读） | open-reading-main（本项目） |
|---|---|---|
| 书源协议 | Legado 2.0/3.0 子集（**仅纯文字源**） | Legado 3.0 全量（文字/音频/漫画/文件） |
| 规则引擎 | **native Go 库**（evparser.dll / libevparser.so / libevparser.a，dart:ffi 调用） | **纯 Dart**（html 包 + 自研 XPath/JSONPath/正则）+ flutter_js(QuickJS) |
| JS 引擎 | 无（导入期直接拒绝 JS 源） | flutter_js 0.8.7（QuickJS FFI，含 java.* 桥） |
| 数据存储 | SQLite（书/章节/正文缓存） | SharedPreferences + 文件缓存 |
| UI 阅读 | 自研 PageBreaker 二分分页 + DisplayPage | native_reader_page（BookFormat.html/epub 等多格式） |
| 设计哲学 | **做减法**：拒绝一切复杂源，保剩余源 100% 可读 | **做加法**：尽量支持全量协议，复杂源运行时才暴露问题 |

架构图对比：

```
yuedu_hd:
  书源JSON → _checkCompatible 过滤(JS/@get:/ajax/type!=0 全拒)
           → BookSourceBean(2.0→3.0字段映射)
           → reader_parser2 (FFI→Go native 规则求值)
           → Dio(GBK解码,ResponseType.plain)
           → SQLite 缓存 → PageBreaker 分页渲染

open-reading-main:
  书源JSON → LegadoCompatibilityScanner(拦截 video/login/dns/proxy/rhino)
           → LegadoBookSource
           → LegadoRuntime: search→getBook→getChapters→getChapterContent
             ├─ LegadoRequestTemplate(URL模板: {{}}/@get:/@js:/charset/body)
             ├─ LegadoRuleEngine(CSS/XPath/JSONPath/正则/JS/put段)
             ├─ LegadoJsEngine(QuickJS: java.ajax两阶段预取/变量池/Cookie)
             ├─ LegadoVariableStore(@get:/@put: 按源隔离变量池)
             └─ LegadoCookieJar(按域+父域合并, SharedPreferences持久化)
           → book_source_reader_page → native_reader 渲染
```

---

## 2. 书源兼容策略（**最核心的哲学差异**）

### yuedu_hd：导入期一刀切（book_source_helper.dart:81-104）

```dart
if(itemStr.contains('@get:')) return false;    // 拒绝源变量
if(itemStr.contains('@js'))  return false;     // 拒绝 @js: 规则
if(itemStr.contains('<js>')) return false;     // 拒绝 <js> 块
if(itemStr.contains('java.ajax')) return false;// 拒绝 ajax
if(item['bookSourceType'] != "0") return false;// 仅文字源
```

**结果**：能导入的源数量少，但**每一个都能走完全链路**——因为引擎能力完全覆盖所接受源的语法范围。用户感知是"稳定"。

### open-reading-main：运行期逐项拦截（legado_book_source.dart:200-267）

blocked 条件仅 7 类：video(type=4)、missingSearch、missingReadingRules、login、customDns、customProxy、rhinoScript。

**结果**：可用源 286/296，但其中大量源依赖 JS 引擎/变量池/特殊 URL 语义。任何一环在真机上缺失（尤其 iOS 的 QuickJS），对应源就在**阅读阶段**才失败。用户感知是"列表里有、点进去读不了"。

> **这正是"发现页正常、阅读失败"的结构性原因**：发现页（exploreUrl）对引擎能力要求最低，而详情/目录/正文对规则引擎和 JS 的要求逐级升高。

---

## 3. 阅读全链路逐步对比

### 3.1 搜索

| 环节 | yuedu_hd | open-reading-main | 差异评价 |
|---|---|---|---|
| URL 拆分 | 按第一个 `,` 分割 url 与 options（BookSourceBean.dart:126-188） | 找**最后一个** `,{` 尝试 JSON 解析（legado_request.dart:59-72） | 本项目更严谨（options 内可含逗号） |
| 单引号 options | `{'method':'POST'}` 先替换 `"`→`^` 再 `'`→`"`（149-155） | `_decodeOptions` 支持单引号 | 双方都支持 |
| 变量插值 | `{{key}}`/`{{page}}`，用 expressions 包（HEvalParser） | `{{}}` 静态替换 + JS 表达式求值 | 本项目覆盖更广（但依赖 JS 引擎） |
| GBK 请求编码 | 自实现 UrlGBKEncode（2万字表）编码 url+body | gbk_codec 编码 | 等价 |
| GBK 响应解码 | content-type 含 "gb" 用 gbk，否则 utf8 失败回退 gbk | charset 显式声明优先 | yuedu_hd 的"utf8 失败回退 gbk"更鲁棒 |
| 并发 | CountLock(8) | BookSourceConcurrencyLimiter(16) + 单源 20s 预算 | 本项目更强 |
| **POST 302 处理** | **捕获 302 → location 改 GET 重发**（book_search_helper.dart:126-138） | ❌ 无（重定向>5 次直接报错） | **缺失**：表单提交型站点搜索会失败 |
| bookUrl 为空 | **回退 tocUrl**（book_search_helper.dart:259-261） | ❌ 无（bookUrl 空则书籍不可点） | **缺失** |

### 3.2 详情页

| 环节 | yuedu_hd | open-reading-main | 差异评价 |
|---|---|---|---|
| 请求次数 | **1 次**（updateChapterList 内请求详情页后顺势解析 tocUrl，book_toc_helper.dart:82-100） | **2 次**：getBook 请求一次（legado_runtime.dart:187），getChapters 的 `_tocUrl` 再请求一次（legado_runtime.dart:462） | ⚠️ **本项目详情页重复请求**。对带一次性 token / 防重放的站点，第二次请求会 404 或内容变化，直接导致"详情能看到、目录拉不到" |
| tocUrl 规则失败 | **`{{baseUrl}}` 表达式兜底**（_parseTocUrl:253-261，规则解析失败时把 tocUrl 当模板用 baseUrl 展开） | 求值为空或 `-` 回退 bookId（legado_runtime.dart:477），非 http 回退 bookId | 本项目回退策略 OK，但缺表达式兜底 |
| init 规则 | 无此概念 | ruleBookInfo.init 支持上下文重定位 | 本项目更全（协议正确） |
| 书名必填 | 无强校验 | name 为空抛异常 | 本项目更严 |

### 3.3 目录

| 环节 | yuedu_hd | open-reading-main | 差异评价 |
|---|---|---|---|
| 分页策略 | BFS 队列 + 全局去重（book_toc_helper.dart:101-162） | for 循环 + seenPages 去重，上限 20 跳 | 等价 |
| **nextTocUrl 多值** | **`split(',')` 支持一次跳多页**（第 137 行） | ❌ 单值（`_url` 取一个） | **缺失**：并发分页目录源会丢章节 |
| 404 处理 | **视为分页自然结束**（第 155-157 行） | 404 抛异常终止整个 getChapters | ⚠️ **本项目更脆**：目录最后一页越界 404 会把已抓到的章节全部丢掉 |
| 分页重叠去重 | 检测第一章重复出现 → sublist 裁剪（第 225-237 行） | seenChapters 按 URL 去重 | URL 去重通常足够，但 URL 带随机参数的站点会失效 |
| 章节数上限 | 无 | 30000 | 本项目有保护 |

### 3.4 正文

| 环节 | yuedu_hd | open-reading-main | 差异评价 |
|---|---|---|---|
| 正文提取 | parseRuleString(content)，多结果 `\n` 连接 | evaluateString + replaceRegex | 等价 |
| 替换净化 | `##regex##replace##flag` 三档（删除/全替换/仅首个）+ `$1` 分组引用（h_parser.dart:75-103） | applyReplaceRule 支持同语义（legado_rule_engine.dart:151-168） | 等价 |
| 正文分页 | while 循环，**上限 10 页** + **"下一页==下一章 URL 则停"** 边界（book_content_helper.dart:70-102） | for 循环上限 20 跳 + seenPages 去重 | ⚠️ 本项目缺"下一页即下一章"判断，可能把下一章内容并进本章 |
| 缓存 | SQLite 按 chapterId 缓存 | 调用方（reader page）负责 | — |

### 3.5 渲染排版

| 环节 | yuedu_hd | open-reading-main |
|---|---|---|
| 排版 | `_formatContent`：连续换行合并、长空格压缩、段首缩进、段间空行（ReadingWidget.dart:456-471） | native_reader 按 BookFormat.html 解析 `<br>`/实体 |
| 正文格式 | 纯文本（引擎保证 `@text`） | contentType 恒为 `text/html`（legado_runtime.dart:413）——规则若取 `@html` 则带标签交给 UI，`@text` 则纯文本 |

---

## 4. 规则引擎能力矩阵

| 能力 | yuedu_hd | open-reading-main | 备注 |
|---|---|---|---|
| Jsoup 风格选择器 class./tag./id./text. | ✅（native 库） | ✅（_legacySelector:480-512） | |
| 显式 CSS `@css:` | ✅ | ✅（含属性选择器 `[property=...]`） | |
| XPath `//` / `@XPath:` | ✅ | ✅（legado_xpath.dart） | |
| JSONPath `$.` / `@json:` | ✅ | ✅（legado_jsonpath.dart，含递归下降/切片/过滤） | |
| 正则 `:` 前缀列表规则 | ✅ | ✅ | |
| 正则替换 `##` | ✅ | ✅ | |
| `||` 或 | ✅ | ✅（备选） | |
| `&&` 与 | ✅ | ✅（串联） | |
| **`%%` 合并** | ✅（OPERATOR_MERGE） | ❌ **未实现** | 影响：用 `%%` 的源字段解析为空 |
| 索引 `.0` / `.-1` / `.0:5` / 排除 `!0` | ✅ | ✅ | |
| `@text/@ownText/@textNodes/@html/@all` | ✅ | ✅ | |
| `@href` 等属性终结 | ✅ | ✅（含任意属性名兜底） | |
| 规则内 `@js:`/`<js>` | ❌（拒绝源） | ✅（依赖 QuickJS） | |
| `{{expression}}` | 仅 expressions 包算术 | ✅ JS 求值（依赖 QuickJS） | |
| `@get:/@put:` 源变量 | ❌（拒绝源） | ✅（变量池，按 bookSourceUrl 隔离） | |
| 方向前缀 `+`/`-`（css/json/xpath） | ✅ | 部分（`+` 剥离；`-` 未实现） | 小缺口 |
| 2.0→3.0 书源字段映射 | ✅ | ❌ | 仅影响老 2.0 源 |

---

## 5. 网络层对比

| 维度 | yuedu_hd | open-reading-main |
|---|---|---|
| HTTP | Dio + ResponseType.plain + 忽略证书错误 | Dio + 自研重定向（≤5 次）+ 8MB 上限 |
| 超时 | connect 15s / receive 5s | 由 BookSourceNetworkPolicy 统一（含 DoH 竞速、IPv4 优先） |
| Cookie | ❌ 无持久化 | ✅ 按域+父域合并 CookieJar（SharedPreferences 持久化，JS 桥共享） |
| UA/headers | 固定默认头 | 书源自定义头 + JS 字面量头（依赖 JS 引擎） |
| 重试 | 无自动重试 | 无自动重试（POST 302 特例也无） |
| WebView 源 | 拒绝 | 拒绝（webViewGet 抛错） |

---

## 6. 跨请求状态机制

| 机制 | yuedu_hd | open-reading-main |
|---|---|---|
| 源变量 @get:/@put: | 拒绝含 @get: 的源 | ✅ 变量池（128 变量/源，512 源 LRU） |
| 变量写入时机 | — | (1) 规则 put:{name:rule} 段 (2) JS java.put |
| 变量读取时机 | — | (1) URL 模板 @get:{name} (2) 整条规则即 @get: (3) JS java.get |
| ⚠️ 发现页路径变量缺口 | 不存在（无此机制） | **存在**：若变量只在 ruleSearch 的规则里 put，从发现页/书架直进的链路永远不会写入 → tocUrl/chapterUrl 的 `@get:{x}` 报 "unknown source variable" |
| Cookie 跨请求 | 无 | ✅ |

---

## 7. 错误处理与健壮性细节（yuedu_hd 有、本项目无）

| # | yuedu_hd 行为 | 位置 | 本项目现状 | 影响 |
|---|---|---|---|---|
| 1 | POST 302 → location 改 GET 重发 | book_search_helper.dart:126-138 | 无 | 表单型搜索站点失败 |
| 2 | 搜索 bookUrl 空 → 回退 tocUrl | book_search_helper.dart:259-261 | 无 | 部分源搜到书但点不开 |
| 3 | tocUrl 规则解析失败 → `{{baseUrl}}` 模板兜底 | book_toc_helper.dart:253-261 | 无（仅空/`-` 回退 bookId） | 个别源目录页 URL 取不到 |
| 4 | 目录分页 404 = 自然结束（保留已抓章节） | book_toc_helper.dart:155-157 | 404 抛异常 → **全部章节丢弃** | ⚠️ 高危：分页越界源必失败 |
| 5 | nextTocUrl 逗号多值 | book_toc_helper.dart:137 | 单值 | 多路分页目录丢章节 |
| 6 | 正文"下一页==下一章"截断 | book_content_helper.dart:94-97 | 无 | 正文并入下一章内容 |
| 7 | GBK 响应 utf8 解码失败自动回退 gbk | utils.dart:10-22 | 仅按声明 charset | charset 声明错误的源乱码 |
| 8 | 忽略证书错误 | utils.dart:111-115 | 严格 | 自签证书站点失败（可商榷） |

反向地，本项目有、yuedu_hd 无：变量池、CookieJar、JS 引擎、XPath/JSONPath 纯 Dart 实现、兼容性扫描报告、并发限制器、单源搜索预算、DoH 竞速、8MB/30000 章上限、重定向上限。

---

## 8. "仍然不能正常阅读"根因分析（按证据强度排序）

### 根因 A：详情页被请求两次，防重放站点目录 404（架构级）
- 证据：`getBook`（legado_runtime.dart:187）与 `_tocUrl`（legado_runtime.dart:462）各自 `_request(source, bookId)`，中间无缓存传递。
- 用户症状完全吻合："详情页有数据（getBook 成功）→ 点阅读报 HTTP 404（第二次请求被站点拒绝/内容变化）"。
- yuedu_hd 对照：详情页只请求一次，顺手解析 tocUrl。
- 修复方向：`getChapters` 复用 `getBook` 已抓的 document（增加可选参数传递 response/document），或给 `_tocUrl` 加内存缓存（bookId → document，TTL 数十秒）。

### 根因 B：目录分页 404 全量丢弃（高危细节）
- 证据：legado_runtime.dart 分页循环里 `_request` 抛 `BookSourceProtocolException('Legado source returned HTTP 404.')` 直接冒泡，`chapters` 列表被丢弃；yuedu_hd 将 404 视为分页结束并**保留已抓章节**。
- 症状：目录第一页正常、翻页越界 404 → 界面表现"目录加载失败"。
- 修复方向：分页请求 404/连接错误时 break 而非 throw（首轮仍需 throw）。

### 根因 C：iOS 真机 QuickJS 可用性未验证（环境级）
- 证据链：
  1. 源码注释自述 "iOS 无 flutter_js pod / 构造失败"（legado_runtime.dart:779）；
  2. 仓库内 ios/Podfile.lock 不含 flutter_js（本地过时，CI 由 flutter build 自动 pod install，**无法离线确认**）；
  3. Windows 实测 chain 报 "This source needs scripting, but the JS engine is unavailable."（笔尖中文），证明引擎不可用时错误路径真实存在；
  4. `_unavailable` 置位后**永不重试**（legado_js_engine.dart:40-49）。
- 若 iOS 上引擎构造失败：所有含 `@js:`/`<js>`/`{{expression}}` 的 URL 与规则在阅读阶段必然报 "uses scripting"/"unsupported template expression"——与用户最初报错一致。
- 修复方向：
  1. iOS 真机日志确认 `getJavascriptRuntime` 是否抛异常（app.log 已具备）；
  2. `_unavailable` 增加指数退避重试而非永久放弃；
  3. 中期：参考 yuedu_hd，把「JS 依赖度」作为导入期分级（纯规则源/轻 JS 源/重 JS 源），纯规则源优先保证。

### 根因 D：发现页路径变量池缺写入（场景级）
- 证据：变量写入仅两处（规则 put 段、JS java.put）；发现页列表用 ruleExplore 解析，不触发 ruleSearch 的 put 段。
- 症状：从发现页进入 → tocUrl/chapterUrl 报 "references an unknown source variable (@get:{...})"。
- 修复方向：getBook/getChapters 遇到未命中变量时，先执行 ruleBookInfo.init（若含 put 段）再重试一次；仍失败则把该源标记 partial 并在 UI 提示"请先搜索一次本书"。

### 根因 E：规则引擎缺口（长尾）
- `%%` 合并操作符未实现（yuedu_hd 有 OPERATOR_MERGE）；
- URL 模板 `@put:` 被 `_unsupportedRequestSyntax` 误拦（legado_request.dart:393-396 把 `@put:` 与脚本同等对待，而 `_expandTemplate` 并不展开它）；
- XPath/JSON/CSS 的 `-` 方向前缀未实现；
- 排除的旧库 file_picker 相关构建历史问题提示 iOS 构建链脆弱（项目记忆）。

### 非根因（已排除）
- 预检误杀（searchUrl preflight）——上轮已修复并有测试覆盖；
- 正文 HTML 渲染——book_source_reader_page.dart:2899 按 BookFormat.html 交给 native_reader，`&nbsp;`/`<br>` 会被解析；
- 变量池跨阶段 sourceUrl 不一致——全链路恒为 bookSourceUrl，已核实。

---

## 9. 修复路线建议（按投入产出排序）

| 优先级 | 事项 | 预期收益 |
|---|---|---|
| P0 | getChapters 复用 getBook 的详情页响应（详情页只请求一次） | 直接消灭"详情正常、目录 404"类失败 |
| P0 | 目录/正文分页 404 → break 保留已抓内容 | 消灭分页越界类目录失败 |
| P1 | iOS 真机验证 QuickJS（app.log 打点）+ `_unavailable` 重试机制 | 恢复全部 JS 依赖源，或至少给出明确诊断 |
| P1 | POST 302→GET 重发；bookUrl 空→tocUrl 回退 | 搜索链路长尾补齐 |
| P2 | `%%` 操作符；URL 模板 `@put:` 展开（展开而非拦截） | 规则覆盖率提升 |
| P2 | nextTocUrl 逗号多值；正文"下一页==下一章"截断；utf8→gbk 解码回退 | 目录/正文质量提升 |
| P3 | 导入期 JS 依赖分级（纯规则/轻 JS/重 JS），纯规则源优先置顶 | 向 yuedu_hd 的"稳定优先"哲学靠拢 |

---

## 附：关键文件索引

| 模块 | yuedu_hd | open-reading-main |
|---|---|---|
| 书源导入/过滤 | lib/db/book_source_helper.dart | lib/book_sources/legado/legado_book_source.dart |
| 数据模型 | lib/db/BookSourceBean.dart | legado_book_source.dart（内含） |
| 搜索 | lib/db/book_search_helper.dart | legado_runtime.dart:29-69 |
| 详情+目录 | lib/db/book_toc_helper.dart | legado_runtime.dart:180-342 |
| 正文 | lib/db/book_content_helper.dart | legado_runtime.dart:344-417 |
| 规则引擎 | reader_parser2（FFI→Go） | legado_rule_engine.dart + legado_xpath/jsonpath |
| 请求层 | lib/db/utils.dart（Dio） | legado_request.dart |
| JS 引擎 | —（拒绝） | legado_js_engine.dart |
| 变量池 | —（拒绝） | legado_variable_store.dart |
| Cookie | — | legado_cookie_jar.dart |
| 阅读渲染 | lib/ui/reading/* | lib/pages/reader/book_source_reader_page.dart |
