import 'dart:async';

import 'package:flutter/material.dart';

class FederatedLearningScreen extends StatefulWidget {
  const FederatedLearningScreen({super.key});

  @override
  State<FederatedLearningScreen> createState() => _FederatedLearningScreenState();
}

class _FederatedLearningScreenState extends State<FederatedLearningScreen> with AutomaticKeepAliveClientMixin {
  double _progress = 0.0;
  bool _isRunning = false;
  Timer? _timer;
  @override
  bool get wantKeepAlive => true;

  void _startFederatedLearning() {
    if (_isRunning) return;
    setState(() {
      _isRunning = true;
      _progress = 0.0;
    });

    _timer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      setState(() {
        _progress += 0.05;
        if (_progress >= 1.0) {
          _progress = 1.0;
          _isRunning = false;
          timer.cancel();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Federated learning completed')),
          );
        }
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Federated Learning')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: _progress),
              const SizedBox(height: 16),
              Text('${(_progress * 100).toStringAsFixed(0)}%'),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _startFederatedLearning,
                child: Text(_isRunning ? 'Running...' : 'Start Federated Learning'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
