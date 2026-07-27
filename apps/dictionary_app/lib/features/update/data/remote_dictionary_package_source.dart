import 'remote_dictionary_package_source_stub.dart'
    if (dart.library.io) 'remote_dictionary_package_source_io.dart'
    as implementation;

import 'dictionary_update_service.dart';

DictionaryPackageSource createRemoteDictionaryPackageSource(
  Uri baseUri, {
  bool allowInsecureLoopback = false,
}) {
  return implementation.createRemoteDictionaryPackageSource(
    baseUri,
    allowInsecureLoopback: allowInsecureLoopback,
  );
}
