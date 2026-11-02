import 'package:flutter/material.dart';
import 'core/localization/app_localizations_pt_ao.dart';
import 'features/auth/screens/role_selection_onboarding_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const DeliveryApp());
}

class DeliveryApp extends StatelessWidget {
  const DeliveryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Delivery Ango_Ifood',
      debugShowCheckedModeBanner: false,
      locale: AppLocalizationsPtAo.locale,
      supportedLocales: const [
        AppLocalizationsPtAo.locale,
      ],
      localizationsDelegates: const [
        AppLocalizationsPtAoDelegate(),
      ],
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFFEA1D2C),
      ),
      home: const RoleSelectionOnboardingScreen(),
    );
  }
}

