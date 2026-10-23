import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../sync_engine/sync_transport.dart';

class ScanPairPage extends StatefulWidget {
  const ScanPairPage({super.key});
  @override
  State<ScanPairPage> createState() => _ScanPairPageState();
}

class _ScanPairPageState extends State<ScanPairPage>
    with WidgetsBindingObserver {
  final _camera = MobileScannerController(
    autoStart: false,
    formats: [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _handled = false;
  String? _message;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      await _camera.start();
    } catch (_) {
      if (mounted) setState(() => _message = '请在系统设置中允许相机权限，再重新进入扫码');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_camera.value.hasCameraPermission || _handled) return;
    if (state == AppLifecycleState.resumed) {
      unawaited(_start());
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      unawaited(_camera.stop());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_camera.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(title: const Text('扫描电脑二维码')),
    body: Stack(
      children: [
        MobileScanner(
          controller: _camera,
          onDetect: (capture) {
            if (_handled) return;
            final raw = capture.barcodes.firstOrNull?.rawValue;
            if (raw == null) return;
            try {
              final ticket = PairTicket.parse(raw);
              _handled = true;
              unawaited(_camera.stop());
              Navigator.of(context).pop(ticket);
            } catch (_) {
              setState(() => _message = '请扫描素若阅读电脑端当前展示的有效二维码');
            }
          },
          errorBuilder: (context, error) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.no_photography_outlined,
                    color: Colors.white,
                    size: 48,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    '无法使用摄像头，请检查相机权限后重试',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white),
                  ),
                  TextButton(onPressed: _start, child: const Text('重试')),
                ],
              ),
            ),
          ),
        ),
        IgnorePointer(
          child: Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 2),
                borderRadius: BorderRadius.circular(18),
              ),
            ),
          ),
        ),
        Positioned(
          left: 24,
          right: 24,
          bottom: 48,
          child: Text(
            _message ?? '打开电脑“设置 → 设备互联 → 二维码展示”，将二维码放入取景框',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              height: 1.6,
            ),
          ),
        ),
      ],
    ),
  );
}
