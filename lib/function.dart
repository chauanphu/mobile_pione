import 'package:flutter/material.dart';

class MyFunctionPage extends StatelessWidget {
  const MyFunctionPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Function Page'),
      ),
      body: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container( // OCR function container
            margin: const EdgeInsets.all(10),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.red[400],
              borderRadius: BorderRadius.circular(10),
            ),
            child: 
              TextButton(
                onPressed: () {
                  // Implement OCR functionality here
                  final String result = _callOCRFunction();
                },
                child: const Icon(Icons.book, size: 100),           )
          ),

          Container( // BLIP function container
            width: 150,
            margin: const EdgeInsets.all(10),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.yellow[400],
              borderRadius: BorderRadius.circular(10),
            ),
            child: 
              Icon(Icons.image, size: 100)            
          ),
        ]
      )
    );
  }

  String _callOCRFunction() {
    // Placeholder for OCR function call
    return "OCR Result";
  }
}