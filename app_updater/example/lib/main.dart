import 'package:app_updater/app_updater.dart';
import 'package:flutter/material.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  AppUpdater.instance.autoUpdate(
    baseUrl: 'http://localhost:8080',
    appSlug: 'app_updater-updater-example-android',
  );
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  OtaRuntimeStatus? _status;

  @override
  void initState() {
    super.initState();
    _refreshStatus();
  }

  Future<void> _refreshStatus() async {
    final status = await AppUpdater.instance.status();
    if (!mounted) return;
    setState(() => _status = status);
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('app_updater example')),
        body: Center(
          child: Text(
            status == null
                ? 'Loading status...'
                : 'state=${status.state} patch=${status.patchNumber}',
          ),
        ),
      ),
    );
  }
}
