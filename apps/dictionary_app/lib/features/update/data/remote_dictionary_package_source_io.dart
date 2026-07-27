import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../domain/release_manifest.dart';
import '../domain/update_models.dart';
import 'dictionary_update_service.dart';

const _maximumMetadataBytes = 512 * 1024;
const _requestTimeout = Duration(seconds: 30);
const _streamIdleTimeout = Duration(seconds: 30);

DictionaryPackageSource createRemoteDictionaryPackageSource(
  Uri baseUri, {
  bool allowInsecureLoopback = false,
}) {
  return RemoteDictionaryPackageSource(
    baseUri,
    allowInsecureLoopback: allowInsecureLoopback,
  );
}

class RemoteDictionaryPackageSource
    implements DictionaryPackageSource, CompleteDictionaryPackageSource {
  RemoteDictionaryPackageSource(
    Uri baseUri, {
    this.allowInsecureLoopback = false,
  }) : baseUri = _validateBaseUri(baseUri, allowInsecureLoopback);

  final Uri baseUri;
  final bool allowInsecureLoopback;

  @override
  Future<CompletePackageMetadata> fetchCompletePackageMetadata(
    UpdateCancellationToken cancellationToken,
  ) async {
    final release = await _getBytes(
      'release-manifest.json',
      cancellationToken,
      accept: 'application/json',
    );
    final assets = await _getBytes(
      'assets-manifest.json',
      cancellationToken,
      accept: 'application/json',
    );
    final checksums = await _getBytes(
      'checksums.txt',
      cancellationToken,
      accept: 'text/plain',
    );
    return CompletePackageMetadata(
      releaseManifestBytes: release,
      assetsManifestBytes: assets,
      checksumsBytes: checksums,
    );
  }

  @override
  Future<DictionaryDownload> openDatabaseDownload(
    ReleaseManifest manifest,
    UpdateCancellationToken cancellationToken,
  ) async {
    if (manifest.databaseFile != 'dictionary.sqlite') {
      throw const DictionaryDownloadException(
        'Remote manifest selected an unsupported filename.',
      );
    }
    cancellationToken.throwIfCancelled();
    final client = HttpClient()..connectionTimeout = _requestTimeout;
    HttpClientRequest? request;
    var cleanedUp = false;
    var streamOwnsClient = false;
    late void Function() abort;
    void cleanup() {
      if (cleanedUp) return;
      cleanedUp = true;
      cancellationToken.removeListener(abort);
      client.close(force: true);
    }

    abort = () {
      request?.abort(const UpdateCancelledException());
      cleanup();
    };

    cancellationToken.addListener(abort);
    try {
      request = await client
          .getUrl(_fileUri('dictionary.sqlite'))
          .timeout(_requestTimeout);
      request.followRedirects = false;
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/octet-stream')
        ..set(HttpHeaders.userAgentHeader, 'myJisho/0.1 dictionary-updater');
      final response = await request.close().timeout(_requestTimeout);
      _requireSuccessfulResponse(response, 'dictionary.sqlite');
      final length = response.contentLength < 0 ? null : response.contentLength;
      final bytes = _guardedResponseStream(
        response,
        cancellationToken,
        cleanup,
      );
      streamOwnsClient = true;
      return DictionaryDownload(
        bytes: bytes,
        contentLength: length,
        onDispose: () async => cleanup(),
      );
    } on UpdateCancelledException {
      rethrow;
    } on Object catch (error) {
      if (cancellationToken.isCancelled) {
        throw const UpdateCancelledException();
      }
      throw DictionaryDownloadException(
        'Could not open the dictionary download.',
        error,
      );
    } finally {
      if (!streamOwnsClient) cleanup();
    }
  }

  Stream<List<int>> _guardedResponseStream(
    HttpClientResponse response,
    UpdateCancellationToken cancellationToken,
    void Function() cleanup,
  ) async* {
    try {
      await for (final chunk in response.timeout(_streamIdleTimeout)) {
        cancellationToken.throwIfCancelled();
        yield chunk;
      }
      cancellationToken.throwIfCancelled();
    } on UpdateCancelledException {
      rethrow;
    } on Object catch (error) {
      if (cancellationToken.isCancelled) {
        throw const UpdateCancelledException();
      }
      throw DictionaryDownloadException(
        'Dictionary download was interrupted.',
        error,
      );
    } finally {
      cleanup();
    }
  }

  @override
  Future<Map<String, Object?>> fetchManifest() async {
    final bytes = await _getBytes(
      'release-manifest.json',
      UpdateCancellationToken(),
      accept: 'application/json',
    );
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('release-manifest.json must be an object.');
    }
    return decoded;
  }

  @override
  Future<Uint8List> fetchDatabase(ReleaseManifest manifest) async {
    final download = await openDatabaseDownload(
      manifest,
      UpdateCancellationToken(),
    );
    final builder = BytesBuilder(copy: false);
    try {
      await for (final chunk in download.bytes) {
        builder.add(chunk);
      }
      return builder.takeBytes();
    } finally {
      await download.dispose();
    }
  }

  Future<Uint8List> _getBytes(
    String filename,
    UpdateCancellationToken cancellationToken, {
    required String accept,
  }) async {
    cancellationToken.throwIfCancelled();
    final client = HttpClient()..connectionTimeout = _requestTimeout;
    HttpClientRequest? request;
    void abort() {
      request?.abort(const UpdateCancelledException());
      client.close(force: true);
    }

    cancellationToken.addListener(abort);
    try {
      request = await client
          .getUrl(_fileUri(filename))
          .timeout(_requestTimeout);
      request.followRedirects = false;
      request.headers
        ..set(HttpHeaders.acceptHeader, accept)
        ..set(HttpHeaders.userAgentHeader, 'myJisho/0.1 dictionary-updater');
      final response = await request.close().timeout(_requestTimeout);
      _requireSuccessfulResponse(response, filename);
      if (response.contentLength > _maximumMetadataBytes) {
        throw DictionaryDownloadException('$filename is too large.');
      }
      final builder = BytesBuilder(copy: false);
      var received = 0;
      await for (final chunk in response.timeout(_streamIdleTimeout)) {
        cancellationToken.throwIfCancelled();
        received += chunk.length;
        if (received > _maximumMetadataBytes) {
          throw DictionaryDownloadException('$filename is too large.');
        }
        builder.add(chunk);
      }
      return builder.takeBytes();
    } on UpdateCancelledException {
      rethrow;
    } on DictionaryDownloadException {
      rethrow;
    } on Object catch (error) {
      if (cancellationToken.isCancelled) {
        throw const UpdateCancelledException();
      }
      throw DictionaryDownloadException('Could not fetch $filename.', error);
    } finally {
      cancellationToken.removeListener(abort);
      client.close(force: true);
    }
  }

  Uri _fileUri(String filename) => baseUri.resolve(filename);

  static Uri _validateBaseUri(Uri uri, bool allowInsecureLoopback) {
    if (!uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !uri.path.endsWith('/')) {
      throw ArgumentError.value(
        uri,
        'baseUri',
        'Must be an absolute directory URL without credentials, query, or '
            'fragment.',
      );
    }
    if (uri.scheme == 'https') return uri;
    if (uri.scheme == 'http' &&
        allowInsecureLoopback &&
        _isLoopbackHost(uri.host)) {
      return uri;
    }
    throw ArgumentError.value(
      uri,
      'baseUri',
      'Remote updates require HTTPS. HTTP is test-only on loopback.',
    );
  }

  static bool _isLoopbackHost(String host) {
    if (host.toLowerCase() == 'localhost') return true;
    return InternetAddress.tryParse(host)?.isLoopback ?? false;
  }

  static void _requireSuccessfulResponse(
    HttpClientResponse response,
    String filename,
  ) {
    if (response.isRedirect) {
      throw DictionaryDownloadException(
        'Redirects are not accepted for $filename.',
      );
    }
    if (response.statusCode != HttpStatus.ok) {
      throw DictionaryDownloadException(
        '$filename returned HTTP ${response.statusCode}.',
      );
    }
  }
}
