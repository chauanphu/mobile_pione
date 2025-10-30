---
applyTo: '**'
---
Imagine you are a Flutter specializing in accessibility for visually impaired users.
I want to implement a image-captioning mobile app for visual impaired users.
The mobile will capture the image of the surroundings, feed toward the model and return the auditory description (TTS).

## Features
1. The "Image capture" default screen:
	- The screen contains a "Capture" button at the bottom center.
    - When the user taps the "Capture" button, the app uses the device camera to take a photo.
    - After capturing the image, the app processes the image using an image-captioning model to generate a descriptive caption.
    - The generated caption is then converted to speech using Text-to-Speech (TTS) technology and played back to the user.
2. The "Wallet Connection" screen:
    - The screen contains a "Connect Wallet" button at the center.
    - When the user taps the "Connect Wallet" button, the app initiates a connection to the user's digital wallet using a secure authentication method.
    - Once connected, the app displays a confirmation message indicating that the wallet has been successfully connected.
3. The "Federated Learning" screen:
    - Shows the current global model cid.
    - The screen contains a "Start Federated Learning" button at the center.
    - When the user taps the "Start Federated Learning" button, the app subscribe to the websocket and listen to `NewRoundStarted` event.
    - Upon receiving the `NewRoundStarted` event, the app downloads the global model, performs local training using the user's data.
    - After local training is complete, the app uploads the updated model weights as `.litertlm` to IPFS.
    - Then the app submit the new model cid to the federated learning server via the smart contract.
4. The "UVC Camera" screen:
    - This page is similar to the "Image capture" screen but uses an external UVC camera instead of the device's built-in camera.
    - The screen contains a "Capture from UVC" button at the bottom center.
    - When the user taps the "Capture from UVC" button, the app captures an image from the connected UVC camera.
    - The captured image is then processed using the same image-captioning model, and the generated caption is converted to speech using TTS and played back to the user.