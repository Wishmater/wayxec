import 'dart:io';

import 'package:flutter_gtk_shell_layer_test/db/isolate_manager.dart';
import 'package:flutter_gtk_shell_layer_test/search_desktop.dart';
import 'package:sembast/sembast.dart';
import 'package:sembast/sembast_io.dart';
import 'package:path/path.dart' as path;
import 'package:flutter_gtk_shell_layer_test/utils.dart';

final _dataHome =
    Platform.environment['XDG_DATA_HOME'] ?? expandEnvironmentVariables(r'$HOME/.local/share');
final _apppath = path.join(_dataHome, "myapplauncher.db");
final database = MDatabase.open(_apppath);

class MDatabase {
  Database db;
  StoreRef<String, Map<String, Object?>> store;

  MDatabase._(this.db, this.store);

  static Future<MDatabase> open(String path) async {
    final db = await databaseFactoryIo.openDatabase(path);
    return MDatabase._(db, stringMapStoreFactory.store());
  }

  Future<List<Application>> getAll() async {
    final query = await store.find(db, finder: Finder());
    return query.map((e) => Application.fromJson(e.value)).toList();
  }

  Future<void> clean() async {
    await store.delete(db, finder: Finder());
  }

  Future<void> upsert(Application app) async {
    await store.record(app.name).put(db, app.toJson());
  }

  Future<void> increaseExecCounter(Application app) async {
    final obj = await store.record(app.name).get(db);
    if (obj == null) {
      return;
    }
    final dbapp = Application.fromJson(obj);
    dbapp.timesExec += 1;
    store.record(app.name).put(db, dbapp.toJson(), merge: true);
  }

  Future<void> saveAll(List<Application> apps) async {
    store.addAll(db, apps.map((e) => e.toJson()).toList());
    await store.records(apps.map((e) => e.name)).put(db, apps.map((e) => e.toJson()).toList());
  }
}

Future<List<Application>> loadApplicationsFromDisk(Map<String, Application> old) async {
  final response = <Application>{};
  final futures = <Future>[];
  final managerSearchIcon = IsolateManager(searchIcon);
  await managerSearchIcon.init();

  for (final dirPath in getApplicationDirectories()) {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) {
      continue;
    }
    for (final entry in dir.listSync(followLinks: true, recursive: true)) {
      if (entry is File) {
        final oldApp = old[entry.absolute.path];

        /// if in cache check for lastModified. If lastModified is equal to file is a cache hit
        if (oldApp != null) {
          final oldLastModified = oldApp.lastModified;
          if (oldLastModified == (entry.statSync().modified)) {
            // in case of two apps having the same name, the freedesktop spec says the first one
            // is the valid one
            if (response.contains(oldApp)) {
              continue;
            }
            // check try exec
            if (oldApp.tryExec != null && !tryExec(oldApp.tryExec!)) {
              continue;
            }
            response.add(oldApp);
            continue;
          }
        }

        final result = Application.parseFromFile(entry);
        if (result.isSuccess()) {
          final app = result.unsafeGetSuccess();
          // in case of two apps having the same name, the freedesktop spec says the first one
          // is the valid one
          if (response.contains(app)) {
            continue;
          }
          // check try exec
          if (app.tryExec != null && !tryExec(app.tryExec!)) {
            continue;
          }
          if (app.icon != null) {
            futures.add(
              managerSearchIcon.run(app.icon!).then((value) => app.iconPath = value),
            );
          }
          response.add(app);
        }
      }
    }
  }
  await Future.wait(futures);
  return response.toList();
}

Future<List<Application>> loadApplications(MDatabase db) async {
  var list = await db.getAll();
  final map = Map.fromEntries(list.map((e) => MapEntry(e.filepath, e)));
  final apps = await loadApplicationsFromDisk(map);
  for (final app in apps) {
    final old = map[app.filepath];
    if (old != null && old.lastModified == app.lastModified) {
      continue;
    }
    db.upsert(app);
  }
  return _orderApps(apps);
}

List<Application> _orderApps(List<Application> apps) {
  List<Application> response = [];

  int searchIndex(int timesExec) {
    int index = 0;
    for (final responseApp in response) {
      if (timesExec > responseApp.timesExec) {
        return index;
      }
      index++;
    }
    return -1;
  }

  for (final app in apps) {
    final index = searchIndex(app.timesExec);
    if (index == -1) {
      response.add(app);
    } else {
      response.insert(index, app);
    }
  }
  return response;
}

bool tryExec(String tryExec) {
  if (path.isAbsolute(tryExec)) {
    final file = File(tryExec);
    if (!file.existsSync()) {
      return false;
    }
    return file.statSync().mode & 256 != 0;
  }
  for (final dir in getPathDirectories()) {
    final file = File(path.join(dir, tryExec));
    if (file.existsSync()) {
      return file.statSync().mode & 256 != 0;
    }
  }
  return false;
}
