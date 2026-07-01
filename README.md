# 👻 GhostWriter

> A zero-latency, context-aware macOS dictation agent that magically types polished text into any active window.

GhostWriter is a lightweight native macOS utility that sits in your menu bar. Hold down the **Right Option** key to speak, and GhostWriter instantly transcribes and polishes your speech using Groq's ultra-fast Whisper and Llama 3 models, injecting the perfect text directly into whatever app you're currently using.

Meeting Mode adds a second capture path for calls and presentations. It uses ScreenCaptureKit to listen to system audio from the active display, transcribes meeting participants into a live notes file, and separately captures your microphone so your own contributions are labeled distinctly.

## ✨ Features

- **Zero-Latency Transcription:** Powered by Groq's `whisper-large-v3` for near-instant speech-to-text.
- **Context-Aware Polishing:** Automatically detects the app you are typing in (e.g., Slack, Mail, Xcode) and uses `llama-3.3-70b-versatile` to format your dictation appropriately (casual for Slack, formal for Mail, code-friendly for IDEs).
- **Native macOS Integration:** Built completely in Swift. Uses CoreGraphics event tapping for global hotkeys and Accessibility APIs (`AXUIElement`) to inject text seamlessly into your cursor's current position.
- **Secure Key Management:** Safely stores your API key in the macOS Keychain.
- **Meeting Mode via ScreenCaptureKit:** Captures system audio from meetings using Apple's screen capture APIs instead of a virtual audio device.
- **Split-Speaker Meeting Notes:** Writes timestamped markdown notes to `~/Documents/Notes`, tagging remote participants as `Them` and your mic capture as `You`.
- **Privacy-Scoped Capture:** Audio remains memory-only until it is sent to Groq for transcription. No raw audio files are written locally.

## 🚀 Installation

Because GhostWriter relies on global system hotkeys and accessibility features, it needs to be packaged cleanly to bypass macOS Gatekeeper quarantines. 

We've provided a simple build and deployment script:

1. Clone this repository to your Mac.
2. Open your terminal and run the ship script:
   ```bash
   ./ship.sh
   ```
3. The script will compile the Swift binary and create a `.release/GhostWriter.zip` file.
4. Unzip the file and double-click `install.command`. This will securely move the app to your `/Applications` folder, strip quarantine flags, and launch the app.

For local development instead of the packaged build:

```bash
swift build
.build/debug/GhostWriter
```

## ⚙️ Setup & Usage

1. **API Key:** On first launch, GhostWriter will prompt you for a [Groq API Key](https://console.groq.com/keys). Enter your key starting with `gsk_`.
2. **Permissions:** macOS will prompt you to grant **Microphone** and **Accessibility** permissions. Follow the prompts to enable them in System Settings.
3. **Meeting Mode Permission:** The first time you enable Meeting Mode, macOS will also require **Screen Recording** permission because ScreenCaptureKit is used to receive system audio.
4. **Dictate:** Place your cursor in any text field, in any app.
5. **Hold:** Press and hold the **Right Option** key. A glowing indicator will appear on your screen.
6. **Speak:** Talk naturally.
7. **Release:** Let go of the key. GhostWriter will process your speech and instantly type out the polished text!

## 🎧 Meeting Mode

1. Open the menu bar item and toggle **Meeting Mode**.
2. Approve **Screen Recording** if macOS prompts for it.
3. Start your meeting in Zoom, Meet, Teams, Slack, or any app that outputs audio through macOS.
4. GhostWriter will capture system audio through ScreenCaptureKit and append live transcript segments to a timestamped markdown file in `~/Documents/Notes`.
5. Your microphone is captured in parallel and written with a `You` label when you speak.
6. Toggle **Meeting Mode** off to stop capture and finalize the notes file with the meeting duration.

Notes:

- ScreenCaptureKit on macOS exposes system audio through the screen capture permission model, so audio capture for meetings is tied to Screen Recording approval.
- The app minimizes video capture to a tiny stream and only consumes the audio samples.
- If a meeting segment is very short or silent, GhostWriter discards it to reduce Whisper hallucinations.

## 🛠 Tech Stack & Architecture

- **Language:** Swift 5.9 (macOS 14.0+)
- **Audio:** `AVFoundation` (16kHz PCM audio capture & RMS-based Voice Activity Detection)
- **Meeting Capture:** `ScreenCaptureKit` for system audio capture during Meeting Mode
- **Input/Output:** `CoreGraphics` (CGEvent taps for hotkeys) & `ApplicationServices` (AXUIElement API for text injection)
- **UI:** SwiftUI (for the API key onboarding and the floating recording indicator)
- **AI Backend:** REST API calls to Groq's Whisper and Llama models.

---
*Built natively for Apple Silicon and macOS.*
