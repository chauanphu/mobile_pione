// lib/services/contract_service.dart

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart';
import 'package:web3dart/crypto.dart';
import 'wallet_service.dart';
import 'package:reown_appkit/reown_appkit.dart';

class ContractService {
  // --- Configuration - Replace with your details ---
  static const String _rpcUrl = 'https://rpc.zeroscan.org'; // Your RPC URL
  static const String _contractAddress =
      '0x3dB9B536f4F27606B4892fbB02aDA6218A5bfa00';
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
      debugPrint('Active Campaign ID result: $activeIdResult');
      final BigInt activeCampaignId = activeIdResult.first as BigInt;

      // If the campaign ID is 0, it means there's no active campaign.
      if (activeCampaignId == BigInt.zero) {
        debugPrint('No active campaign found.');
        return null;
      }

      // 2. Call the 'campaigns' view function with the active ID to get campaign details.
      final campaignDetailsResult = await _web3client.call(
        contract: _contract,
        function: _campaignsFunction,
        params: [activeCampaignId],
      );

      // 3. The result is a list. Based on the ABI, the globalModelCID is the 3rd element (index 2).
      // Output structure: [id, state, globalModelCID, currentRound, totalRounds, submissionDeadline, minSubmissions, submissionCounter]
      if (campaignDetailsResult.length > 2) {
        final String globalModelCID = campaignDetailsResult[2] as String;
        // Do NOT treat empty CID as "no active campaign"; return empty string to signal active campaign without model yet
        return globalModelCID;
      }
      return null;
    } catch (e) {
      debugPrint('Error fetching current global model: $e');
      return null;
    }
  }

  /// Returns the current active campaign id (0 if none)
  static Future<BigInt> getActiveCampaignId() async {
    try {
      final activeIdResult = await _web3client.call(
        contract: _contract,
        function: _activeCampaignIdFunction,
        params: [],
      );
      return activeIdResult.first as BigInt;
    } catch (e) {
      debugPrint('Error fetching activeCampaignId: $e');
      return BigInt.zero;
    }
  }

  /// Fetch campaign details by id using the `campaigns` public getter
  /// Returns a map with keys: id, state, globalModelCID, currentRound, totalRounds, submissionDeadline, minSubmissions, submissionCounter
  static Future<Map<String, dynamic>?> getCampaignDetails(BigInt campaignId) async {
    try {
      final details = await _web3client.call(
        contract: _contract,
        function: _campaignsFunction,
        params: [campaignId],
      );
      if (details.isEmpty) return null;
      return {
        'id': details[0] as BigInt,
        'state': (details[1] as BigInt).toInt(),
        'globalModelCID': details[2] as String,
        'currentRound': (details[3] as BigInt).toInt(),
        'totalRounds': (details[4] as BigInt).toInt(),
        'submissionDeadline': details[5] as BigInt,
        'minSubmissions': (details[6] as BigInt).toInt(),
        'submissionCounter': (details[7] as BigInt).toInt(),
      };
    } catch (e) {
      debugPrint('Error fetching campaign details: $e');
      return null;
    }
  }

  /// Submits a model CID to the smart contract using wallet signing.
  /// This sends the transaction through the connected wallet which will prompt the user to sign.
  static Future<String> submitModelWithWallet(
    String modelCid,
    String walletAddress,
  ) async {
    try {
      // Ensure contract is initialized
      if (!_isInitialized) {
        await initialize();
      }

      // Resolve topic and chainId for the connected session
      final topic = WalletService.appKitModal.session?.topic;
      final chainId = 'eip155:5080';

      if (topic == null) {
        throw Exception('No active wallet session (topic is null).');
      }

      // Build a minimal transaction template with the sender address
      final fromAddress = EthereumAddress.fromHex(walletAddress);
      final txTemplate = Transaction(
        from: fromAddress,
        // Optional: you can set gasPrice/maxGas if needed; AppKit/wallet can also estimate
      );

      debugPrint('Submitting model via wallet: $modelCid');
      // Request the wallet to send the transaction using AppKit helper
      final result = await WalletService.appKitModal.requestWriteContract(
        topic: topic,
        chainId: chainId,
        deployedContract: _contract,
        functionName: _submitModelFunction.name,
        transaction: txTemplate,
        parameters: [modelCid],
        // method can be omitted; defaults to eth_sendTransaction
      );

      // result for eth_sendTransaction should be the tx hash (String)
      final txHash = result?.toString() ?? '';
      if (txHash.isEmpty) {
        throw Exception('Empty transaction hash returned by wallet.');
      }

      debugPrint('Model submission txHash: $txHash');
      return txHash;
    } catch (e) {
      debugPrint('Error submitting model with wallet: $e');
      rethrow;
    }
  }

  /// Submits a model CID to the smart contract using provided credentials.
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
