import 'package:flutter/material.dart';

import 'screens/camera_test_screen.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CellSay',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey),
        useMaterial3: true,
      ),
      home: const HomeMenuScreen(),
    );
  }
}

class HomeMenuScreen extends StatelessWidget {
  const HomeMenuScreen({super.key});

  void _showComingSoon(BuildContext context, String featureName) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text('$featureName estará disponible pronto.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final buttons = <_FeatureButtonData>[
      const _FeatureButtonData(
        label: 'Detección de objetos',
        hint: 'Toca dos veces para abrir la detección de objetos.',
        icon: Icons.remove_red_eye,
      ),
      const _FeatureButtonData(
        label: 'Detección de texto',
        hint: 'Toca dos veces para leer textos y carteles.',
        icon: Icons.text_fields,
      ),
      const _FeatureButtonData(
        label: 'Detección de dinero',
        hint: 'Toca dos veces para identificar billetes y monedas.',
        icon: Icons.attach_money,
      ),
      _FeatureButtonData(
        label: 'Probar cámara',
        hint: 'Toca dos veces para revisar el funcionamiento de la cámara.',
        icon: Icons.photo_camera,
        action: (context) {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const CameraTestScreen(),
            ),
          );
        },
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('CellSay'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                label:
                    'Bienvenido a CellSay. Aplicación de apoyo para personas con discapacidad visual.',
                child: Text(
                  'Bienvenido a CellSay',
                  style: Theme.of(context)
                      .textTheme
                      .headlineMedium
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Selecciona una función para comenzar. Todas las opciones están optimizadas para TalkBack.',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 24),
              Expanded(
                child: ListView.separated(
                  itemCount: buttons.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 16),
                  itemBuilder: (context, index) {
                    final data = buttons[index];
                    return Semantics(
                      button: true,
                      label: data.label,
                      hint: data.hint,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          minimumSize: const Size.fromHeight(72),
                          alignment: Alignment.centerLeft,
                          textStyle: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontSize: 20),
                        ),
                        onPressed: () {
                          final action = data.action;
                          if (action != null) {
                            action(context);
                          } else {
                            _showComingSoon(context, data.label);
                          }
                        },
                        icon: Icon(data.icon, size: 32),
                        label: Text(data.label),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FeatureButtonData {
  const _FeatureButtonData({
    required this.label,
    required this.hint,
    required this.icon,
    this.action,
  });

  final String label;
  final String hint;
  final IconData icon;
  final void Function(BuildContext context)? action;
}
