class ReleaseManifest {
  const ReleaseManifest({
    required this.channel,
    required this.contentStatus,
    required this.databaseFile,
    required this.schemaVersion,
    required this.dictionaryVersion,
    required this.minimumAppVersion,
    required this.databaseSize,
    required this.databaseSha256,
    required this.releasedAt,
    required this.licenseStatus,
  });

  factory ReleaseManifest.fromJson(
    Map<String, Object?> json, {
    bool requireCompleteContract = false,
  }) {
    const requiredFields = <String>{
      'channel',
      'content_status',
      'database_file',
      'schema_version',
      'dictionary_version',
      'minimum_app_version',
      'database_size',
      'database_sha256',
      'released_at',
    };
    const completeFields = <String>{...requiredFields, 'license_status'};
    final expectedFields = requireCompleteContract
        ? completeFields
        : requiredFields;
    final missing = expectedFields.difference(json.keys.toSet());
    final unknown = json.keys.toSet().difference(
      requireCompleteContract ? completeFields : completeFields,
    );
    if (missing.isNotEmpty) {
      throw FormatException(
        'release-manifest.json is missing: ${missing.toList()..sort()}',
      );
    }
    if (unknown.isNotEmpty) {
      throw FormatException(
        'release-manifest.json has unknown fields: '
        '${unknown.toList()..sort()}',
      );
    }

    final channel = _string(json, 'channel');
    final contentStatus = _string(json, 'content_status');
    final databaseFile = _string(json, 'database_file');
    final schemaVersion = _integer(json, 'schema_version');
    final dictionaryVersion = _string(json, 'dictionary_version');
    final minimumAppVersion = _string(json, 'minimum_app_version');
    final databaseSize = _integer(json, 'database_size');
    final databaseSha256 = _string(json, 'database_sha256');
    final releasedAtText = _string(json, 'released_at');
    final licenseStatus = json['license_status'] == null
        ? 'cleared'
        : _string(json, 'license_status');

    if (!_semanticVersion.hasMatch(dictionaryVersion) ||
        !_semanticVersion.hasMatch(minimumAppVersion)) {
      throw const FormatException(
        'Manifest versions must be semantic versions.',
      );
    }
    if (databaseSize < 1) {
      throw const FormatException('database_size must be positive.');
    }
    if (!_sha256.hasMatch(databaseSha256)) {
      throw const FormatException(
        'database_sha256 must be a lowercase SHA-256.',
      );
    }
    final releasedAt = DateTime.tryParse(releasedAtText);
    if (releasedAt == null || !releasedAtText.endsWith('Z')) {
      throw const FormatException('released_at must be an ISO-8601 UTC value.');
    }

    return ReleaseManifest(
      channel: channel,
      contentStatus: contentStatus,
      databaseFile: databaseFile,
      schemaVersion: schemaVersion,
      dictionaryVersion: dictionaryVersion,
      minimumAppVersion: minimumAppVersion,
      databaseSize: databaseSize,
      databaseSha256: databaseSha256,
      releasedAt: releasedAt,
      licenseStatus: licenseStatus,
    );
  }

  static final RegExp _semanticVersion = RegExp(
    r'^[0-9]+(?:\.[0-9]+){2}(?:[-+][0-9A-Za-z.-]+)?$',
  );
  static final RegExp _sha256 = RegExp(r'^[a-f0-9]{64}$');

  static String _string(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value is! String || value.isEmpty) {
      throw FormatException('$key must be a non-empty string.');
    }
    return value;
  }

  static int _integer(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value is! int) throw FormatException('$key must be an integer.');
    return value;
  }

  final String channel;
  final String contentStatus;
  final String databaseFile;
  final int schemaVersion;
  final String dictionaryVersion;
  final String minimumAppVersion;
  final int databaseSize;
  final String databaseSha256;
  final DateTime releasedAt;
  final String licenseStatus;
}
