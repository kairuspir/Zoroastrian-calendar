import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'models/calendar_event.dart';
import 'models/calendar_type.dart';
import 'models/event_editor_model.dart';
import 'models/event_editor_view_model.dart';
import 'models/event_list_tab_view_model.dart';
import 'models/home_tab_view_model.dart';
import 'models/my_app_view_model.dart';
import 'models/user_preferences.dart';
import 'models/zorastrian_date.dart';
import 'time_provider.dart';
import 'utilities.dart';

class DBProvider {
  DBProvider._();

  static final DBProvider db = DBProvider._();

  static const _key_theme = "Theme";
  static const _key_theme_color = "ThemeColor";
  static const _key_calendar_type = "PreferredCalendarType";

  static const calendar_key_shahenshai = "Shahanshahi";
  static const calendar_key_kadmi = "Kadmi";
  static const calendar_key_fasli = "Fasli";

  Database _database;
  List<CalendarType> _calendarTypes;
  List<int> _fasliLeapYears;
  List<String> _mahCollection;
  EventEditorModel _eventEditorModel;

  Future<Database> get database async {
    if (_database != null) return _database;
    // if _database is null we instantiate it
    _database = await _initializeDB();
    return _database;
  }

  _initializeDB() async {
    // Construct a file path to copy database to
    Directory documentsDirectory = await getApplicationDocumentsDirectory();
    String path = join(documentsDirectory.path, "asset_database.db");

    // Only copy if the database doesn't exist
    if (FileSystemEntity.typeSync(path) == FileSystemEntityType.notFound) {
      // Load database from asset and copy
      ByteData data =
          await rootBundle.load(join('assets', 'calLookupDb.sqlite'));
      List<int> bytes =
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);

      // Save copied asset to documents
      await new File(path).writeAsBytes(bytes);
    }
    return await openDatabase(path);
  }

  Future<List<CalendarType>> get calendarTypes async {
    if (_calendarTypes != null) return _calendarTypes;
    final db = await database;
    final res = await db.query("CalendarType");
    final result = res.isNotEmpty
        ? res.map((e) => CalendarType.fromMap(e)).toList()
        : <CalendarType>[];
    _calendarTypes = result;
    return _calendarTypes;
  }

  Future<List<int>> get fasliLeapYears async {
    if (_fasliLeapYears != null) return _fasliLeapYears;
    final db = await database;
    final result = (await db.rawQuery(
            "SELECT fasliyear FROM CalendarMasterLookup where faslidayid = 366"))
        .map<int>((x) => x["fasliyear"])
        .toList();
    _fasliLeapYears = result;
    return _fasliLeapYears;
  }

  Future<List<String>> get mahCollection async {
    if (_mahCollection != null) return _mahCollection;
    final db = await database;
    final result = (await db.rawQuery('''
      Select a.mahname
      FROM( SELECT Max(id), mahname 
      FROM CalendarDayLookup 
      GROUP BY mahname
      order BY 1) as a''')).map<String>((x) => x["mahname"]).toList();
    _mahCollection = result;
    return _mahCollection;
  }

  Future<List<CalendarEvent>> _getEventsForDay(
      String calendarType, int calendarDayId) async {
    final db = await database;
    final cts = await calendarTypes;

    final calendarTypeId = cts.where((x) => x.name == calendarType).single.id;
    final res = await db.query("CalendarEvent",
        where:
            "calendarDayLookupId = ? AND (calendarTypeId = 4 OR calendarTypeId = ?)",
        whereArgs: [calendarDayId, calendarTypeId]);
    final result = res.isNotEmpty
        ? res.map((e) => CalendarEvent.fromMap(e)).toList()
        : <CalendarEvent>[];
    return result;
  }

  Future<int> _setUserPreference(String name, String value) async {
    final db = await database;
    var result = await db.update(
        "UserPreferences", UserPreference(name: name, value: value).toMap(),
        where: "name = ?", whereArgs: [name]);
    return result;
  }

  Future<List<UserPreference>> _getUserPreferences() async {
    final db = await database;
    String query = '''
      Select * From UserPreferences
      ''';
    final queryResult = await db.rawQuery(query);
    final result = queryResult.isNotEmpty
        ? queryResult.map((e) => UserPreference.fromMap(e)).toList()
        : <UserPreference>[];
    return result;
  }

  Future<ZorastrianDate> _getZorastrianDateRaw(CalendarType calendarType,
      String rojName, String mahName, int year) async {
    final db = await database;
    String query = '''
      SELECT CML.id,
      CML.GregorianDate,
      CML.Shahanshahidayid,
      SCDL.RojName AS 'ShahanshahiRojName',
      SCDL.MahName AS 'ShahanshahiMahName',
      CML.ShahanshahiYear,
      CML.KadmiDayId,
      KCDL.RojName AS 'KadmiRojName',
      KCDL.MahName AS 'KadmiMahName',
      CML.KadmiYear,
      CML.faslidayid,
      FCDL.RojName AS 'FasliRojName',
      FCDL.MahName AS 'FasliMahName',
      CML.FasliYear
      FROM CalendarMasterLookup 'CML'
      join CalendarDayLookup 'SCDL' on CML.shahanshahidayid = SCDL.Id
      join CalendarDayLookup 'KCDL' on CML.kadmidayid = KCDL.Id
      join CalendarDayLookup 'FCDL' on CML.faslidayid = FCDL.Id
      ''';
    final whereClause = (calendarType.name == calendar_key_shahenshai)
        ? "where SCDL.RojName = ? AND SCDL.MahName = ? AND CML.ShahanshahiYear = ?"
        : (calendarType.name == calendar_key_kadmi)
            ? "where KCDL.RojName = ? AND KCDL.MahName = ? AND CML.KadmiYear = ?"
            : "where FCDL.RojName = ? AND FCDL.MahName = ? AND CML.FasliYear = ?";
    var queryResult =
        await db.rawQuery(query + whereClause, [rojName, mahName, year]);
    if (queryResult.isEmpty) {
      final lastRowClause =
          (year >= 1470) ? "order by 1 Desc LIMIT 1" : "order by 1 ASC LIMIT 1";
      queryResult = await db.rawQuery(query + lastRowClause);
    }
    final result = ZorastrianDate.fromMap(queryResult.first);
    return result;
  }

  Future<ZorastrianDate> getZorastrianDate(DateTime now) async {
    final db = await database;
    DateTime inputDate;
    if (now.hour < 6) {
      // Zorastrian day starts at 6 am.
      inputDate = DateTime(now.year, now.month, now.day - 1, now.hour,
          now.minute, now.second, now.millisecond, now.microsecond);
    } else {
      inputDate = now;
    }
    final today = inputDate.toString().substring(0, 10) + " 00:00:00.000";
    String query = '''
      SELECT CML.id,
      CML.GregorianDate,
      CML.Shahanshahidayid,
      SCDL.RojName AS 'ShahanshahiRojName',
      SCDL.MahName AS 'ShahanshahiMahName',
      CML.ShahanshahiYear,
      CML.KadmiDayId,
      KCDL.RojName AS 'KadmiRojName',
      KCDL.MahName AS 'KadmiMahName',
      CML.KadmiYear,
      CML.faslidayid,
      FCDL.RojName AS 'FasliRojName',
      FCDL.MahName AS 'FasliMahName',
      CML.FasliYear
      FROM CalendarMasterLookup 'CML'
      join CalendarDayLookup 'SCDL' on CML.shahanshahidayid = SCDL.Id
      join CalendarDayLookup 'KCDL' on CML.kadmidayid = KCDL.Id
      join CalendarDayLookup 'FCDL' on CML.faslidayid = FCDL.Id
      where CML.gregoriandate = ?
      ''';
    final queryResult = await db.rawQuery(query, [today]);
    final zd = ZorastrianDate.fromMap(queryResult.first);
    final result = zd.copyWith(gregorianDate: now);
    return result;
  }

  String _getGah(TimeProvider timeProvider, int dayId) {
    final dateTime = timeProvider.dateTime;
    final midnight = timeProvider.midnight.toDouble();
    final sunrise = timeProvider.sunrise.toDouble();
    final noon = timeProvider.noon.toDouble();
    final afternoon = timeProvider.afternoon.toDouble();
    final sunset = timeProvider.sunset.toDouble();
    final time = TimeOfDay.fromDateTime(dateTime).toDouble();
    var result = "";
    if (time >= midnight && time < sunrise) {
      result = "Ushahin";
    } else if (time >= sunrise && time < noon) {
      result = "Havan";
    } else if (time >= noon && time < afternoon) {
      result = (dayId < 211) ? "Rapithwin" : "Second Havan";
    } else if (time >= afternoon && time < sunset) {
      result = "Uzirin";
    } else {
      result = "Aiwisruthrem";
    }
    return result;
  }

  Future<String> _getChog(TimeProvider timeProvider) async {
    // Good - Amrut, Shubh, Labh, Chal
    // Bad - Udveg, Rog, Kaal
    final db = await database;
    final dateTime = timeProvider.dateTime;
    final day = DateFormat.EEEE().format(dateTime);
    final dayPhase = timeProvider.dayPhase;
    final chogNumber = timeProvider.chogNumber;
    String query = '''
      SELECT ChaughadiaName FROM ChaughadiaLookup
      JOIN Chaughadia on ChaughadiaLookup.ChaugNameId = Chaughadia.ChaughadiaNameId
      WHERE chaugnumber = ? AND dayphase=? AND day = ?
    ''';
    final queryResult = await db.rawQuery(query, [chogNumber, dayPhase, day]);
    final result = queryResult.first["ChaughadiaName"];
    return result;
  }

  Future<List<EventListTabViewModel>> getEventListTabData() async {
    final db = await database;
    String query = '''
      SELECT MIN(cml.GregorianDate) as GregorianDate , ce.Id, ce.title
      FROM CalendarEvent ce
      join CalendarDayLookup cdl on cdl.Id = ce.CalendarDayLookupId
      join CalendarMasterLookup cml on cml.ShahanshahiDayId = cdl.Id
      where cml.GregorianDate > datetime('now','localtime')
      GROUP BY ce.Id, ce.title
      ORDER BY 1 ASC
      ''';
    final queryResult = await db.rawQuery(query);
    final result = queryResult.isEmpty
        ? []
        : queryResult.map((x) => EventListTabViewModel.fromMap(x)).toList();
    return result;
  }

  Future<HomeTabViewModel> getHomeTabData(DateTime now) async {
    final zdt = await getZorastrianDate(now);
    final timeProvider = TimeProvider(now);
    final sg = _getGah(timeProvider, zdt.shahanshahiDayId);
    final kg = _getGah(timeProvider, zdt.kadmiDayId);
    final fg = _getGah(timeProvider, zdt.fasliDayId);
    final ch = await _getChog(timeProvider);
    final se =
        await _getEventsForDay(calendar_key_shahenshai, zdt.shahanshahiDayId);
    final ke = await _getEventsForDay(calendar_key_kadmi, zdt.kadmiDayId);
    final fe = await _getEventsForDay(calendar_key_fasli, zdt.fasliDayId);
    return HomeTabViewModel(
      zorastrianDate: zdt,
      shahanshahiGah: sg,
      kadmiGah: kg,
      fasliGah: fg,
      chog: ch,
      shahanshahiEvents: se,
      kadmiEvents: ke,
      fasliEvents: fe,
    );
  }

  Future<int> setThemeColorPreference(MaterialColor color) async {
    final colorStr = color.toMaterialColorName();
    return await _setUserPreference(_key_theme_color, colorStr);
  }

  Future<int> setTheme(ThemeMode input) async {
    String themeStr = "";
    switch (input) {
      case ThemeMode.light:
        themeStr = "light";
        break;
      case ThemeMode.dark:
        themeStr = "dark";
        break;
      case ThemeMode.system:
      default:
        themeStr = "system";
        break;
    }
    return await _setUserPreference(_key_theme, themeStr);
  }

  Future<int> setPreferredCalendar(CalendarType input) async {
    final inputStr = input.id.toString();
    return await _setUserPreference(_key_calendar_type, inputStr);
  }

  Future<void> saveEvent(CalendarEvent input) async {
    final db = await database;
    if (input.id == 0) {
      final queryResult =
          await db.rawQuery("SELECT MAX(id)+1 as id FROM CalendarEvent");
      final int id = queryResult.first["id"];
      await db.insert("CalendarEvent", input.copyWith(id: id).toMap());
    } else {
      await db.update("CalendarEvent", input.toMap(),
          where: "id=?", whereArgs: [input.id]);
    }
  }

  Future<void> deleteEvent(CalendarEvent input) async {
    final db = await database;
    db.delete("CalendarEvent", where: "id = ?", whereArgs: [input.id]);
  }

  Future<MyAppViewModel> getMyAppData() async {
    final preferences = await _getUserPreferences();

    final color = preferences
        .where((x) => x.name == _key_theme_color)
        .single
        .value
        .toMaterialColor();

    final themeStr = preferences
        .where((x) => x.name == _key_theme)
        .single
        .value
        .toLowerCase();

    final themeMode = (themeStr == "light")
        ? ThemeMode.light
        : (themeStr == "dark") ? ThemeMode.dark : ThemeMode.system;

    final cts = await calendarTypes;
    final pct = int.parse(
        preferences.where((x) => x.name == _key_calendar_type).single.value);
    final calendarType = cts.where((x) => x.id == pct).single;
    return MyAppViewModel(
        themeColor: color, themeMode: themeMode, calendarType: calendarType);
  }

  Future saveEventEditorEvent() async {
    await saveEvent(_eventEditorModel.calendarEvent);
  }

  void clearEventEditorState() {
    _eventEditorModel = null;
  }

  void setEventEditorState({
    @required EditorMode editorTitle,
    @required ZorastrianDate zorastrianDate,
    @required CalendarEvent calendarEvent,
    Frequency selectedFrequency = Frequency.Yearly,
  }) {
    _eventEditorModel = EventEditorModel(
        editorTitle: editorTitle,
        calendarEvent: calendarEvent,
        zorastrianDate: zorastrianDate,
        selectedFrequency: selectedFrequency);
  }

  void setEventEditorEventTitle(String title) {
    final newCalendarEvent =
        _eventEditorModel.calendarEvent.copyWith(title: title);

    _eventEditorModel =
        _eventEditorModel.copyWith(calendarEvent: newCalendarEvent);
  }

  void setEventEditorCalendarType(CalendarType calendarType) {
    final zd = _eventEditorModel.zorastrianDate;
    final newCalendarDayLookupId =
        (calendarType.name == calendar_key_shahenshai)
            ? zd.shahanshahiDayId
            : (calendarType.name == calendar_key_kadmi)
                ? zd.kadmiDayId
                : zd.fasliDayId;
    final newCalendarTypeId = calendarType.id;
    final newCalendarEvent = _eventEditorModel.calendarEvent.copyWith(
        calendarDayLookupId: newCalendarDayLookupId,
        calendarTypeId: newCalendarTypeId);
    _eventEditorModel =
        _eventEditorModel.copyWith(calendarEvent: newCalendarEvent);
  }

  Future setEventEditorMah(String mahName) async {
    final calendarType = (await calendarTypes)
        .where((x) => x.id == _eventEditorModel.calendarEvent.calendarTypeId)
        .single;

    final oldMahName = (calendarType.name == calendar_key_shahenshai)
        ? _eventEditorModel.zorastrianDate.shahanshahiMahName
        : (calendarType.name == calendar_key_kadmi)
            ? _eventEditorModel.zorastrianDate.kadmiMahName
            : _eventEditorModel.zorastrianDate.fasliMahName;
    final newMahName = mahName;
    String rojName;
    if (oldMahName != "Gatha" && newMahName == "Gatha") {
      rojName = "Ahunavad";
    } else if (oldMahName == "Gatha" && newMahName != "Gatha") {
      rojName = "Hormazd";
    } else {
      rojName = (calendarType.name == calendar_key_shahenshai)
          ? _eventEditorModel.zorastrianDate.shahanshahiRojName
          : (calendarType.name == calendar_key_kadmi)
              ? _eventEditorModel.zorastrianDate.kadmiRojName
              : _eventEditorModel.zorastrianDate.fasliRojName;
    }

    final year = (calendarType.name == calendar_key_shahenshai)
        ? _eventEditorModel.zorastrianDate.shahanshahiYear
        : (calendarType.name == calendar_key_kadmi)
            ? _eventEditorModel.zorastrianDate.kadmiYear
            : _eventEditorModel.zorastrianDate.fasliYear;

    final newZorastrianDate =
        await _getZorastrianDateRaw(calendarType, rojName, mahName, year);
    final newCalendarDayLookupId =
        (calendarType.name == calendar_key_shahenshai)
            ? newZorastrianDate.shahanshahiDayId
            : (calendarType.name == calendar_key_kadmi)
                ? newZorastrianDate.kadmiDayId
                : newZorastrianDate.fasliDayId;
    final newCalendarMasterLookupId = newZorastrianDate.id;
    final newCalendarEvent = _eventEditorModel.calendarEvent.copyWith(
        calendarDayLookupId: newCalendarDayLookupId,
        calendarMasterLookupId: newCalendarMasterLookupId);
    _eventEditorModel = _eventEditorModel.copyWith(
        calendarEvent: newCalendarEvent, zorastrianDate: newZorastrianDate);
  }

  Future setEventEditorRoj(String rojName) async {
    final calendarType = (await calendarTypes)
        .where((x) => x.id == _eventEditorModel.calendarEvent.calendarTypeId)
        .single;
    final mahName = (calendarType.name == calendar_key_shahenshai)
        ? _eventEditorModel.zorastrianDate.shahanshahiMahName
        : (calendarType.name == calendar_key_kadmi)
            ? _eventEditorModel.zorastrianDate.kadmiMahName
            : _eventEditorModel.zorastrianDate.fasliMahName;
    final year = (calendarType.name == calendar_key_shahenshai)
        ? _eventEditorModel.zorastrianDate.shahanshahiYear
        : (calendarType.name == calendar_key_kadmi)
            ? _eventEditorModel.zorastrianDate.kadmiYear
            : _eventEditorModel.zorastrianDate.fasliYear;

    final newZorastrianDate =
        await _getZorastrianDateRaw(calendarType, rojName, mahName, year);
    final newCalendarDayLookupId =
        (calendarType.name == calendar_key_shahenshai)
            ? newZorastrianDate.shahanshahiDayId
            : (calendarType.name == calendar_key_kadmi)
                ? newZorastrianDate.kadmiDayId
                : newZorastrianDate.fasliDayId;
    final newCalendarMasterLookupId = newZorastrianDate.id;
    final newCalendarEvent = _eventEditorModel.calendarEvent.copyWith(
        calendarDayLookupId: newCalendarDayLookupId,
        calendarMasterLookupId: newCalendarMasterLookupId);
    _eventEditorModel = _eventEditorModel.copyWith(
        calendarEvent: newCalendarEvent, zorastrianDate: newZorastrianDate);
  }

  Future setEventEditorYear(int year) async {
    final calendarType = (await calendarTypes)
        .where((x) => x.id == _eventEditorModel.calendarEvent.calendarTypeId)
        .single;
    final mahName = (calendarType.name == calendar_key_shahenshai)
        ? _eventEditorModel.zorastrianDate.shahanshahiMahName
        : (calendarType.name == calendar_key_kadmi)
            ? _eventEditorModel.zorastrianDate.kadmiMahName
            : _eventEditorModel.zorastrianDate.fasliMahName;
    final rojName = (calendarType.name == calendar_key_shahenshai)
        ? _eventEditorModel.zorastrianDate.shahanshahiRojName
        : (calendarType.name == calendar_key_kadmi)
            ? _eventEditorModel.zorastrianDate.kadmiRojName
            : _eventEditorModel.zorastrianDate.fasliRojName;
    final newZorastrianDate =
        await _getZorastrianDateRaw(calendarType, rojName, mahName, year);
    final newCalendarDayLookupId =
        (calendarType.name == calendar_key_shahenshai)
            ? newZorastrianDate.shahanshahiDayId
            : (calendarType.name == calendar_key_kadmi)
                ? newZorastrianDate.kadmiDayId
                : newZorastrianDate.fasliDayId;
    final newCalendarMasterLookupId = newZorastrianDate.id;
    final newCalendarEvent = _eventEditorModel.calendarEvent.copyWith(
        calendarDayLookupId: newCalendarDayLookupId,
        calendarMasterLookupId: newCalendarMasterLookupId);
    _eventEditorModel = _eventEditorModel.copyWith(
        calendarEvent: newCalendarEvent, zorastrianDate: newZorastrianDate);
  }

  Future setEventEditorDate(DateTime date) async {
    final input = DateTime(date.year, date.month, date.day, 7);
    final calendarType = (await calendarTypes)
        .where((x) => x.id == _eventEditorModel.calendarEvent.calendarTypeId)
        .single;
    final newZorastrianDate = await getZorastrianDate(input);
    final newCalendarDayLookupId =
        (calendarType.name == calendar_key_shahenshai)
            ? newZorastrianDate.shahanshahiDayId
            : (calendarType.name == calendar_key_kadmi)
                ? newZorastrianDate.kadmiDayId
                : newZorastrianDate.fasliDayId;
    final newCalendarMasterLookupId = newZorastrianDate.id;
    final newCalendarEvent = _eventEditorModel.calendarEvent.copyWith(
        calendarDayLookupId: newCalendarDayLookupId,
        calendarMasterLookupId: newCalendarMasterLookupId);
    _eventEditorModel = _eventEditorModel.copyWith(
        calendarEvent: newCalendarEvent, zorastrianDate: newZorastrianDate);
  }

  Future<EventEditorViewModel> getEventEditorData() async {
    final db = await database;
    final String editorTitle = (_eventEditorModel.editorTitle == EditorMode.Add)
        ? "Add Event"
        : "Edit Event";
    final ZorastrianDate zorastrianDate = _eventEditorModel.zorastrianDate;
    final CalendarEvent calendarEvent = _eventEditorModel.calendarEvent;
    final String selectedFrequency =
        (_eventEditorModel.selectedFrequency == Frequency.Yearly)
            ? "Yearly"
            : "Monthly";

    final eventTitle = calendarEvent.title;
    final cts = await calendarTypes;
    final selectedCalendarType =
        cts.where((x) => x.id == calendarEvent.calendarTypeId).single;
    final selectedCalendarTypeName = selectedCalendarType.name;

    final selectedMah = (selectedCalendarTypeName == calendar_key_shahenshai)
        ? zorastrianDate.shahanshahiMahName
        : (selectedCalendarTypeName == calendar_key_kadmi)
            ? zorastrianDate.kadmiMahName
            : zorastrianDate.fasliMahName;
    final selectedRoj = (selectedCalendarTypeName == calendar_key_shahenshai)
        ? zorastrianDate.shahanshahiRojName
        : (selectedCalendarTypeName == calendar_key_kadmi)
            ? zorastrianDate.kadmiRojName
            : zorastrianDate.fasliRojName;
    final selectedYear = (selectedCalendarTypeName == calendar_key_shahenshai)
        ? zorastrianDate.shahanshahiYear
        : (selectedCalendarTypeName == calendar_key_kadmi)
            ? zorastrianDate.kadmiYear
            : zorastrianDate.fasliYear;

    final selectedDate = zorastrianDate.gregorianDate;

    int daysInYear = 365;
    if (selectedCalendarTypeName == calendar_key_fasli) {
      final fly = await fasliLeapYears;
      if (fly.contains(selectedYear)) {
        daysInYear = 366;
      }
    }
    final rc = (await db.rawQuery('''
      SELECT rojname FROM CalendarDayLookup 
      where id <=? and mahname = ?
    ''', [daysInYear, selectedMah])).map<String>((x) => x["RojName"]).toList();
    final fc = ["Yearly", "Monthly"];
    final mc = await mahCollection;
    return EventEditorViewModel(
      calendarTypes: cts,
      frequencyCollection: fc,
      mahCollection: mc,
      rojCollection: rc,
      selectedFrequency: selectedFrequency,
      selectedMah: selectedMah,
      selectedRoj: selectedRoj,
      selectedYear: selectedYear,
      selectedCalendarType: selectedCalendarType,
      selectedDate: selectedDate,
      eventTitle: eventTitle,
      editorTitle: editorTitle,
    );
  }
}
