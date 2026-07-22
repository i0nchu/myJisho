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
  });

  factory ReleaseManifest.fromJson(Map<String, Object?> json) {
    return ReleaseManifest(
      channel: json['channel']! as String,
      contentStatus: json['content_status']! as String,
      databaseFile: json['database_file']! as String,
      schemaVersion: json['schema_version']! as int,
      dictionaryVersion: json['dictionary_version']! as String,
      minimumAppVersion: json['minimum_app_version']! as String,
      databaseSize: json['database_size']! as int,
      databaseSha256: json['database_sha256']! as String,
      releasedAt: DateTime.parse(json['released_at']! as String),
    );
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
}
