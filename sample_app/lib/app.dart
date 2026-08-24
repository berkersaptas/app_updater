import 'package:app_updater/app_updater.dart';
import 'package:flutter/material.dart';

Future<void> startApp(String message, {bool reportBootSuccess = true}) async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(OtaDemoApp(message: message));

  if (!reportBootSuccess) return;

  // baseUrl/appSlug come from ../app_updater.yaml (baked in at build time) — nothing to pass
  // here. See app_updater/README.md.
  AppUpdater.instance.autoUpdate(
    onResult: (result) => debugPrint('app_updater: $result'),
    onError: (error) => debugPrint('app_updater: $error'),
  );
}

class OtaDemoApp extends StatelessWidget {
  const OtaDemoApp({required this.message, super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: Text(message, style: const TextStyle(fontSize: 32)),
        ),
      ),
    );
  }
}
