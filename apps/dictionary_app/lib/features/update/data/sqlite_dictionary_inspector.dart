import 'sqlite_dictionary_inspector_stub.dart'
    if (dart.library.io) 'sqlite_dictionary_inspector_io.dart'
    as implementation;

Future<bool> isHealthySqliteDictionary(String path) =>
    implementation.isHealthySqliteDictionary(path);

Future<String> readDictionaryVersion(String path) =>
    implementation.readDictionaryVersion(path);
