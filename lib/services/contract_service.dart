// lib/services/contract_service.dart

import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:http/http.dart';
import 'package:web3dart/crypto.dart';
import 'package:web3dart/web3dart.dart';

class ContractService {
  // --- Configuration - Replace with your details ---
  static const String _rpcUrl = 'https://rpc.zeroscan.org'; // Your RPC URL
  static const String _contractAddress =
      '0x8fbB5515aC9df7BdbB6A1AeBF6899Ae72Ef2f60B';
  // -------------------------------------------------

  static late Web3Client _web3client;
  static late DeployedContract _contract;

  // Events
  static late ContractEvent _newRoundStartedEvent;

  // Functions
  static late ContractFunction _submitModelFunction;
  static late ContractFunction _activeCampaignIdFunction; // NEW
  static late ContractFunction _campaignsFunction; // NEW

  static bool _isInitialized = false;

  /// Initializes the service by loading the contract ABI and setting up the client.
  static Future<void> initialize() async {
    if (_isInitialized) return;

    _web3client = Web3Client(_rpcUrl, Client());

    // Load the contract ABI from the assets folder
    final String abiString = await rootBundle.loadString('assets/abi/abi.json');
    final jsonAbi = jsonDecode(abiString);
    // FIXED: Pass the ABI array directly (it's already a List after jsonDecode)
    final contractAbi = ContractAbi.fromJson(
      jsonEncode(jsonAbi['abi']),
      'FederatedLearning',
    );
    final contractAddress = EthereumAddress.fromHex(
      _contractAddress,
    ); // Throws if invalid
    _contract = DeployedContract(contractAbi, contractAddress);

    // Initialize contract events and functions
    _newRoundStartedEvent = _contract.event('NewRoundStarted');
    _submitModelFunction = _contract.function('submitModel');
    _activeCampaignIdFunction = _contract.function('activeCampaignId'); // NEW
    _campaignsFunction = _contract.function('campaigns'); // NEW

    _isInitialized = true;
  }

  /// Listens to the NewRoundStarted event from the smart contract.
  Stream<List<dynamic>> get newRoundStartedStream {
    final eventSignatureTopic = bytesToHex(
      _newRoundStartedEvent.signature,
      include0x: true,
    );
    return _web3client
        .events(
          FilterOptions(
            address: _contract.address,
            topics: [
              [eventSignatureTopic],
            ],
          ),
        )
        .where((event) => event.topics != null && event.data != null)
        .map(
          (event) =>
              _newRoundStartedEvent.decodeResults(event.topics!, event.data!),
        );
  }

  // NEW: Function to get the current global model CID
  /// Fetches the global model CID from the currently active campaign.
  /// Returns the CID as a [String], or `null` if no active campaign is found or an error occurs.
  static Future<String?> getCurrentGlobalModel() async {
    try {
      // 1. Call the 'activeCampaignId' view function to get the current campaign ID.
      final activeIdResult = await _web3client.call(
        contract: _contract,
        function: _activeCampaignIdFunction,
        params: [],
      );
      final BigInt activeCampaignId = activeIdResult.first as BigInt;

      // If the campaign ID is 0, it means there's no active campaign.
      if (activeCampaignId == BigInt.zero) {
        print('No active campaign found.');
        return null;
      }

      // 2. Call the 'campaigns' view function with the active ID to get campaign details.
      final campaignDetailsResult = await _web3client.call(
        contract: _contract,
        function: _campaignsFunction,
        params: [activeCampaignId],
      );

      // 3. The result is a list. Based on the ABI, the globalModelCID is the 3rd element (index 2).
      // Output structure: [id, state, globalModelCID, currentRound, ...]
      if (campaignDetailsResult.length > 2) {
        final String globalModelCID = campaignDetailsResult[2] as String;
        return globalModelCID.isNotEmpty ? globalModelCID : null;
      }
      return null;
    } catch (e) {
      print('Error fetching current global model: $e');
      return null;
    }
  }

  /// Submits a model CID to the smart contract.
  /// Requires the wallet's credentials to sign the transaction.
  static Future<String> submitModel(
    String modelCid,
    Credentials credentials,
  ) async {
    final transaction = Transaction.callContract(
      contract: _contract,
      function: _submitModelFunction,
      parameters: [modelCid],
    );
    final txHash = await _web3client.sendTransaction(
      credentials,
      transaction,
      chainId: 5080, // Chain ID for Pione Zero
    );

    return txHash;
  }
}
