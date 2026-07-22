import 'local_directory_package_source_stub.dart'
    if (dart.library.io) 'local_directory_package_source_io.dart'
    as implementation;

import 'dictionary_update_service.dart';

DictionaryPackageSource createLocalDirectoryPackageSource(
  String directoryPath,
) => implementation.createLocalDirectoryPackageSource(directoryPath);
