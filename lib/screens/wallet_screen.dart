import 'package:flutter/material.dart';
import 'package:reown_appkit/reown_appkit.dart';
import 'package:flutter/semantics.dart';
import '../services/wallet_service.dart';

class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key});

  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen>
    with AutomaticKeepAliveClientMixin {
  // bool _isInitialized = false;
  bool _isConnected = false;
  @override
  bool get wantKeepAlive => true;

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
      // if (mounted) setState(() => _isInitialized = true);
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
    // 1. Announce the success directly to the screen reader.
    const String successMessage = 'Wallet connected successfully!';
    SemanticsService.announce(successMessage, TextDirection.ltr);

    // // 2. Provide haptic feedback for confirmation.
    // HapticFeedback.mediumImpact();

    // 3. Show the visual SnackBar for sighted users.
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(successMessage),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
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
              child: AppKitModalAccountButton(
                appKitModal: WalletService.appKitModal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
