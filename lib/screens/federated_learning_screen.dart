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
  State<FederatedLearningScreen> createState() => _FederatedLearningScreenState();
}

class _FederatedLearningScreenState extends State<FederatedLearningScreen> {
  // WebSocket for presence/live-tracking
  final String _presenceServerUrl = 'ws://192.168.1.86:3001';
  WebSocketChannel? _presenceChannel;

  // State variables
  bool _isTraining = false;
  double _progress = 0.0;
  String _statusMessage = 'Initializing...';
  String? _currentModelCID; // Holds the model CID for the current round

  @override
  void initState() {
    super.initState();
    _initializeServices();
  }

  Future<void> _initializeServices() async {
    // Initialize the contract service
    await ContractService.initialize();
    
    // Listen for new training rounds from the smart contract
    ContractService().newRoundStartedStream.listen((eventData) {
      // Assuming event format: [campaignId, round, initialModelCID]
      final String initialModelCID = eventData[2];
      setState(() {
        _currentModelCID = initialModelCID;
        _statusMessage = 'New round started. Ready to train.';
      });
    });

    setState(() {
      _statusMessage = 'Waiting for new training round...';
    });
    
    // Connect to presence server
    _connectToPresenceServer();
  }

  void _connectToPresenceServer() {
    try {
      _presenceChannel = WebSocketChannel.connect(Uri.parse(_presenceServerUrl));
      _presenceChannel!.sink.add(jsonEncode({
        'type': 'node_online',
        'address': WalletService.getCurrentWalletAddress() ?? 'unknown',
      }));
    } catch (e) {
      print("Failed to connect to presence server: $e");
    }
  }

  void _startTrainingAndSubmission() async {
    // 1. Check for wallet and current round
    final walletAddress = WalletService.getCurrentWalletAddress();
    if (walletAddress == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please connect your wallet first.')),
      );
      return;
    }
    if (_currentModelCID == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No active training round.')),
      );
      return;
    }

    setState(() {
      _isTraining = true;
      _progress = 0.0;
      _statusMessage = 'Training with model: $_currentModelCID';
    });

    // 2. Simulate the training process
    // In a real app, you would download the model from IPFS using the CID,
    // train it, and then upload the new model to get a new CID.
    await Future.delayed(const Duration(seconds: 5), () {
      setState(() {
        _progress = 1.0;
        _statusMessage = 'Training complete. Submitting model...';
      });
    });

    // 3. Submit the new model CID to the smart contract
    try {
      // We'll use a placeholder for the new CID
      const String newModelCid = 'new_trained_model_cid_placeholder';
      
      // We need credentials to sign. This part depends heavily on how Reown AppKit
      // exposes the private key or a signing method. This is a conceptual example.
      // You would replace this with the actual signing method from your wallet service.
      final credentials = EthPrivateKey.fromHex('YOUR_PRIVATE_KEY_PLACEHOLDER'); // IMPORTANT: DO NOT HARDCODE KEYS
      
      final txHash = await ContractService.submitModel(newModelCid, credentials);
      
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
  void dispose() {
    _presenceChannel?.sink.close(); // Close presence connection
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
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
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