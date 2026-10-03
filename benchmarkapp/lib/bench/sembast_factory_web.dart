import 'package:sembast_web/sembast_web.dart';

Future<Database> openSembast(String name) =>
    databaseFactoryWeb.openDatabase(name);
