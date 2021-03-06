import 'dart:convert';

import 'package:dart_service_announcement/dart_service_announcement.dart';
import 'package:moor/moor.dart';
import 'package:moor/sqlite_keywords.dart';
import 'package:moor_inspector/src/uuid.dart';

import 'moor_inspector_server_base.dart';
import 'moore_inspector_empty.dart'
    if (dart.library.html) 'package:moor_inspector/src/moor_inspector_server_web.dart'
    if (dart.library.io) 'package:moor_inspector/src/moor_inspector_server.dart';

const _ANNOUNCEMENT_PORT = 6395;

const _VARIABLE_TYPE_STRING = 'string';
const _VARIABLE_TYPE_BOOL = 'bool';
const _VARIABLE_TYPE_INT = 'int';
const _VARIABLE_TYPE_REAL = 'real';
const _VARIABLE_TYPE_BLOB = 'blob';
const _VARIABLE_TYPE_DATETIME = 'datetime';

class MooreInspectorDriver extends ToolingServer implements ConnectionListener {
  final _databases = <DatabaseHolder>[];
  late final MoorInspectorServer _server;
  final String _bundleId;
  final String? _icon;
  final String _tag = SimpleUUID.uuid().substring(0, 6);
  late final BaseServerAnnouncementManager _announcementManager;
  late List<int> _serverIdData;
  late final List<int> _serverProtocolData;

  @override
  int get port => _server.port;

  @override
  int get protocolVersion => 1;

  MooreInspectorDriver(
    List<DatabaseHolder> databases,
    this._bundleId,
    this._icon,
    int port,
  ) : _server = createServer(port) {
    _databases.addAll(databases);

    _serverProtocolData = utf8.encode(
        json.encode({'type': 'protocol', 'protocolVersion': protocolVersion}));

    _server.connectionListener = this;
    _announcementManager =
        ServerAnnouncementManager(_bundleId, _ANNOUNCEMENT_PORT, this);
    if (_icon != null) {
      _announcementManager.addExtension(IconExtension(_icon!));
    }
    _announcementManager.addExtension(TagExtension(_tag));

    _buildServerIdData();
  }

  Future<void> start() async {
    await _server.start();
    await _announcementManager.start();
  }

  Future<void> stop() async {
    await _server.stop();
    await _announcementManager.stop();
  }

  @override
  void onNewConnection(MooreInspectorConnection connection) {
    connection
      ..sendMessageUTF8(_serverProtocolData)
      ..sendMessageUTF8(_serverIdData);
  }

  void _buildServerIdData() {
    final tableModels = _databases
        .map((tuple) => _buildTableModel(tuple.name, tuple.id, tuple.database))
        .toList();

    final jsonObject = Map<String, dynamic>();
    jsonObject['databases'] = tableModels;
    jsonObject['bundleId'] = _bundleId;
    jsonObject['icon'] = _icon;
    jsonObject['protocolVersion'] = protocolVersion;

    final wrapper = Map<String, dynamic>();
    wrapper['type'] = 'serverInfo';
    wrapper['body'] = jsonObject;

    final asJson = json.encode(wrapper);
    _serverIdData = utf8.encode(asJson);
  }

  Map<String, dynamic> _buildTableModel(
      String name, String id, GeneratedDatabase db) {
    final root = Map<String, dynamic>();
    root['name'] = name;
    root['id'] = id;

    final structure = Map<String, dynamic>();
    root['structure'] = structure;
    structure['version'] = db.schemaVersion;

    structure['tables'] = db.allTables.map((tableInfo) {
      final table = Map<String, dynamic>();
      table['sqlName'] = tableInfo.actualTableName;
      table['withoutRowId'] = tableInfo.withoutRowId;
      table['primaryKey'] =
          tableInfo.$primaryKey.map((column) => column.$name).toList();

      table['columns'] = tableInfo.$columns.map((column) {
        final columnData = Map<String, dynamic>();

        columnData['name'] = column.$name;
        columnData['isRequired'] = column.requiredDuringInsert;
        columnData['type'] = column.typeName;
        columnData['nullable'] = column.$nullable;
        columnData['autoIncrement'] = column.hasAutoIncrement;

        if (column is GeneratedColumn<bool> ||
            column is GeneratedColumn<bool?>) {
          columnData['isBoolean'] = true;
        }

        return columnData;
      }).toList();
      return table;
    }).toList();

    return root;
  }

  @override
  Future<List<int>> filterTable(
    String databaseId,
    String requestId,
    String query,
    List<InspectorVariable> variables, {
    bool sendResponse = true,
  }) async {
    final db =
        _databases.firstOrNull((element) => element.id == databaseId)?.database;
    if (db == null) return Future.error(const NoSuchDatabaseException());

    final select =
        db.customSelect(query, variables: variables.map(_mapVariable).toList());
    final data = await select.get();
    if (!sendResponse) return Future.value(List.empty());

    final jsonData = Map<String, dynamic>();
    jsonData['databaseId'] = databaseId;
    jsonData['requestId'] = requestId;

    if (data.isNotEmpty) {
      final columns = Set<String>();
      jsonData['data'] = data.map((row) {
        final rowItem = Map<String, dynamic>();
        row.data.forEach((key, value) {
          columns.add(key);
          rowItem[key] = value;
        });
        return rowItem;
      }).toList(growable: false);
      jsonData['columns'] = columns.toList(growable: false);
    }

    final wrapper = Map<String, dynamic>();
    wrapper['type'] = 'filterResult';
    wrapper['body'] = jsonData;

    return utf8.encode(json.encode(wrapper));
  }

  @override
  Future<List<int>> update(
    String databaseId,
    String requestId,
    String query,
    List<String> affectedTables,
    List<InspectorVariable> variables, {
    bool sendResponse = true,
  }) async {
    final db =
        _databases.firstOrNull((element) => element.id == databaseId)?.database;
    if (db == null) return Future.error(const NoSuchDatabaseException());

    final numUpdated = await db.customUpdate(
      query,
      updates: db.allTables
          .where((element) => affectedTables.contains(element.actualTableName))
          .toSet(),
      variables: variables.map(_mapVariable).toList(),
    );
    if (!sendResponse) return Future.value(List.empty());

    final jsonData = Map<String, dynamic>();
    jsonData['databaseId'] = databaseId;
    jsonData['requestId'] = requestId;
    jsonData['numUpdated'] = numUpdated;

    final wrapper = Map<String, dynamic>();
    wrapper['type'] = 'updateResult';
    wrapper['body'] = jsonData;

    return utf8.encode(json.encode(wrapper));
  }

  Variable<dynamic> _mapVariable(InspectorVariable e) {
    if (e.data == null) {
      return const Variable(null);
    }
    switch (e.type) {
      case _VARIABLE_TYPE_STRING:
        return Variable.withString(e.data as String);
      case _VARIABLE_TYPE_BOOL:
        return Variable.withBool(e.data as bool);
      case _VARIABLE_TYPE_INT:
        return Variable.withInt(e.data as int);
      case _VARIABLE_TYPE_REAL:
        return Variable.withReal(e.data as double);
      case _VARIABLE_TYPE_BLOB:
        return Variable.withBlob(Uint8List.fromList(e.data as List<int>));
      case _VARIABLE_TYPE_DATETIME:
        return Variable.withDateTime(
            DateTime.fromMicrosecondsSinceEpoch(e.data as int, isUtc: true));
    }
    throw MoorInspectorException(
        'Could not map variable type: ${e.type}, no mapping known');
  }

  @override
  Future<List<int>> export(
    String databaseId,
    String requestId,
    List<String>? tables,
  ) async {
    final db =
        _databases.firstOrNull((element) => element.id == databaseId)?.database;
    if (db == null) return Future.error(const NoSuchDatabaseException());

    final filteredTables = (tables == null || tables.isEmpty)
        ? db.allTables
        : db.allTables
            .where((element) => tables.contains(element.actualTableName));

    final schemas = _createSchema(db, filteredTables);

    final tableData = <Map<String, dynamic>>[];

    final jsonData = Map<String, dynamic>();
    jsonData['databaseId'] = databaseId;
    jsonData['requestId'] = requestId;
    jsonData['schemas'] = schemas;
    jsonData['data'] = tableData;

    await Future.wait(filteredTables.map((e) async {
      final root = Map<String, dynamic>();
      final queryResult =
          await db.customSelect('SELECT * FROM ${e.actualTableName}').get();

      root['name'] = e.actualTableName;
      root['data'] = queryResult.map((row) {
        final rowItem = Map<String, dynamic>();
        row.data.forEach((key, value) {
          rowItem[key] = value;
        });
        return rowItem;
      }).toList(growable: false);

      tableData.add(root);
    }));

    final wrapper = Map<String, dynamic>();
    wrapper['type'] = 'exportResult';
    wrapper['body'] = jsonData;

    final asJson = json.encode(wrapper);
    return utf8.encode(asJson);
  }

  List<String> _createSchema(
      GeneratedDatabase database, Iterable<TableInfo> tables) {
    return tables.map((table) {
      final context = GenerationContext.fromDb(database);
      _createTableStatement(table, context);
      return context.sql;
    }).toList(growable: false);
  }
}

class DatabaseHolder {
  final String name;
  final String id;
  final GeneratedDatabase database;

  DatabaseHolder(this.name, this.id, this.database);
}

class NoSuchDatabaseException implements Exception {
  const NoSuchDatabaseException();

  @override
  String toString() => 'No database with given id found';
}

class MoorInspectorException implements Exception {
  final String message;

  MoorInspectorException(this.message);

  @override
  String toString() => message;
}

void _createTableStatement(TableInfo table, GenerationContext context) {
  context.buffer.write('CREATE TABLE IF NOT EXISTS ${table.aliasedName} (');

  var hasAutoIncrement = false;
  for (var i = 0; i < table.$columns.length; i++) {
    final column = table.$columns[i];

    if (column.hasAutoIncrement) {
      hasAutoIncrement = true;
    }

    column.writeColumnDefinition(context);

    if (i < table.$columns.length - 1) context.buffer.write(', ');
  }

  final dslTable = table.asDslTable;

// we're in a bit of a hacky situation where we don't write the primary
// as table constraint if it has already been written on a primary key
// column, even though that column appears in table.$primaryKey because we
// need to know all primary keys for the update(table).replace(row) API
  final hasPrimaryKey = table.$primaryKey.isNotEmpty;
  final dontWritePk = dslTable.dontWriteConstraints || hasAutoIncrement;
  if (hasPrimaryKey && !dontWritePk) {
    context.buffer.write(', PRIMARY KEY (');
    final pkList = table.$primaryKey.toList(growable: false);
    for (var i = 0; i < pkList.length; i++) {
      final column = pkList[i];

      context.buffer.write(escapeIfNeeded(column.$name));

      if (i != pkList.length - 1) context.buffer.write(', ');
    }
    context.buffer.write(')');
  }

  final constraints = dslTable.customConstraints;

  for (var i = 0; i < constraints.length; i++) {
    context.buffer..write(', ')..write(constraints[i]);
  }

  context.buffer.write(')');

// == true because of nullability
  if (dslTable.withoutRowId == true) {
    context.buffer.write(' WITHOUT ROWID');
  }

  context.buffer.write(';');
}

extension _ListExtension<T> on List<T> {
  T? firstOrNull(bool test(T element)) {
    final index = indexWhere(test);
    if (index >= 0) return this[index];
    return null;
  }
}
