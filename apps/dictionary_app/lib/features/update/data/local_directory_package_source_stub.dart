import 'dart:typed_data';

import '../domain/release_manifest.dart';
import 'dictionary_update_service.dart';

DictionaryPackageSource createLocalDirectoryPackageSource(
  String directoryPath,
) => _UnsupportedLocalPackageSource();

class _UnsupportedLocalPackageSource implements DictionaryPackageSource {
  @override
  Future<Map<String, Object?>> fetchManifest() {
    throw UnsupportedError('Local release directories are not supported.');
  }

  @override
  Future<Uint8List> fetchDatabase(ReleaseManifest manifest) {
    throw UnsupportedError('Local release directories are not supported.');
  }
}
