import SwiftUI
import AppKit

// MARK: - App Delegate

/// Manages the app lifecycle, permission checks, hotkey registration, and the floating overlay.
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Properties

    private var statusItem: NSStatusItem?
    private var overlayPanel: NSPanel?
    private var overlayHostingView: NSHostingView<GlowOverlayView>?
    private var apiKeyWindowController: APIKeyWindowController?
    private var meetingModeMenuItem: NSMenuItem?

    // Core services
    private let permissionGuard = PermissionGuard()
    private let hotkeyManager = HotkeyManager()
    private let audioCapture = AudioCapture()
    private let systemAudioCapture = SystemAudioCapture()
    private let voiceActivityDetector = VoiceActivityDetector()
    private let groqService = GroqService()
    private let textPolisher = TextPolisher()
    private let appDetector = AppDetector()
    private let textInjector = TextInjector()

    // Shared state
    private let appState = AppState()

    // PTT audio buffer
    private var audioBuffer = Data()

    // Meeting mode state — system audio (others), accessed on meetingQueue
    private let meetingQueue = DispatchQueue(label: "com.ghostwriter.meeting", qos: .userInteractive)
    private var meetingSpeechBuffer = Data()
    private var meetingLastVoiceTime: Date?
    private var meetingSegmentStart: Date?
    private let meetingSilenceDebounce: TimeInterval = 1.5
    private let meetingMaxSegmentSeconds: TimeInterval = 25.0

    // Meeting mode state — microphone (self), accessed on micMeetingQueue
    private let micMeetingQueue = DispatchQueue(label: "com.ghostwriter.meeting.mic", qos: .userInteractive)
    private var micMeetingSpeechBuffer = Data()
    private var micMeetingLastVoiceTime: Date?
    private var micMeetingSegmentStart: Date?
    private let micCapture = AudioCapture()

    // Meeting notes
    private let meetingNotes = MeetingNotesWriter()
    private var meetingStartTime: Date?

    // Support logic
    private var hasPromptedForPermissions = false

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupOverlayPanel()
        setupHotkeyCallbacks()

        NotificationCenter.default.addObserver(self, selector: #selector(onAPIKeySaved), name: NSNotification.Name("APIKeySaved"), object: nil)

        if KeychainService.groqAPIKey() == nil {
            print("🔑 API Key missing — showing setup window")
            showAPIKeyWindow()
        } else {
            finishInitialization()
        }

        print("🎤 GhostWriter launched")
    }

    private func finishInitialization() {
        hotkeyManager.start()
        Task { @MainActor in await checkPermissions() }
    }

    @objc private func onAPIKeySaved() {
        finishInitialization()
    }

    @objc private func showAPIKeyWindow() {
        if apiKeyWindowController == nil {
            apiKeyWindowController = APIKeyWindowController()
        }
        apiKeyWindowController?.showAndActivate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager.stop()
        audioCapture.stop()
        systemAudioCapture.stop()
        overlayPanel?.close()
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "GhostWriter")
            button.image?.size = NSSize(width: 18, height: 18)
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "GhostWriter v0.1.0", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        let meetingItem = NSMenuItem(title: "Meeting Mode", action: #selector(toggleMeetingMode), keyEquivalent: "m")
        meetingItem.target = self
        menu.addItem(meetingItem)
        self.meetingModeMenuItem = meetingItem

        menu.addItem(NSMenuItem.separator())

        let apiKeyItem = NSMenuItem(title: "Set API Key…", action: #selector(showAPIKeyWindow), keyEquivalent: "k")
        apiKeyItem.target = self
        menu.addItem(apiKeyItem)

        let micItem = NSMenuItem(title: "Authorize Microphone…", action: #selector(manualMicRequest), keyEquivalent: "")
        micItem.target = self
        menu.addItem(micItem)

        let a11yItem = NSMenuItem(title: "Authorize Accessibility…", action: #selector(openPermissions), keyEquivalent: "")
        a11yItem.target = self
        menu.addItem(a11yItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit GhostWriter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    @objc private func manualMicRequest() {
        Task { @MainActor in
            await permissionGuard.requestMicrophonePermission()
        }
    }

    private func setupOverlayPanel() {
        let overlayView = GlowOverlayView(state: appState)
        let hostingView = NSHostingView(rootView: overlayView)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 180),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true  // enabled for dragging when in meeting mode
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.contentView = hostingView
        panel.isReleasedWhenClosed = false

        positionOverlayPanel(panel)

        self.overlayPanel = panel
        self.overlayHostingView = hostingView
    }

    private func positionOverlayPanel(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let panelSize = panel.frame.size
        let x = screenFrame.midX - panelSize.width / 2
        let y = screenFrame.minY + 60
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Hotkey Callbacks

    private func setupHotkeyCallbacks() {
        hotkeyManager.onKeyDown = { [weak self] in
            self?.startRecording()
        }

        hotkeyManager.onKeyUp = { [weak self] in
            self?.stopRecordingAndProcess()
        }
    }

    // MARK: - PTT Recording Flow

    private func startRecording() {
        guard permissionGuard.hasMicrophonePermission,
              permissionGuard.hasAccessibilityPermission else {
            print("⚠️ Missing permissions — cannot record")
            if !hasPromptedForPermissions {
                Task { @MainActor in await checkPermissions() }
            }
            return
        }

        audioBuffer = Data()
        appState.recordingState = .listening
        overlayPanel?.orderFront(nil)

        audioCapture.onAudioBuffer = { [weak self] buffer in
            guard let self else { return }
            let rms = self.voiceActivityDetector.calculateRMS(from: buffer)
            Task { @MainActor in self.appState.audioLevel = rms }
            self.audioBuffer.append(buffer)
        }

        audioCapture.start()
    }

    private func stopRecordingAndProcess() {
        audioCapture.stop()

        guard !audioBuffer.isEmpty else {
            appState.recordingState = .idle
            if !appState.isMeetingMode { overlayPanel?.orderOut(nil) }
            return
        }

        appState.recordingState = .processing
        let capturedAudio = audioBuffer
        audioBuffer = Data()

        Task {
            do {
                let rawText = try await groqService.transcribe(audioData: capturedAudio)
                guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    await MainActor.run {
                        appState.recordingState = .idle
                        if !appState.isMeetingMode { overlayPanel?.orderOut(nil) }
                    }
                    return
                }

                let activeApp = appDetector.currentApp()
                let polishedText = try await textPolisher.polish(rawText: rawText, appContext: activeApp)
                textInjector.inject(text: polishedText)

                await MainActor.run { appState.recordingState = .done }
                try? await Task.sleep(for: .milliseconds(500))
                await MainActor.run {
                    appState.recordingState = .idle
                    if !appState.isMeetingMode { overlayPanel?.orderOut(nil) }
                }
            } catch {
                print("❌ Pipeline error: \(error)")
                await MainActor.run { appState.recordingState = .error(error.localizedDescription) }
                try? await Task.sleep(for: .seconds(2))
                await MainActor.run {
                    appState.recordingState = .idle
                    if !appState.isMeetingMode { overlayPanel?.orderOut(nil) }
                }
            }
        }
    }

    // MARK: - Meeting Mode

    @objc private func toggleMeetingMode() {
        if appState.isMeetingMode {
            stopMeetingMode()
        } else {
            Task { @MainActor in await startMeetingMode() }
        }
    }

    @MainActor
    private func startMeetingMode() async {
        // Ensure screen recording permission (SCShareableContent will prompt if needed)
        do {
            try await systemAudioCapture.start()
        } catch {
            print("❌ Could not start system audio capture: \(error.localizedDescription)")
            showError("Screen Recording permission is required for Meeting Mode. Enable it in System Settings → Privacy & Security → Screen Recording.")
            return
        }

        appState.isMeetingMode = true
        appState.meetingCaption = "Listening to meeting…"
        appState.isSpeakerActive = false
        meetingModeMenuItem?.state = .on
        meetingStartTime = Date()
        meetingNotes.beginSession()

        // Update status bar icon
        statusItem?.button?.image = NSImage(systemSymbolName: "headphones.circle.fill", accessibilityDescription: "Meeting Mode")

        overlayPanel?.ignoresMouseEvents = false  // allow dragging the pill
        overlayPanel?.orderFront(nil)
        print("📡 Meeting Mode ON")

        setupMeetingAudioCallback()
        setupMicMeetingCallback()
    }

    private func stopMeetingMode() {
        micCapture.stop()
        micMeetingQueue.sync {
            micMeetingSpeechBuffer = Data()
            micMeetingLastVoiceTime = nil
            micMeetingSegmentStart = nil
        }
        systemAudioCapture.stop()

        if let start = meetingStartTime {
            meetingNotes.endSession(startedAt: start)
            meetingStartTime = nil
        }

        // Flush any remaining buffer
        meetingQueue.sync {
            meetingSpeechBuffer = Data()
            meetingLastVoiceTime = nil
            meetingSegmentStart = nil
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.appState.isMeetingMode = false
            self.appState.meetingCaption = ""
            self.appState.isSpeakerActive = false
            self.meetingModeMenuItem?.state = .off
            self.statusItem?.button?.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "GhostWriter")

            self.overlayPanel?.ignoresMouseEvents = true  // restore pass-through
            if self.appState.recordingState == .idle {
                self.overlayPanel?.orderOut(nil)
            }
            print("📡 Meeting Mode OFF")
        }
    }

    private func setupMeetingAudioCallback() {
        let vad = VoiceActivityDetector()
        vad.silenceDebounce = 0.1  // We handle our own longer debounce below

        var vadDebugCount = 0
        var peakDBFS: Float = -160.0
        var peakResetCount = 0
        let peakWindowBuffers = 240 // ~10s at 4096 frames / 24kHz
        systemAudioCapture.onAudioBuffer = { [weak self] buffer in
            guard let self else { return }

            let rms = vad.calculateRMS(from: buffer)
            let dbfs = vad.rmsToDBFS(rms)
            let isVoice = dbfs >= -50.0

            if dbfs > peakDBFS { peakDBFS = dbfs }
            vadDebugCount += 1
            peakResetCount += 1
            if peakResetCount >= peakWindowBuffers {
                print("🎙 Peak dBFS last 10s: \(String(format: "%.1f", peakDBFS)) (threshold -65)")
                peakDBFS = -160.0
                peakResetCount = 0
            }

            self.meetingQueue.async { [weak self] in
                self?.processMeetingBuffer(buffer, isVoice: isVoice, rms: rms)
            }
        }
    }

    // MARK: - Mic Capture (self) in Meeting Mode

    private func setupMicMeetingCallback() {
        let vad = VoiceActivityDetector()
        micCapture.onAudioBuffer = { [weak self] buffer in
            guard let self else { return }
            let rms = vad.calculateRMS(from: buffer)
            let isVoice = vad.rmsToDBFS(rms) >= -40.0  // mic threshold — louder than system audio
            self.micMeetingQueue.async { [weak self] in
                self?.processMicMeetingBuffer(buffer, isVoice: isVoice)
            }
        }
        micCapture.start()
    }

    private func processMicMeetingBuffer(_ buffer: Data, isVoice: Bool) {
        let now = Date()
        if isVoice {
            if micMeetingSpeechBuffer.isEmpty { micMeetingSegmentStart = now }
            micMeetingSpeechBuffer.append(buffer)
            micMeetingLastVoiceTime = now
            if let start = micMeetingSegmentStart,
               now.timeIntervalSince(start) >= meetingMaxSegmentSeconds {
                flushMicMeetingSegment()
            }
        } else if let lastVoice = micMeetingLastVoiceTime,
                  now.timeIntervalSince(lastVoice) >= meetingSilenceDebounce,
                  !micMeetingSpeechBuffer.isEmpty {
            flushMicMeetingSegment()
        }
    }

    private func flushMicMeetingSegment() {
        let captured = micMeetingSpeechBuffer
        micMeetingSpeechBuffer = Data()
        micMeetingLastVoiceTime = nil
        micMeetingSegmentStart = nil

        let minBytes = 16000 * 2 / 2
        guard captured.count >= minBytes else { return }

        Task {
            do {
                let text = try await groqService.transcribe(audioData: captured)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      !self.whisperHallucinations.contains(trimmed.lowercased()) else { return }
                print("🎤 You: \(trimmed)")
                self.meetingNotes.append(segment: trimmed, speaker: "You")
            } catch {
                print("❌ Mic transcription error: \(error.localizedDescription)")
            }
        }
    }

    private func processMeetingBuffer(_ buffer: Data, isVoice: Bool, rms: Float) {
        // Must be called on meetingQueue
        let now = Date()

        if isVoice {
            if meetingSpeechBuffer.isEmpty {
                meetingSegmentStart = now
                DispatchQueue.main.async { [weak self] in
                    self?.appState.isSpeakerActive = true
                    self?.appState.audioLevel = rms
                }
            }
            meetingSpeechBuffer.append(buffer)
            meetingLastVoiceTime = now

            // Flush if segment is too long (Whisper's 25s limit)
            if let start = meetingSegmentStart,
               now.timeIntervalSince(start) >= meetingMaxSegmentSeconds {
                flushMeetingSegment()
            }
        } else {
            // Update UI level
            DispatchQueue.main.async { [weak self] in
                self?.appState.audioLevel = rms
            }

            // Check if we've been silent long enough after speech
            if let lastVoice = meetingLastVoiceTime,
               now.timeIntervalSince(lastVoice) >= meetingSilenceDebounce,
               !meetingSpeechBuffer.isEmpty {
                flushMeetingSegment()
                DispatchQueue.main.async { [weak self] in
                    self?.appState.isSpeakerActive = false
                }
            }
        }
    }

    // Whisper hallucinates these phrases on short/quiet audio — discard them
    private let whisperHallucinations: Set<String> = [
        "thank you.", "thanks for watching.", "thanks for watching", "thank you",
        "you", ".", " ", "of the", "the", "a", "i", "bye.", "bye",
        "[music]", "[applause]", "[silence]", "♪", "..."
    ]

    private func flushMeetingSegment() {
        // Must be called on meetingQueue
        let capturedAudio = meetingSpeechBuffer
        meetingSpeechBuffer = Data()
        meetingLastVoiceTime = nil
        meetingSegmentStart = nil

        guard !capturedAudio.isEmpty else { return }

        // Require at least 0.5s of audio (16kHz × 2 bytes × 0.5s = 16000 bytes)
        // Whisper hallucinates on very short clips
        let minBytes = 16000 * 2 / 2  // 0.5s at 16kHz Int16
        guard capturedAudio.count >= minBytes else {
            print("⏭ Segment too short (\(capturedAudio.count) bytes), skipping")
            return
        }

        Task {
            do {
                let text = try await groqService.transcribe(audioData: capturedAudio)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }

                // Discard known Whisper hallucinations
                guard !self.whisperHallucinations.contains(trimmed.lowercased()) else {
                    print("⏭ Filtered hallucination: '\(trimmed)'")
                    return
                }

                print("📡 Meeting transcript: \(trimmed)")
                self.meetingNotes.append(segment: trimmed)
                await MainActor.run { [weak self] in
                    self?.appState.meetingCaption = trimmed
                }
            } catch {
                print("❌ Meeting transcription error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Permissions

    @MainActor
    private func checkPermissions() async {
        let hasMic = await permissionGuard.requestMicrophonePermission()
        let hasA11y = permissionGuard.checkAccessibilityPermission()

        if hasA11y {
            hotkeyManager.start()
        }

        if !hasMic || !hasA11y {
            guard !hasPromptedForPermissions else { return }
            hasPromptedForPermissions = true

            let alert = NSAlert()
            alert.messageText = "GhostWriter Needs Permissions"
            alert.informativeText = "Please enable Microphone and Accessibility in System Settings, then click 'I've Done It'."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "I've Done It")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                openPermissions()
            } else {
                hotkeyManager.start()
            }
        }
    }

    @objc private func openPermissions() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "GhostWriter"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - App State

/// Observable state shared across the app — drives the GlowOverlay UI.
@Observable
final class AppState {
    var recordingState: RecordingState = .idle
    var audioLevel: Float = 0.0
    // Meeting mode
    var isMeetingMode: Bool = false
    var isSpeakerActive: Bool = false
    var meetingCaption: String = ""
}

// MARK: - Recording State

enum RecordingState: Equatable {
    case idle
    case listening
    case processing
    case done
    case error(String)

    static func == (lhs: RecordingState, rhs: RecordingState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.listening, .listening),
             (.processing, .processing), (.done, .done):
            return true
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}
