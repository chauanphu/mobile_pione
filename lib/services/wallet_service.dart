import 'package:flutter/material.dart';
import 'package:reown_appkit/reown_appkit.dart';

/// Lightweight wrapper around the Reown AppKit modal used by the wallet screen.
class WalletService {
  static late final ReownAppKitModal _appKitModal;

  static void initializeAppKit(BuildContext context) {
    ReownAppKitModalNetworks.removeSupportedNetworks('solana');
    ReownAppKitModalNetworks.addSupportedNetworks('eip155', [
      ReownAppKitModalNetworkInfo(
        name: 'Pione Zero',
        chainId: '5080',
        chainIcon: '',
        currency: 'PZO',
        rpcUrl: 'https://rpc.zeroscan.org',
        explorerUrl: 'https://pionechain.com',
      )
    ]);

    _appKitModal = ReownAppKitModal(
      context: context,
      projectId: '947c589be0bdf26edc51f4b99c32d060',
      metadata: const PairingMetadata(
        name: 'Vision Mate App',
        description: 'App for connecting wallet and IoT device',
        url: 'https://github.com/thetrucy/vweb.github.io',
        icons: [
          'https://github.com/thetrucy/vweb.github.io/blob/main/vicon.png',
        ],
        redirect: Redirect(
          native: 'https://github.com/thetrucy/vweb.github.io',
          universal: 'https://github.com/thetrucy/vweb.github.io',
        ),
      ),
      enableAnalytics: true,
      disconnectOnDispose: true,
      optionalNamespaces: {
        'eip155': RequiredNamespace.fromJson({
          'chains': ReownAppKitModalNetworks.getAllSupportedNetworks(
            namespace: 'eip155',
          ).map((chain) => chain.chainId).toList(),
          'methods': NetworkUtils.defaultNetworkMethods['eip155']!.toList(),
          'events': NetworkUtils.defaultNetworkEvents['eip155']!.toList(),
        }),
      },
    );
  }

  static ReownAppKitModal get appKitModal => _appKitModal;

  /// Returns the currently connected wallet address as a hex string (0x...) or null.
  static String? getCurrentWalletAddress() {
    try {
      if (!_appKitModal.isConnected) return null;
      final selectedChain = _appKitModal.selectedChain?.chainId;
      if (selectedChain == null) return null;
      final namespace = NamespaceUtils.getNamespaceFromChain(selectedChain);
      return _appKitModal.session?.getAddress(namespace);
    } catch (_) {
      return null;
    }

  }

  /// Checks if wallet is currently connected
  static bool isConnected() {
    return _appKitModal.isConnected;
  }
}
