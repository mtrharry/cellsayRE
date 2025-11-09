import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

class CameraTestScreen extends StatefulWidget {
  const CameraTestScreen({super.key});

  @override
  State<CameraTestScreen> createState() => _CameraTestScreenState();
}

class _CameraTestScreenState extends State<CameraTestScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  List<CameraDescription> _availableCameras = const [];
  int _selectedCameraIndex = 0;
  bool _isInitializing = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _prepareCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) {
      return;
    }

    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      _controller?.dispose();
      setState(() {
        _controller = null;
      });
    } else if (state == AppLifecycleState.resumed) {
      _prepareCamera(cameraIndex: _selectedCameraIndex, reuseExistingList: true);
    }
  }

  Future<void> _prepareCamera({int? cameraIndex, bool reuseExistingList = false}) async {
    if (!mounted) {
      return;
    }

    setState(() {
      _isInitializing = true;
      _errorMessage = null;
    });

    try {
      final cameras = reuseExistingList && _availableCameras.isNotEmpty
          ? _availableCameras
          : await availableCameras();

      if (cameras.isEmpty) {
        setState(() {
          _errorMessage =
              'No se encontraron cámaras disponibles en este dispositivo.';
        });
        return;
      }

      final nextIndex = cameraIndex ?? _chooseBestCameraIndex(cameras);
      var boundedIndex = nextIndex;
      if (boundedIndex < 0) {
        boundedIndex = 0;
      } else if (boundedIndex >= cameras.length) {
        boundedIndex = cameras.length - 1;
      }
      final selectedCamera = cameras[boundedIndex];

      final newController = CameraController(
        selectedCamera,
        ResolutionPreset.high,
        enableAudio: false,
      );

      await newController.initialize();
      if (!mounted) {
        await newController.dispose();
        return;
      }

      final previousController = _controller;
      setState(() {
        _availableCameras = cameras;
        _selectedCameraIndex = boundedIndex;
        _controller = newController;
      });
      await previousController?.dispose();
    } on CameraException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage =
            'Ocurrió un problema al iniciar la cámara: ${error.description ?? error.code}.';
      });
    } finally {
      if (!mounted) {
        return;
      }
      setState(() {
        _isInitializing = false;
      });
    }
  }

  int _chooseBestCameraIndex(List<CameraDescription> cameras) {
    final backIndex =
        cameras.indexWhere((camera) => camera.lensDirection == CameraLensDirection.back);
    if (backIndex != -1) {
      return backIndex;
    }

    final externalIndex = cameras
        .indexWhere((camera) => camera.lensDirection == CameraLensDirection.external);
    if (externalIndex != -1) {
      return externalIndex;
    }

    return 0;
  }

  Future<void> _switchCamera() async {
    if (_availableCameras.length < 2) {
      return;
    }

    final nextIndex = (_selectedCameraIndex + 1) % _availableCameras.length;
    await _prepareCamera(cameraIndex: nextIndex, reuseExistingList: true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Probar cámara'),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF0B2545), Color(0xFF1B4965)],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final isPortrait = constraints.maxWidth < constraints.maxHeight;

                if (isPortrait) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        flex: 3,
                        child: _CameraPreviewArea(
                          controller: _controller,
                          isInitializing: _isInitializing,
                          errorMessage: _errorMessage,
                          onRetry: _prepareCamera,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Expanded(
                        flex: 2,
                        child: _CameraInfoPanel(
                          theme: theme,
                          cameraCount: _availableCameras.length,
                          canSwitchCamera: _availableCameras.length > 1,
                          onSwitchCamera: _switchCamera,
                          onRetry: _prepareCamera,
                          isInitializing: _isInitializing,
                        ),
                      ),
                    ],
                  );
                }

                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      flex: 5,
                      child: _CameraPreviewArea(
                        controller: _controller,
                        isInitializing: _isInitializing,
                        errorMessage: _errorMessage,
                        onRetry: _prepareCamera,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      flex: 4,
                      child: _CameraInfoPanel(
                        theme: theme,
                        cameraCount: _availableCameras.length,
                        canSwitchCamera: _availableCameras.length > 1,
                        onSwitchCamera: _switchCamera,
                        onRetry: _prepareCamera,
                        isInitializing: _isInitializing,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _CameraPreviewArea extends StatelessWidget {
  const _CameraPreviewArea({
    required this.controller,
    required this.isInitializing,
    required this.errorMessage,
    required this.onRetry,
  });

  final CameraController? controller;
  final bool isInitializing;
  final String? errorMessage;
  final Future<void> Function({int? cameraIndex, bool reuseExistingList}) onRetry;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Vista previa de la cámara',
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          boxShadow: const [
            BoxShadow(
              color: Colors.black26,
              blurRadius: 24,
              offset: Offset(0, 12),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Container(color: Colors.black87),
              if (controller != null && controller!.value.isInitialized)
                CameraPreview(controller!)
              else if (errorMessage != null)
                _CameraMessage(
                  icon: Icons.error_outline,
                  message: errorMessage!,
                  actionLabel: 'Reintentar',
                  onAction: () => onRetry(reuseExistingList: true),
                )
              else
                const _CameraMessage(
                  icon: Icons.photo_camera,
                  message:
                      'Preparando la cámara...\nAsegúrate de otorgar permisos si el sistema los solicita.',
                ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        Colors.black.withOpacity(0.75),
                        Colors.black.withOpacity(0.0),
                      ],
                    ),
                  ),
                  child: const Text(
                    'Mantén el dispositivo estable y apunta al elemento que quieras revisar.',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              if (isInitializing)
                const Align(
                  alignment: Alignment.center,
                  child: CircularProgressIndicator(color: Colors.white),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CameraInfoPanel extends StatelessWidget {
  const _CameraInfoPanel({
    required this.theme,
    required this.cameraCount,
    required this.canSwitchCamera,
    required this.onSwitchCamera,
    required this.onRetry,
    required this.isInitializing,
  });

  final ThemeData theme;
  final int cameraCount;
  final bool canSwitchCamera;
  final VoidCallback onSwitchCamera;
  final Future<void> Function({int? cameraIndex, bool reuseExistingList}) onRetry;
  final bool isInitializing;

  @override
  Widget build(BuildContext context) {
    final textTheme = theme.textTheme;
    final hasMultipleCameras = cameraCount > 1;

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      color: Colors.white.withOpacity(0.92),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Vista previa en vivo',
              style: textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: const Color(0xFF0B2545),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Utiliza este modo para comprobar rápidamente si la cámara de tu dispositivo funciona correctamente.',
              style: textTheme.bodyMedium?.copyWith(color: const Color(0xFF1B4965)),
            ),
            const SizedBox(height: 16),
            const _BulletPoint(
              icon: Icons.brightness_6,
              text:
                  'Si la imagen se ve oscura, mueve el dispositivo hacia un lugar mejor iluminado.',
            ),
            const SizedBox(height: 12),
            const _BulletPoint(
              icon: Icons.center_focus_strong,
              text: 'Acerca o aleja el dispositivo hasta que el objeto se vea nítido.',
            ),
            const SizedBox(height: 12),
            const _BulletPoint(
              icon: Icons.volume_up,
              text:
                  'Activa TalkBack o VoiceOver para recibir ayuda auditiva al explorar la pantalla.',
            ),
            const Spacer(),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                if (canSwitchCamera)
                  FilledButton.icon(
                    onPressed: isInitializing ? null : onSwitchCamera,
                    icon: const Icon(Icons.cameraswitch),
                    label: const Text('Cambiar cámara'),
                  ),
                FilledButton.icon(
                  onPressed: isInitializing
                      ? null
                      : () => onRetry(cameraIndex: null, reuseExistingList: false),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Reiniciar vista previa'),
                ),
                FilledButton.icon(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('Volver'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              hasMultipleCameras
                  ? 'Consejo: alterna entre las cámaras disponibles para elegir la que ofrezca mejor ángulo.'
                  : 'Este dispositivo reporta una única cámara disponible.',
              style: textTheme.bodySmall?.copyWith(color: const Color(0xFF0F4C75)),
            ),
          ],
        ),
      ),
    );
  }
}

class _BulletPoint extends StatelessWidget {
  const _BulletPoint({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: const Color(0xFF1B4965)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: const Color(0xFF102A43)),
          ),
        ),
      ],
    );
  }
}

class _CameraMessage extends StatelessWidget {
  const _CameraMessage({
    required this.icon,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      color: Colors.black.withOpacity(0.6),
      padding: const EdgeInsets.all(24),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 48),
          const SizedBox(height: 16),
          Text(
            message,
            textAlign: TextAlign.center,
            style: textTheme.bodyLarge?.copyWith(color: Colors.white),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 20),
            FilledButton(
              onPressed: onAction,
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black87,
              ),
              child: Text(actionLabel!),
            ),
          ],
        ],
      ),
    );
  }
}
