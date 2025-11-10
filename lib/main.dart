// FILE: lib/main.dart
import 'package:flutter/material.dart';
import 'package:mobile_pione/screens/glasses.dart';

// import 'screens/capture_screen.dart';
import 'screens/wallet_screen.dart';
import 'screens/federated_learning_screen.dart';
import 'screens/capture_screen.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vision Mate',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // A PageController is used to control the PageView.
  late final PageController _pageController;

  // Track if drawing mode is active to disable page navigation
  bool _isDrawingModeActive = false;

  @override
  void initState() {
    super.initState();
    // Initialize the controller. The initialPage is 0 (the CaptureScreen).
    _pageController = PageController(initialPage: 0);
  }

  void _setDrawingMode(bool isDrawing) {
    setState(() {
      _isDrawingModeActive = isDrawing;
    });
  }

  @override
  void dispose() {
    // It's important to dispose of the controller when the widget is removed.
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // The PageView widget creates a scrollable list that works page by page.
      // This enables the swipe navigation between screens.
      body: PageView(
        controller: _pageController,
        // Disable physics when drawing mode is active
        physics: _isDrawingModeActive 
            ? const NeverScrollableScrollPhysics() 
            : const PageScrollPhysics(),
        children: [
          const CameraScreen(),
          CaptureScreen(onDrawingModeChanged: _setDrawingMode),
          const WalletScreen(),
          const FederatedLearningScreen(),
        ],
      ),
      // The BottomNavigationBar has been removed.
    );
  }
}