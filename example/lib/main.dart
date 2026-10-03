import 'package:flutter/material.dart';
import 'package:orca_secure_storage/orca_secure_storage.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await OrcaSecureStorage.init(password: 'strongpassword');
  runApp(const App());
}

class App extends StatefulWidget {
  const App({Key? key}) : super(key: key);

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> {
  final box = OrcaSecureStorage();

  @override
  void initState() {
    super.initState();
  }

  String get lastupdated => box.read('lastupdated') ?? 'never';

  bool get isDark => box.read('darkmode') ?? false;

  void changeTheme(bool val) {
    box.write('darkmode', val);
    box.write('lastupdated', DateTime.now().toLocal().toString());
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: isDark ? ThemeData.dark() : ThemeData.light(),
      home: Scaffold(
        appBar: AppBar(title: const Text("OrcaSecureStorage")),
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Spacer(flex: 1),
            Flexible(
              flex: 3,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SwitchListTile(
                    value: isDark,
                    title: const Text("Touch to change ThemeMode"),
                    onChanged: changeTheme,
                  ),
                  const SizedBox(height: 10),
                  Text('Last updated: $lastupdated')
                ],
              ),
            ),
            const Spacer(flex: 1),
          ],
        ),
      ),
    );
  }
}
