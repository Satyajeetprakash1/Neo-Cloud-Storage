import 'package:drift/drift.dart';

// Assuming drift code generation will be run in CI via `flutter pub run build_runner build`
// part 'database.g.dart';

@DataClassName('LocalNode')
class LocalNodes extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  BoolColumn get isDirectory => boolean().withDefault(const Constant(false))();
  TextColumn get path => text()(); // ltree representation or local path
  TextColumn get parentId => text().nullable()();
  IntColumn get sizeBytes => integer().withDefault(const Constant(0))();
  TextColumn get syncStatus => text().withDefault(const Constant('PENDING'))(); // PENDING, SYNCED, MODIFIED
  DateTimeColumn get updatedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('SyncQueueItem')
class SyncQueue extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get nodeId => text().references(LocalNodes, #id)();
  TextColumn get operation => text()(); // UPLOAD, DOWNLOAD, DELETE
  IntColumn get chunkIndex => integer().nullable()();
  TextColumn get status => text().withDefault(const Constant('QUEUED'))(); // QUEUED, IN_PROGRESS, FAILED, COMPLETED
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

@DataClassName('DeduplicationRecord')
class DeduplicationRecords extends Table {
  TextColumn get chunkHash => text()();
  BoolColumn get existsGlobally => boolean().withDefault(const Constant(false))();
  DateTimeColumn get lastVerified => dateTime().nullable()();
  
  @override
  Set<Column> get primaryKey => {chunkHash};
}

@DriftDatabase(tables: [LocalNodes, SyncQueue, DeduplicationRecords])
class AppDatabase extends _$AppDatabase {
  AppDatabase(QueryExecutor e) : super(e);

  @override
  int get schemaVersion => 1;
}

// Dummy class to satisfy static analyzer until build_runner generates `database.g.dart` in CI
class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  @override
  int get schemaVersion => 1;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => [];
}
