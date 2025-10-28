import 'package:flutter/material.dart';
import 'package:reown_appkit/reown_appkit.dart';

import '../services/wallet_service.dart';
import 'function_screen.dart';

class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key});

  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  bool _isInitialized = false;
  bool _isConnected = false;

  @override
  void initState() {
    super.initState();
    WalletService.initializeAppKit(context);
    _initReownAppKit();
    _setupConnectionListener();
  }

  void _initReownAppKit() async {
    try {
      await WalletService.appKitModal.init();
      if (mounted) setState(() => _isInitialized = true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('AppKit initialization failed: $e')),
        );
      }
    }
  }

  void _setupConnectionListener() {
    WalletService.appKitModal.addListener(() {
      final isNowConnected = WalletService.appKitModal.isConnected;
      if (isNowConnected && !_isConnected) {
        _showConnectSuccess();
      }
      setState(() {
        _isConnected = isNowConnected;
      });
    });
  }

  void _showConnectSuccess() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Wallet connected successfully!'),
        backgroundColor: Colors.green,
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _navigateToFunctionPage() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const MyFunctionPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: const Text('Vision Mate - Wallet'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Text(
              'Connect Your Wallet',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 32),
            // Network select & connect buttons provided by AppKit modal
            AppKitModalNetworkSelectButton(appKit: WalletService.appKitModal),
            const SizedBox(height: 16),
            AppKitModalConnectButton(appKit: WalletService.appKitModal),
            const SizedBox(height: 16),
            Visibility(
              visible: WalletService.appKitModal.isConnected,
              child: AppKitModalAccountButton(appKitModal: WalletService.appKitModal),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _navigateToFunctionPage,
        tooltip: 'Next page',
        child: const Icon(Icons.arrow_right, size: 40),
      ),
    );
  }
}
