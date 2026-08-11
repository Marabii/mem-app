import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// A message in an OpenAI-style chat completion request.
class AiMessage {
  const AiMessage.system(this.content) : role = 'system';
  const AiMessage.user(this.content) : role = 'user';

  final String role;
  final String content;

  Map<String, String> toJson() => {'role': role, 'content': content};
}

/// Anything the user can act on: bad URL, model offline, refused key.
class AiException implements Exception {
  const AiException(this.message, {this.detail});
  final String message;
  final String? detail;
  @override
  String toString() => detail == null ? message : '$message\n\n$detail';
}

/// Minimal client for any OpenAI-compatible `/chat/completions` endpoint —
/// LM Studio, Ollama, llama.cpp, vLLM, or OpenAI itself.
///
/// Nothing else in the app depends on this class: if the model is unreachable
/// every other feature keeps working.
class AiClient {
  AiClient({
    required String baseUrl,
    required this.apiKey,
    required this.model,
    this.temperature = 0.4,
    this.timeout = const Duration(seconds: 180),
  }) : baseUrl = normalizeBaseUrl(baseUrl);

  final String baseUrl;
  final String apiKey;
  final String model;
  final double temperature;
  final Duration timeout;

  /// Accepts `192.168.1.10:1234`, `http://host:1234`, or `http://host:1234/v1/`
  /// and always yields a scheme-qualified URL ending in `/v1`.
  static String normalizeBaseUrl(String raw) {
    var url = raw.trim();
    if (url.isEmpty) return url;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'http://$url';
    }
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    if (!url.endsWith('/v1')) url = '$url/v1';
    return url;
  }

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (apiKey.trim().isNotEmpty) 'Authorization': 'Bearer ${apiKey.trim()}',
      };

  /// Used by the "Test connection" button.
  Future<List<String>> listModels() async {
    final res = await _send(() => http
        .get(Uri.parse('$baseUrl/models'), headers: _headers)
        .timeout(const Duration(seconds: 20)));
    final body = jsonDecode(res.body);
    if (body is Map && body['data'] is List) {
      return [
        for (final m in body['data'] as List)
          if (m is Map && m['id'] != null) m['id'].toString(),
      ];
    }
    return const [];
  }

  /// Returns the assistant's raw message content.
  Future<String> complete(
    List<AiMessage> messages, {
    int? maxTokens,
  }) async {
    if (model.trim().isEmpty) {
      throw const AiException('No model name is set in AI settings.');
    }

    final payload = <String, dynamic>{
      'model': model,
      'messages': messages.map((m) => m.toJson()).toList(),
      'temperature': temperature,
      'stream': false,
      'max_tokens': ?maxTokens,
      // No response_format here: OpenAI's `json_object` value is rejected
      // outright by some OpenAI-compatible servers (they only accept
      // `json_schema` or `text`), so this failed hard rather than being
      // harmlessly ignored. The system prompt asks for bare JSON instead, and
      // extractJsonObject() below tolerates fences or stray prose either way.
    };

    final res = await _send(() => http
        .post(
          Uri.parse('$baseUrl/chat/completions'),
          headers: _headers,
          body: jsonEncode(payload),
        )
        .timeout(timeout));

    final body = jsonDecode(utf8.decode(res.bodyBytes));
    if (body is! Map) {
      throw const AiException('The model returned an unexpected response.');
    }
    final choices = body['choices'];
    if (choices is! List || choices.isEmpty) {
      throw AiException(
        'The model returned no completion.',
        detail: truncateForDisplay(res.body),
      );
    }
    final content = (choices.first as Map)['message']?['content'];
    if (content is! String || content.trim().isEmpty) {
      throw AiException(
        'The model returned an empty answer.',
        detail: truncateForDisplay(res.body),
      );
    }
    return content;
  }

  Future<http.Response> _send(Future<http.Response> Function() request) async {
    late final http.Response res;
    try {
      res = await request();
    } on SocketException catch (e) {
      throw AiException(
        'Could not reach $baseUrl.\nCheck the address and that the server is '
        'running on the same network.',
        detail: e.message,
      );
    } on HttpException catch (e) {
      throw AiException('The connection failed.', detail: e.message);
    } on FormatException catch (e) {
      throw AiException('That base URL is not valid.', detail: e.message);
    } catch (e) {
      if (e is AiException) rethrow;
      throw AiException('The request failed.', detail: e.toString());
    }

    if (res.statusCode == 401 || res.statusCode == 403) {
      throw const AiException('The server rejected the API key.');
    }
    if (res.statusCode == 404) {
      throw AiException(
        'Not found at $baseUrl. If your server has no /v1 prefix, '
        'try the full path in AI settings.',
      );
    }
    if (res.statusCode >= 400) {
      throw AiException(
        'The server returned HTTP ${res.statusCode}.',
        detail: truncateForDisplay(res.body),
      );
    }
    return res;
  }

}

/// Clips a raw model response down to something that fits in an error dialog.
String truncateForDisplay(String s, [int max = 600]) =>
    s.length <= max ? s : '${s.substring(0, max)}…';

/// Pulls a JSON object out of a model response.
///
/// Small local models routinely wrap JSON in ``` fences or add a sentence of
/// preamble, so a bare `jsonDecode` is not enough. Tries, in order: the whole
/// string, the contents of a fenced block, then the first balanced `{...}`.
Map<String, dynamic>? extractJsonObject(String raw) {
  Map<String, dynamic>? tryDecode(String s) {
    try {
      final v = jsonDecode(s);
      return v is Map<String, dynamic> ? v : null;
    } catch (_) {
      return null;
    }
  }

  final trimmed = raw.trim();
  final direct = tryDecode(trimmed);
  if (direct != null) return direct;

  final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```', caseSensitive: false)
      .firstMatch(trimmed);
  if (fence != null) {
    final inner = tryDecode(fence.group(1)!.trim());
    if (inner != null) return inner;
  }

  // Balanced scan, skipping braces that appear inside string literals.
  final start = trimmed.indexOf('{');
  if (start == -1) return null;
  var depth = 0;
  var inString = false;
  var escaped = false;
  for (var i = start; i < trimmed.length; i++) {
    final ch = trimmed[i];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (ch == r'\') {
      escaped = true;
      continue;
    }
    if (ch == '"') {
      inString = !inString;
      continue;
    }
    if (inString) continue;
    if (ch == '{') depth++;
    if (ch == '}') {
      depth--;
      if (depth == 0) {
        return tryDecode(trimmed.substring(start, i + 1));
      }
    }
  }
  return null;
}
