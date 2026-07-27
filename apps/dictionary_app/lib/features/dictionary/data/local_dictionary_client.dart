import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../domain/dictionary_entry.dart';

class DictionaryGenerationFailure implements Exception {
  const DictionaryGenerationFailure({
    required this.message,
    this.code = 'generation_failed',
    this.issues = const [],
    this.retryable = true,
  });

  final String code;
  final String message;
  final List<String> issues;
  final bool retryable;

  @override
  String toString() => message;
}

class LocalDictionaryRevision {
  const LocalDictionaryRevision({
    required this.revision,
    required this.origin,
    required this.createdAt,
    required this.model,
    required this.sourceCount,
  });

  factory LocalDictionaryRevision.fromJson(Map<String, Object?> json) =>
      LocalDictionaryRevision(
        revision: json['revision']! as int,
        origin: json['origin']! as String,
        createdAt: DateTime.tryParse(json['created_at']! as String),
        model: json['model'] as String? ?? '',
        sourceCount: json['source_count'] as int? ?? 0,
      );

  final int revision;
  final String origin;
  final DateTime? createdAt;
  final String model;
  final int sourceCount;
}

abstract interface class LocalDictionaryGateway {
  Future<List<DictionaryEntry>> search(String query);

  Future<List<DictionaryEntry>> allEntries();

  Future<DictionaryEntry?> findById(String entryId);

  Future<DictionaryEntry> generateMissing(String query);

  Future<List<LocalDictionaryRevision>> listRevisions(String entryId);

  Future<DictionaryEntry> getRevision(String entryId, int revision);

  Future<DictionaryEntry> editEntry(String entryId, Map<String, Object?> patch);

  Future<DictionaryEntry> restoreRevision(String entryId, int revision);

  Future<DictionaryEntry> regenerate(String entryId);

  Future<DictionaryEntry> setLocked(String entryId, bool locked);

  Future<void> deleteEntry(String entryId);
}

class LocalDictionaryClient implements LocalDictionaryGateway {
  LocalDictionaryClient({
    Uri? baseUri,
    String? apiToken,
    http.Client? client,
    this.pollInterval = const Duration(milliseconds: 350),
    this.generationTimeout = const Duration(seconds: 90),
  }) : baseUri =
           baseUri ??
           Uri.parse(
             const String.fromEnvironment(
               'KOTOBA_LOCAL_API',
               defaultValue: 'http://127.0.0.1:8766',
             ),
           ),
       apiToken =
           apiToken ?? const String.fromEnvironment('KOTOBA_LOCAL_API_TOKEN'),
       _client = client ?? http.Client();

  final Uri baseUri;
  final String apiToken;
  final http.Client _client;
  final Duration pollInterval;
  final Duration generationTimeout;

  void close() => _client.close();

  @override
  Future<List<DictionaryEntry>> search(String query) async {
    final uri = _uri('/api/search').replace(queryParameters: {'q': query});
    final payload = await _send(() => _client.get(uri, headers: _headers()));
    return (payload['entries'] as List<Object?>? ?? const [])
        .map(
          (value) => DictionaryEntry.fromJson(value! as Map<String, Object?>),
        )
        .toList(growable: false);
  }

  @override
  Future<List<DictionaryEntry>> allEntries() async {
    final payload = await _send(
      () => _client.get(_uri('/api/entries'), headers: _headers()),
    );
    return (payload['entries'] as List<Object?>? ?? const [])
        .map(
          (value) => DictionaryEntry.fromJson(value! as Map<String, Object?>),
        )
        .toList(growable: false);
  }

  @override
  Future<DictionaryEntry?> findById(String entryId) async {
    final response = await _client.get(
      _uri('/api/entries/${Uri.encodeComponent(entryId)}'),
      headers: _headers(),
    );
    if (response.statusCode == 404) return null;
    final payload = _decodeResponse(response);
    return DictionaryEntry.fromJson(payload['entry']! as Map<String, Object?>);
  }

  @override
  Future<DictionaryEntry> generateMissing(String query) async {
    final payload = await _send(
      () => _client.post(
        _uri('/api/generation-jobs'),
        headers: _headers(json: true),
        body: jsonEncode({'query': query}),
      ),
    );
    return _waitForJob(payload['job']! as Map<String, Object?>);
  }

  @override
  Future<List<LocalDictionaryRevision>> listRevisions(String entryId) async {
    final payload = await _send(
      () => _client.get(
        _uri('/api/entries/${Uri.encodeComponent(entryId)}/revisions'),
        headers: _headers(),
      ),
    );
    return (payload['revisions'] as List<Object?>? ?? const [])
        .map(
          (value) =>
              LocalDictionaryRevision.fromJson(value! as Map<String, Object?>),
        )
        .toList(growable: false);
  }

  @override
  Future<DictionaryEntry> getRevision(String entryId, int revision) async {
    final payload = await _send(
      () => _client.get(
        _uri(
          '/api/entries/${Uri.encodeComponent(entryId)}/revisions/$revision',
        ),
        headers: _headers(),
      ),
    );
    return DictionaryEntry.fromJson(payload['entry']! as Map<String, Object?>);
  }

  @override
  Future<DictionaryEntry> editEntry(
    String entryId,
    Map<String, Object?> patch,
  ) => _entryMutation('PUT', '/api/entries/${Uri.encodeComponent(entryId)}', {
    'patch': patch,
  });

  @override
  Future<DictionaryEntry> restoreRevision(String entryId, int revision) =>
      _entryMutation(
        'POST',
        '/api/entries/${Uri.encodeComponent(entryId)}/restore',
        {'revision': revision},
      );

  @override
  Future<DictionaryEntry> regenerate(String entryId) async {
    final payload = await _send(
      () => _client.post(
        _uri('/api/entries/${Uri.encodeComponent(entryId)}/regenerate'),
        headers: _headers(json: true),
        body: '{}',
      ),
    );
    return _waitForJob(payload['job']! as Map<String, Object?>);
  }

  @override
  Future<DictionaryEntry> setLocked(String entryId, bool locked) =>
      _entryMutation(
        'POST',
        '/api/entries/${Uri.encodeComponent(entryId)}/lock',
        {'locked': locked},
      );

  @override
  Future<void> deleteEntry(String entryId) async {
    final response = await _client.delete(
      _uri('/api/entries/${Uri.encodeComponent(entryId)}'),
      headers: _headers(),
    );
    if (response.statusCode == 204) return;
    _decodeResponse(response);
  }

  Future<DictionaryEntry> _entryMutation(
    String method,
    String path,
    Map<String, Object?> body,
  ) async {
    final request = http.Request(method, _uri(path))
      ..headers.addAll(_headers(json: true))
      ..body = jsonEncode(body);
    final streamed = await _client.send(request);
    final response = await http.Response.fromStream(streamed);
    final payload = _decodeResponse(response);
    return DictionaryEntry.fromJson(payload['entry']! as Map<String, Object?>);
  }

  Future<DictionaryEntry> _waitForJob(Map<String, Object?> initialJob) async {
    var job = initialJob;
    final deadline = DateTime.now().add(generationTimeout);
    while (true) {
      final status = job['status'] as String?;
      if (status == 'ready') {
        final rawEntry = job['entry'];
        if (rawEntry is Map<String, Object?>) {
          return DictionaryEntry.fromJson(rawEntry);
        }
        final entryId = job['entry_id'] as String?;
        if (entryId != null) {
          final entry = await findById(entryId);
          if (entry != null) return entry;
        }
        throw const DictionaryGenerationFailure(
          code: 'missing_entry',
          message: '生成工作已完成，但找不到詞條資料。',
        );
      }
      if (status == 'failed') {
        throw _generationFailure(job['error']);
      }
      if (DateTime.now().isAfter(deadline)) {
        throw const DictionaryGenerationFailure(
          code: 'timeout',
          message: '詞條生成逾時，請確認本機模型服務後再試一次。',
        );
      }
      final jobId = job['job_id']! as String;
      await Future<void>.delayed(pollInterval);
      final payload = await _send(
        () => _client.get(
          _uri('/api/generation-jobs/${Uri.encodeComponent(jobId)}'),
          headers: _headers(),
        ),
      );
      job = payload['job']! as Map<String, Object?>;
    }
  }

  DictionaryGenerationFailure _generationFailure(Object? raw) {
    if (raw is! Map<String, Object?>) {
      return const DictionaryGenerationFailure(message: '詞條生成或驗證失敗。');
    }
    final rawIssues = raw['issues'] as List<Object?>? ?? const [];
    return DictionaryGenerationFailure(
      code: raw['code'] as String? ?? 'generation_failed',
      message: raw['message'] as String? ?? '詞條生成或驗證失敗。',
      issues: rawIssues
          .map((value) {
            if (value is String) return value;
            if (value is Map<String, Object?>) {
              final path = value['path'] as String? ?? '';
              final message = value['message'] as String? ?? value.toString();
              return path.isEmpty ? message : '$path：$message';
            }
            return value.toString();
          })
          .toList(growable: false),
      retryable: raw['retryable'] as bool? ?? true,
    );
  }

  Future<Map<String, Object?>> _send(
    Future<http.Response> Function() operation,
  ) async {
    try {
      return _decodeResponse(await operation());
    } on DictionaryGenerationFailure {
      rethrow;
    } on TimeoutException {
      throw const DictionaryGenerationFailure(
        code: 'service_timeout',
        message: '本機詞條服務沒有回應。',
      );
    } on http.ClientException catch (error) {
      throw DictionaryGenerationFailure(
        code: 'service_unavailable',
        message: '無法連線到本機詞條服務：${error.message}',
      );
    }
  }

  Map<String, Object?> _decodeResponse(http.Response response) {
    Map<String, Object?> payload = const {};
    if (response.bodyBytes.isNotEmpty) {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, Object?>) payload = decoded;
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return payload;
    }
    final rawError = payload['error'];
    if (rawError is Map<String, Object?>) {
      throw _generationFailure(rawError);
    }
    throw DictionaryGenerationFailure(
      code: 'http_${response.statusCode}',
      message: '本機詞條服務回傳錯誤（${response.statusCode}）。',
    );
  }

  Uri _uri(String path) {
    final normalizedBase = baseUri.toString().endsWith('/')
        ? baseUri
        : Uri.parse('${baseUri.toString()}/');
    return normalizedBase.resolve(path.replaceFirst(RegExp(r'^/'), ''));
  }

  Map<String, String> _headers({bool json = false}) => {
    if (json) 'Content-Type': 'application/json',
    if (apiToken.isNotEmpty) 'Authorization': 'Bearer $apiToken',
  };
}
