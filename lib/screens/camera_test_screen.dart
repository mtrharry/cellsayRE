import 'dart:async';
import 'dart:ui';
import 'package:google_mlkit_commons/google_mlkit_commons.dart';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

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
  late final TextRecognizer _textRecognizer =
      TextRecognizer(script: TextRecognitionScript.latin);
  bool _isProcessingImage = false;
  bool _isAwaitingUserDecision = false;
  bool _isFrozenFrame = false;
  bool _textDetectionCooldown = false;
  bool _isStreamActive = false;
  bool _showPrompt = false;
  Timer? _cooldownTimer;
  _TextRecognitionSnapshot? _pendingSnapshot;
  _TextRecognitionSnapshot? _frozenSnapshot;
  String? _coherentRecognizedText;
  String? _lastPromptedText;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _prepareCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cooldownTimer?.cancel();
    unawaited(_textRecognizer.close());
    final controller = _controller;
    _controller = null;
    unawaited(_stopImageStream(controller));
    controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) {
      return;
    }

    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      final controller = _controller;
      _controller = null;
      _resetTextDetectionState();
      if (controller != null) {
        unawaited(_stopImageStream(controller));
        controller.dispose();
      }
      setState(() {
        // Fuerza la reconstrucción para mostrar mensajes de reinicio.
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
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420, // <--- forzamos YUV420
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
        _resetTextDetectionState();
      });
      await _stopImageStream(previousController);
      await previousController?.dispose();

      await _startImageStream(newController);
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

  void _resetTextDetectionState() {
    _pendingSnapshot = null;
    _frozenSnapshot = null;
    _coherentRecognizedText = null;
    _isAwaitingUserDecision = false;
    _isFrozenFrame = false;
    _textDetectionCooldown = false;
    _isProcessingImage = false;
    _isStreamActive = false;
    _showPrompt = false;
    _cooldownTimer?.cancel();
    _cooldownTimer = null;
    _lastPromptedText = null;
  }

  Future<void> _startImageStream(CameraController controller) async {
    if (!mounted || kIsWeb) {
      return;
    }
    if (!controller.value.isInitialized) {
      return;
    }
    if (controller.value.isStreamingImages) {
      if (!_isStreamActive && mounted) {
        setState(() {
          _isStreamActive = true;
        });
      }
      return;
    }

    try {
      await controller.startImageStream(_processCameraImage);
      if (!mounted) {
        await controller.stopImageStream();
        return;
      }
      setState(() {
        _isStreamActive = true;
      });
    } on CameraException catch (error) {
      debugPrint('No se pudo iniciar el stream de imágenes: $error');
      if (mounted) {
        setState(() {
          _isStreamActive = false;
        });
      }
    }
  }

  Future<void> _stopImageStream(CameraController? controller) async {
    if (controller == null || kIsWeb) {
      return;
    }
    if (!controller.value.isStreamingImages) {
      if (mounted && _isStreamActive) {
        setState(() {
          _isStreamActive = false;
        });
      } else {
        _isStreamActive = false;
      }
      return;
    }

    try {
      await controller.stopImageStream();
    } catch (error) {
      debugPrint('No se pudo detener el stream de imágenes: $error');
    }
    if (mounted) {
      setState(() {
        _isStreamActive = false;
      });
    } else {
      _isStreamActive = false;
    }
  }

  void _startDetectionCooldown() {
    _cooldownTimer?.cancel();
    _textDetectionCooldown = true;
    _cooldownTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) {
        _textDetectionCooldown = false;
        return;
      }
      setState(() {
        _textDetectionCooldown = false;
      });
    });
  }

  Future<void> _acceptTextAnalysis() async {
    if (!_isAwaitingUserDecision) {
      return;
    }

    final controller = _controller;
    final snapshot = _pendingSnapshot;
    setState(() {
      _showPrompt = false;
      _isAwaitingUserDecision = false;
    });

    if (controller == null || snapshot == null) {
      return;
    }

    await _stopImageStream(controller);
    try {
      if (controller.value.isInitialized &&
          !controller.value.isPreviewPaused) {
        await controller.pausePreview();
      }
    } catch (error) {
      debugPrint('No se pudo pausar la vista previa tras confirmar: $error');
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _frozenSnapshot = snapshot;
      _coherentRecognizedText = snapshot.normalizedText;
      _isFrozenFrame = true;
      _pendingSnapshot = null;
      _lastPromptedText = snapshot.normalizedText;
    });
  }

  void _dismissTextPrompt() {
    if (!_isAwaitingUserDecision) {
      return;
    }
    setState(() {
      _pendingSnapshot = null;
      _showPrompt = false;
      _isAwaitingUserDecision = false;
    });
    _startDetectionCooldown();
  }

  Future<void> _resumeTextDetection() async {
    final controller = _controller;
    if (controller == null) {
      return;
    }

    setState(() {
      _frozenSnapshot = null;
      _coherentRecognizedText = null;
      _isFrozenFrame = false;
      _lastPromptedText = null;
    });

    try {
      if (controller.value.isPreviewPaused) {
        await controller.resumePreview();
      }
    } catch (error) {
      debugPrint('No se pudo reanudar la vista previa: $error');
    }

    await _startImageStream(controller);
    _startDetectionCooldown();
  }

  Future<void> _processCameraImage(CameraImage image) async {
    if (_isProcessingImage ||
        _isAwaitingUserDecision ||
        _isFrozenFrame ||
        _textDetectionCooldown) {
      return;
    }

    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }

    _isProcessingImage = true;
    try {
      final rotation = InputImageRotationValue.fromRawValue(
            controller.description.sensorOrientation,
          ) ??
          InputImageRotation.rotation0deg;
      final inputImage = _buildInputImage(image, rotation);
      if (inputImage == null) {
        return;
      }

      final recognizedText = await _textRecognizer.processImage(inputImage);
      final normalizedText = _normalizeRecognizedText(recognizedText.text);

      if (normalizedText.isEmpty) {
        if (_pendingSnapshot != null && !_isAwaitingUserDecision && mounted) {
          setState(() {
            _pendingSnapshot = null;
          });
        }
        return;
      }

      if (_textDetectionCooldown) {
        return;
      }

      if (_lastPromptedText != null &&
          _lastPromptedText == normalizedText &&
          !_isFrozenFrame) {
        return;
      }

      final snapshot = _createSnapshot(
        recognizedText,
        Size(image.width.toDouble(), image.height.toDouble()),
        rotation,
        controller.description.lensDirection,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _pendingSnapshot = snapshot;
        _showPrompt = true;
        _isAwaitingUserDecision = true;
        _lastPromptedText = snapshot.normalizedText;
      });
    } catch (error) {
      debugPrint('Error al procesar la imagen para OCR: $error');
    } finally {
      _isProcessingImage = false;
    }
  }

  InputImage? _buildInputImage(CameraImage image, InputImageRotation rotation) {
    final WriteBuffer allBytes = WriteBuffer();
    for (final Plane plane in image.planes) {
      allBytes.putUint8List(plane.bytes);
    }
    final bytes = allBytes.done().buffer.asUint8List();

    final Size size = Size(
      image.width.toDouble(),
      image.height.toDouble(),
    );

    final format = (image.planes.length == 1)
        ? InputImageFormat.nv21
        : InputImageFormat.yuv420;

    return InputImage.fromBytes(
      bytes: bytes,
      metadata: InputImageMetadata(
        size: size,
        rotation: rotation,
        format: format,
        bytesPerRow: image.planes.first.bytesPerRow,
      ),
    );
  }






  String _normalizeRecognizedText(String text) {
    final normalizedLines = text
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    return normalizedLines.join('\n');
  }

  _TextRecognitionSnapshot _createSnapshot(
    RecognizedText recognizedText,
    Size imageSize,
    InputImageRotation rotation,
    CameraLensDirection lensDirection,
  ) {
    final lines = <_TextLineBox>[];
    for (final block in recognizedText.blocks) {
      for (final line in block.lines) {
        final normalized = _normalizeRecognizedText(line.text);
        if (normalized.isEmpty) {
          continue;
        }
        lines.add(
          _TextLineBox(
            text: normalized,
            boundingBox: line.boundingBox,
          ),
        );
      }
    }

    final normalizedText =
        _normalizeRecognizedText(recognizedText.text).trimRight();

    return _TextRecognitionSnapshot(
      lines: lines,
      normalizedText: normalizedText,
      imageSize: imageSize,
      rotation: rotation,
      lensDirection: lensDirection,
    );
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
                          showPrompt: _showPrompt,
                          onAcceptAnalysis: _acceptTextAnalysis,
                          onDismissPrompt: _dismissTextPrompt,
                          isFrozen: _isFrozenFrame,
                          frozenSnapshot: _frozenSnapshot,
                          recognizedText: _coherentRecognizedText,
                          onResumeDetection: _resumeTextDetection,
                          isStreamActive: _isStreamActive,
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
                        showPrompt: _showPrompt,
                        onAcceptAnalysis: _acceptTextAnalysis,
                        onDismissPrompt: _dismissTextPrompt,
                        isFrozen: _isFrozenFrame,
                        frozenSnapshot: _frozenSnapshot,
                        recognizedText: _coherentRecognizedText,
                        onResumeDetection: _resumeTextDetection,
                        isStreamActive: _isStreamActive,
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
    required this.showPrompt,
    required this.onAcceptAnalysis,
    required this.onDismissPrompt,
    required this.isFrozen,
    required this.frozenSnapshot,
    required this.recognizedText,
    required this.onResumeDetection,
    required this.isStreamActive,
  });

  final CameraController? controller;
  final bool isInitializing;
  final String? errorMessage;
  final Future<void> Function({int? cameraIndex, bool reuseExistingList}) onRetry;
  final bool showPrompt;
  final VoidCallback onAcceptAnalysis;
  final VoidCallback onDismissPrompt;
  final bool isFrozen;
  final _TextRecognitionSnapshot? frozenSnapshot;
  final String? recognizedText;
  final VoidCallback? onResumeDetection;
  final bool isStreamActive;

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
              if (isFrozen &&
                  controller != null &&
                  controller!.value.isInitialized &&
                  frozenSnapshot != null)
                Positioned.fill(
                  child: IgnorePointer(
                    ignoring: true,
                    child: CustomPaint(
                      painter: _TextBoxesPainter(
                        snapshot: frozenSnapshot!,
                      ),
                    ),
                  ),
                ),
              if (!isStreamActive &&
                  !isFrozen &&
                  controller != null &&
                  controller!.value.isInitialized &&
                  errorMessage == null &&
                  !isInitializing)
                const Positioned(
                  top: 16,
                  right: 16,
                  child: _DetectionStatusPill(
                    label: 'Inicializando OCR...',
                  ),
                ),
              if (isInitializing)
                const Align(
                  alignment: Alignment.center,
                  child: CircularProgressIndicator(color: Colors.white),
                ),
              if (showPrompt)
                Positioned(
                  left: 24,
                  right: 24,
                  bottom: 32,
                  child: _AnalysisPromptOverlay(
                    onAccept: onAcceptAnalysis,
                    onDismiss: onDismissPrompt,
                  ),
                ),
              if (isFrozen && recognizedText != null)
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 24,
                  child: _FrozenTextPanel(
                    text: recognizedText!,
                    onResumeDetection: onResumeDetection,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DetectionStatusPill extends StatelessWidget {
  const _DetectionStatusPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.7),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: Theme.of(context)
            .textTheme
            .labelMedium
            ?.copyWith(color: Colors.white),
      ),
    );
  }
}

class _AnalysisPromptOverlay extends StatelessWidget {
  const _AnalysisPromptOverlay({
    required this.onAccept,
    required this.onDismiss,
  });

  final VoidCallback onAccept;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Semantics(
      liveRegion: true,
      label: 'Se ha detectado texto en pantalla',
      child: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(20),
        color: Colors.black.withOpacity(0.85),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'He detectado texto. ¿Quieres analizarlo?',
                style: textTheme.titleMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Si aceptas, congelaré el fotograma actual y podrás revisar el contenido con calma.',
                style: textTheme.bodyMedium?.copyWith(color: Colors.white70),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: onAccept,
                      icon: const Icon(Icons.visibility),
                      label: const Text('Analizar texto'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onDismiss,
                      icon: const Icon(Icons.close),
                      label: const Text('Ignorar'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white70),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FrozenTextPanel extends StatelessWidget {
  const _FrozenTextPanel({
    required this.text,
    required this.onResumeDetection,
  });

  final String text;
  final VoidCallback? onResumeDetection;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Material(
      elevation: 10,
      borderRadius: BorderRadius.circular(20),
      color: Colors.black.withOpacity(0.85),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Texto reconocido',
              style: textTheme.titleMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 200),
              child: SingleChildScrollView(
                child: Text(
                  text,
                  style: textTheme.bodyMedium?.copyWith(
                    color: Colors.white70,
                    height: 1.3,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onResumeDetection,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Reanudar captura'),
            ),
          ],
        ),
      ),
    );
  }
}

class _TextBoxesPainter extends CustomPainter {
  _TextBoxesPainter({required this.snapshot});

  final _TextRecognitionSnapshot snapshot;

  @override
  void paint(Canvas canvas, Size size) {
    if (snapshot.lines.isEmpty) {
      return;
    }

    if (snapshot.lensDirection == CameraLensDirection.front) {
      canvas.translate(size.width, 0);
      canvas.scale(-1, 1);
    }

    final borderPaint = Paint()
      ..color = const Color(0xFFFFC857)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    final fillPaint = Paint()
      ..color = const Color(0xFFFFC857).withOpacity(0.25)
      ..style = PaintingStyle.fill;

    for (final line in snapshot.lines) {
      final transformed = _transformRect(line.boundingBox, size);
      canvas.drawRRect(
        RRect.fromRectAndRadius(transformed, const Radius.circular(12)),
        fillPaint,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(transformed, const Radius.circular(12)),
        borderPaint,
      );
    }
  }

  Rect _transformRect(Rect rect, Size size) {
    final imageSize = snapshot.imageSize;

    switch (snapshot.rotation) {
      case InputImageRotation.rotation90deg:
        final scaleX = size.width / imageSize.height;
        final scaleY = size.height / imageSize.width;
        final left = size.width - rect.bottom * scaleX;
        final top = rect.left * scaleY;
        final right = size.width - rect.top * scaleX;
        final bottom = rect.right * scaleY;
        return Rect.fromLTRB(left, top, right, bottom);
      case InputImageRotation.rotation270deg:
        final scaleX = size.width / imageSize.height;
        final scaleY = size.height / imageSize.width;
        final left = rect.top * scaleX;
        final top = size.height - rect.right * scaleY;
        final right = rect.bottom * scaleX;
        final bottom = size.height - rect.left * scaleY;
        return Rect.fromLTRB(left, top, right, bottom);
      case InputImageRotation.rotation180deg:
        final scaleX = size.width / imageSize.width;
        final scaleY = size.height / imageSize.height;
        final left = size.width - rect.right * scaleX;
        final top = size.height - rect.bottom * scaleY;
        final right = size.width - rect.left * scaleX;
        final bottom = size.height - rect.top * scaleY;
        return Rect.fromLTRB(left, top, right, bottom);
      case InputImageRotation.rotation0deg:
      default:
        final scaleX = size.width / imageSize.width;
        final scaleY = size.height / imageSize.height;
        return Rect.fromLTRB(
          rect.left * scaleX,
          rect.top * scaleY,
          rect.right * scaleX,
          rect.bottom * scaleY,
        );
    }
  }

  @override
  bool shouldRepaint(covariant _TextBoxesPainter oldDelegate) {
    return oldDelegate.snapshot != snapshot;
  }
}

class _TextRecognitionSnapshot {
  const _TextRecognitionSnapshot({
    required this.lines,
    required this.normalizedText,
    required this.imageSize,
    required this.rotation,
    required this.lensDirection,
  });

  final List<_TextLineBox> lines;
  final String normalizedText;
  final Size imageSize;
  final InputImageRotation rotation;
  final CameraLensDirection lensDirection;
}

class _TextLineBox {
  const _TextLineBox({required this.text, required this.boundingBox});

  final String text;
  final Rect boundingBox;
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
