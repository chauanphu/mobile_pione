// lib/screens/federated_learning_screen.dart

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:mobile_pione/services/contract_service.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
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

  // NEW: State variables for campaign and round tracking
  BigInt? _activeCampaignId;
  BigInt? _currentRound;

  // WebSocket connection status
  bool _isPresenceConnected = false;
  
  // Track stream subscriptions for cancellation
  dynamic _roundStreamSubscription;

  @override
  void initState() {
    super.initState();
    _initializeServices();
  }

  @override
  void dispose() {
    // Cancel stream subscription and disconnect websocket on screen dispose
    _roundStreamSubscription?.cancel();
    _disconnectPresenceServer();
    super.dispose();
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
      final activeId = await ContractService.getActiveCampaignId();
      final cid = await ContractService.getCurrentGlobalModel();
      Map<String, dynamic>? details;
      if (activeId != BigInt.zero) {
        details = await ContractService.getCampaignDetails(activeId);
      }
      setState(() {
        _activeCampaignId = activeId != BigInt.zero ? activeId : null;
        _currentRound = details != null ? BigInt.from(details['currentRound'] as int) : null;
        _globalModelCID = cid;
        _isLoadingModel = false;
        if (activeId == BigInt.zero) {
          _statusMessage = 'No active campaign found.';
        } else if ((cid ?? '').isEmpty) {
          _statusMessage = 'Active campaign found. Waiting for global model...';
        } else {
          _statusMessage = 'Ready to train.';
        }
      });
    } catch (e) {
      setState(() {
        _isLoadingModel = false;
        _statusMessage = 'Failed to fetch model.';
      });
    }
  }

  void _connectToPresenceServer() {
    // Avoid establishing a new connection if already connected
    if (_isPresenceConnected && _presenceChannel != null) {
      debugPrint("Already connected to presence server");
      return;
    }

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
      setState(() {
        _isPresenceConnected = true;
      });
      debugPrint("Connected to presence server");
    } catch (e) {
      debugPrint("Failed to connect to presence server: $e");
      setState(() {
        _isPresenceConnected = false;
      });
    }
  }

  void _disconnectPresenceServer() {
    try {
      _presenceChannel?.sink.close();
      _presenceChannel = null;
      setState(() {
        _isPresenceConnected = false;
      });
      debugPrint("Disconnected from presence server");
    } catch (e) {
      debugPrint("Error disconnecting from presence server: $e");
    }
  }

  void _startTrainingAndSubmission() async {
    final walletAddress = WalletService.getCurrentWalletAddress();
    if (walletAddress == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please connect your wallet first.')),
      );
      return;
    }

    _connectToPresenceServer();

    // Listen to NewRoundStarted events
    _roundStreamSubscription = ContractService().newRoundStartedStream.listen(
      (eventData) {
        // Event structure: [campaignId, roundNumber, initialModelCID, ...]
        if (eventData.length >= 3) {
          final BigInt campaignId = eventData[0] as BigInt;
          final BigInt roundNumber = eventData[1] as BigInt;
          final String initialModelCID = eventData[2] as String;

          setState(() {
            _activeCampaignId = campaignId;
            _currentRound = roundNumber;
            _currentModelCIDForTraining = initialModelCID;
            _statusMessage =
                'New round started (Campaign $campaignId, Round $roundNumber).';
          });

          // Automatically start training after receiving the event
          _performTrainingAndSubmission(initialModelCID, walletAddress);
        }
      },
      onError: (error) {
        setState(() {
          _statusMessage = 'Error listening to events: $error';
          _isTraining = false;
        });
      },
    );

    setState(() {
      _statusMessage = _isPresenceConnected
          ? 'Listening for submission event...'
          : 'Waiting for new training round...';
      _isTraining = true;
    });
  }

  void _cancelTraining() {
    // Cancel the round stream subscription
    _roundStreamSubscription?.cancel();
    _roundStreamSubscription = null;
    
    // Disconnect from presence server
    _disconnectPresenceServer();
    
    setState(() {
      _isTraining = false;
      _progress = 0.0;
      _statusMessage = 'Training cancelled. Ready to join training again.';
      _currentModelCIDForTraining = null;
    });
  }

  Future<void> _performTrainingAndSubmission(
    String modelCID,
    String walletAddress,
  ) async {
    setState(() {
      _isTraining = true;
      _progress = 0.0;
      _statusMessage = 'Training with model: $modelCID';
    });

    try {
      // Simulate training process (5 seconds)
      await Future.delayed(const Duration(seconds: 5), () {
        setState(() {
          _progress = 1.0;
          _statusMessage = 'Training complete. Preparing submission...';
        });
      });

      // Generate a trained model CID
      // In production, this would be the IPFS CID of the uploaded model weights
      final newModelCid = 'trained_model_${DateTime.now().millisecondsSinceEpoch}';

      setState(() {
        _statusMessage =
            'Model trained: $newModelCid\n\n'
            'Campaign: ${_activeCampaignId ?? "N/A"}\n'
            'Round: ${_currentRound ?? "N/A"}\n\n'
            'Submitting to smart contract...';
      });

      // Submit the model to the smart contract
      final txHash = await ContractService.submitModelWithWallet(
        newModelCid,
        walletAddress,
      );

      setState(() {
        _statusMessage =
            'Model Submission Successful!\n\n'
            'Model CID: $newModelCid\n'
            'Campaign: ${_activeCampaignId ?? "N/A"}\n'
            'Round: ${_currentRound ?? "N/A"}\n\n'
            'Transaction Hash: $txHash\n\n'
            'Waiting for next round...';
        _isTraining = false;
      });

      // Show success snackbar
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Model submitted successfully!'),
            duration: Duration(seconds: 2),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      debugPrint('Error during training and submission: $e');
      
      setState(() {
        _statusMessage =
            'Error during submission:\n\n'
            '$e\n\n'
            'Please try again or check your wallet connection.';
        _isTraining = false;
      });

      // Show error snackbar
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            duration: const Duration(seconds: 3),
            backgroundColor: Colors.red,
          ),
        );
      }
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
              const SizedBox(height: 20),
              // NEW: Display campaign and round information
              if (_activeCampaignId != null && _currentRound != null)
                Card(
                  color: Colors.blue.shade50,
                  child: Padding(
                    padding: const EdgeInsets.all(12.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Campaign: ${_activeCampaignId!} | Round: ${_currentRound!}',
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        if (_currentModelCIDForTraining != null) ...[
                          const SizedBox(height: 8),
                          const Text(
                            'Training Model:',
                            style: TextStyle(fontSize: 12),
                          ),
                          SelectableText(
                            _currentModelCIDForTraining!,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                              color: Colors.green,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 20),
              if (_isTraining) LinearProgressIndicator(value: _progress),
              const SizedBox(height: 20),
              Text(_statusMessage, textAlign: TextAlign.center),
              const SizedBox(height: 30),
              ElevatedButton(
                onPressed: _isTraining ? _cancelTraining : _startTrainingAndSubmission,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isTraining ? Colors.red : Colors.blue,
                ),
                child: Text(_isTraining ? 'Cancel' : 'Join Training'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
