import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/course.dart';
import '../models/event_item.dart';
import '../models/task.dart';
import 'backup_codec.dart';

/// 三张业务表：课程是规则，事件/任务是一次性实例。显示层才混排。
class AppData {
  const AppData({
    required this.courses,
    required this.events,
    required this.tasks,
  });

  final List<Course> courses;
  final List<EventItem> events;
  final List<TaskItem> tasks;
}

class DbService {
  Database? _database;

  Future<Database> get database async {
    final existing = _database;
    if (existing != null) return existing;
    final dir = await getDatabasesPath();
    final db = await openDatabase(
      p.join(dir, 'todo_app.db'),
      version: 1,
      onCreate: _createTables,
    );
    _database = db;
    return db;
  }

  Future<void> init() async => database;

  Future<void> _createTables(Database db, int version) async {
    await db.execute('''
      CREATE TABLE courses(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        day_of_week INTEGER NOT NULL,
        start_time TEXT NOT NULL,
        end_time TEXT NOT NULL,
        location TEXT,
        color TEXT,
        semester_start TEXT NOT NULL,
        semester_end TEXT NOT NULL,
        week_parity INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE events(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        start_at TEXT NOT NULL,
        location TEXT,
        note TEXT,
        done INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE tasks(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        due_date TEXT NOT NULL,
        due_time TEXT,
        location TEXT,
        note TEXT,
        done INTEGER NOT NULL DEFAULT 0
      )
    ''');
  }

  Future<int> insertCourse(Course item) async =>
      (await database).insert('courses', item.toMap()..remove('id'));
  Future<int> insertEvent(EventItem item) async =>
      (await database).insert('events', item.toMap()..remove('id'));
  Future<int> insertTask(TaskItem item) async =>
      (await database).insert('tasks', item.toMap()..remove('id'));

  Future<void> setTaskDone(int id, {required bool done}) async {
    await (await database).update(
      'tasks',
      {'done': done ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<AppData> queryAll() async {
    final db = await database;
    final courses = await db.query(
      'courses',
      orderBy: 'day_of_week, start_time',
    );
    final events = await db.query('events', orderBy: 'start_at');
    final tasks = await db.query('tasks', orderBy: 'due_date, due_time');
    return AppData(
      courses: courses.map(Course.fromMap).toList(),
      events: events.map(EventItem.fromMap).toList(),
      tasks: tasks.map(TaskItem.fromMap).toList(),
    );
  }

  Future<BackupData> exportData() async {
    final data = await queryAll();
    return BackupData(
      courses: data.courses,
      events: data.events,
      tasks: data.tasks,
    );
  }

  /// 覆盖式恢复：事务内清空三表再写入，任何失败整体回滚。
  Future<void> restore(BackupData data) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('courses');
      await txn.delete('events');
      await txn.delete('tasks');
      for (final item in data.courses) {
        await txn.insert('courses', item.toMap()..remove('id'));
      }
      for (final item in data.events) {
        await txn.insert('events', item.toMap()..remove('id'));
      }
      for (final item in data.tasks) {
        await txn.insert('tasks', item.toMap()..remove('id'));
      }
    });
  }
}
