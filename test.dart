import 'package:flutter/material.dart';
import 'package:flutter_uvc_camera/flutter_uvc_camera.dart';

class CameraScreen extends StatefulWidget {
  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  late UVCCameraController cameraController;
  bool isCameraOpen = false;

  @override
  void initState() {
    super.initState();
    cameraController = UVCCameraController();
    
    // Set up camera state callback
    cameraController.cameraStateCallback = (state) {
      setState(() {
        isCameraOpen = state == UVCCameraState.opened;
      });
    };
  }

  @override
  void dispose() {
    cameraController.closeCamera();
    cameraController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('UVC Camera')),
      body: Column(
        children: [
          // Camera preview
          Container(
            height: 300,
            child: UVCCameraView(
              cameraController: cameraController,
              width: 300, 
              height: 300,
            ),
          ),
          
          // Camera control buttons
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              ElevatedButton(
                onPressed: isCameraOpen ? null : () => cameraController.openUVCCamera(),
                child: Text('Open Camera'),
              ),
              ElevatedButton(
                onPressed: isCameraOpen ? () => cameraController.closeCamera() : null,
                child: Text('Close Camera'),
              ),
              ElevatedButton(
                onPressed: isCameraOpen ? () => takePicture() : null,
                child: Text('Take Picture'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> takePicture() async {
    final path = await cameraController.takePicture();
    if (path != null) {
      print('Picture saved at: $path');
    }
  }
}