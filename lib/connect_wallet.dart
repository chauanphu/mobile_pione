import 'package:flutter/material.dart';
import './function.dart';
import "package:reown_appkit/reown_appkit.dart";

// AppKit Modal instance
late final ReownAppKitModal _appKitModal;

void initializeAppKit(BuildContext context) {
  _appKitModal = ReownAppKitModal(
    context: context,
    projectId: '947c589be0bdf26edc51f4b99c32d060', // Replace with your actual project ID
    metadata: const PairingMetadata(
      name: 'Vision Mate App',
      description: 'App for connecting wallet and IoT device',
      url: 'https://github.com/thetrucy/vweb.github.io',
      icons: ['https://github.com/thetrucy/vweb.github.io/blob/main/vicon.png'],
      redirect: Redirect(
        native: 'https://github.com/thetrucy/vweb.github.io',
        universal: 'https://github.com/thetrucy/vweb.github.io',
      ),
    ),
    enableAnalytics: true,
  );
}

class ConnectWalletPage extends StatefulWidget {
  const ConnectWalletPage({super.key, required this.title});

  final String title;

  @override
  State<ConnectWalletPage> createState() => _ConnectWalletPageState();
}

class _ConnectWalletPageState extends State<ConnectWalletPage> {
  bool _isInitialized = false;
  bool _isConnected = false;
  @override
  void initState() {
    super.initState();
    initializeAppKit(context);
    // 💡 Call the new async initialization method
    _initReownAppKit(); 
    _setupConnectionListener();
  }
  void _initReownAppKit() async {
    try {
      await _appKitModal.init(); // This call is essential!
      if (mounted) {
        setState(() {
          _isInitialized = true;
        });
      }
    } catch (e) {
      // Handle initialization errors here (e.g., Project ID invalid)
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('AppKit initialization failed: $e')),
        );
      }
    }
  }
  void _setupConnectionListener() {
    _appKitModal.addListener(() {
      final isNowConnected = _appKitModal.isConnected;
      if (isNowConnected && !_isConnected) {
        // Connection just succeeded
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        backgroundColor: Theme.of(context).colorScheme.onPrimary,
        title: Text(widget.title),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Text(
              'Connect Your Wallet',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 32),
            AppKitModalNetworkSelectButton(appKit: _appKitModal),
            const SizedBox(height: 16),
            AppKitModalConnectButton(appKit: _appKitModal),
            const SizedBox(height: 16),
            Visibility(
              visible: _appKitModal.isConnected,
              child: AppKitModalAccountButton(appKitModal: _appKitModal),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(

        onPressed: _navigateToFunctionPage,
        tooltip: 'Next page',
        child: const Icon(Icons.arrow_right, size: 40,),
      ),
    );
  }

  void _navigateToFunctionPage() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const MyFunctionPage()),
    );
  }
}
