// lib/screens/federated_learning_screen.dart

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:mobile_pione/services/contract_service.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web3dart/web3dart.dart'; // Import web3dart
import '../services/wallet_service.dart';

class FederatedLearningScreen extends StatefulWidget {
  const FederatedLearningScreen({super.key});

  @override
  State<FederatedLearningScreen> createState() =>
      _FederatedLearningScreenState();
}

class _FederatedLearningScreenState extends State<FederatedLearningScreen> {
  // WebSocket for presence/live-tracking
  final String _presenceServerUrl = 'ws://192.168.1.250:3001';
  WebSocketChannel? _presenceChannel;

  // State variables
  bool _isTraining = false;
  double _progress = 0.0;
  String _statusMessage = 'Initializing...';
  String? _currentModelCIDForTraining; // Renamed for clarity
  // NEW: State variables for displaying the global model
  bool _isLoadingModel = true;
  String? _globalModelCID;

  @override
  void initState() {
    super.initState();
    _initializeServices();
  }

  Future<void> _initializeServices() async {
    // Initialize the contract service
    setState(() {
      _statusMessage = 'Initializing services...';
    });
    await ContractService.initialize();
    _fetchCurrentModel(); // NEW: Fetch model on init
  }

  // NEW: Method to fetch the current global model from the contract
  Future<void> _fetchCurrentModel() async {
    setState(() {
      _isLoadingModel = true;
      _statusMessage = 'Fetching current global model...';
    });
    try {
      final cid = await ContractService.getCurrentGlobalModel();
      setState(() {
        _globalModelCID = cid;
        _isLoadingModel = false;
        _statusMessage = cid != null
            ? 'Ready to train.'
            : 'No active campaign found.';
      });
    } catch (e) {
      setState(() {
        _isLoadingModel = false;
        _statusMessage = 'Failed to fetch model.';
      });
    }
  }

  void _connectToPresenceServer() {
    try {
      _presenceChannel = WebSocketChannel.connect(
        Uri.parse(_presenceServerUrl),
      );
      _presenceChannel!.sink.add(
        jsonEncode({
          'type': 'register_node',
          'address': WalletService.getCurrentWalletAddress() ?? 'unknown',
        }),
      );
    } catch (e) {
      print("Failed to connect to presence server: $e");
    }
  }

  void _startTrainingAndSubmission() async {
    _connectToPresenceServer();
    ContractService().newRoundStartedStream.listen((eventData) {
      final String initialModelCID = eventData[2];
      setState(() {
        _currentModelCIDForTraining = initialModelCID;
        _statusMessage = 'New round started. Ready to train.';
      });
    });

    setState(() {
      _statusMessage = 'Waiting for new training round...';
    });

    final walletAddress = WalletService.getCurrentWalletAddress();
    if (walletAddress == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please connect your wallet first.')),
      );
      return;
    }
    if (_currentModelCIDForTraining == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No active training round.')),
      );
      return;
    }

    setState(() {
      _isTraining = true;
      _progress = 0.0;
      _statusMessage = 'Training with model: $_currentModelCIDForTraining';
    });

    await Future.delayed(const Duration(seconds: 5), () {
      setState(() {
        _progress = 1.0;
        _statusMessage = 'Training complete. Submitting model...';
      });
    });

    try {
      const String newModelCid = 'new_trained_model_cid_placeholder';
      final credentials = EthPrivateKey.fromHex('YOUR_PRIVATE_KEY_PLACEHOLDER');
      final txHash = await ContractService.submitModel(
        newModelCid,
        credentials,
      );
      setState(() {
        _statusMessage = 'Model submitted! Tx: $txHash';
        _isTraining = false;
      });
    } catch (e) {
      setState(() {
        _statusMessage = 'Error submitting model: $e';
        _isTraining = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Federated Learning')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // NEW: Widget to display the current global model
              Card(
                elevation: 2,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Current Global Model',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (_isLoadingModel)
                        const Row(
                          children: [
                            SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 3),
                            ),
                            SizedBox(width: 16),
                            Text('Fetching from blockchain...'),
                          ],
                        )
                      else
                        SelectableText(
                          _globalModelCID ?? 'N/A (No active campaign)',
                          style: TextStyle(
                            fontFamily: 'monospace',
                            color: _globalModelCID != null
                                ? Colors.green.shade700
                                : Colors.grey,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 40),
              if (_isTraining) LinearProgressIndicator(value: _progress),
              const SizedBox(height: 20),
              Text(_statusMessage, textAlign: TextAlign.center),
              const SizedBox(height: 30),
              ElevatedButton(
                onPressed: _isTraining ? null : _startTrainingAndSubmission,
                child: Text(_isTraining ? 'Training...' : 'Start Training'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
