// Screen Answers — a floating corner window that screenshots your screen
// and asks Claude Opus 5.5 to answer whatever questions are on it.
// Every capture joins one running chat, so Claude can combine figures and
// question parts spread across several screenshots. "New Chat" starts over.
// Hotkey: Control + Option + A

import Cocoa
import Carbon.HIToolbox
import ScreenCaptureKit

let model = "claude-opus-5-5"
let effort = "medium"   // "low" = faster, "high" = more careful
let configDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/screen-answers")
let keyFile = configDir.appendingPathComponent("api_key")

let systemPrompt = """
You are a study helper shown in a small window in the corner of the user's screen. \
This is one running chat: the user sends screenshots of their screen over time (often a practice test or homework), \
plus occasional typed questions. Earlier screenshots stay in the conversation, so use them: a figure, table, passage, \
or the first part of a question may be in an earlier screenshot and the rest in a later one. Combine them.

How to answer:
- Answer only questions you haven't already answered in this chat, unless the user asks again.
- Multiple-choice question: reply with ONLY the question number and the letter, e.g. **3.** B — no explanation, no option text.
- Other questions (free response, fill-in, math): **3.** then the short final answer, plus one brief line of key steps only if needed.
- If the user has already selected or written an answer, append ✅ or ❌ (e.g. **3.** B ❌).
- If a question needs a figure or part you can't see yet, say so in one line (e.g. **5.** need the graph — capture it).
- If the user asks you to explain, then explain clearly but briefly.
- No LaTeX and no markdown headings. Write math in plain text/Unicode (x², √, π, ≤, →).
- If no question is visible, say in one line what you see.
"""

let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ScreenAnswers.log")

/// Appends a timestamped line to ~/Library/Logs/ScreenAnswers.log (never logs the API key or images).
func log(_ s: String) {
    let line = "\(Date()) \(s)\n"
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
    } else {
        try? line.write(to: logURL, atomically: true, encoding: .utf8)
    }
}

struct Msg: LocalizedError {
    let errorDescription: String?
    init(_ s: String) { errorDescription = s }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate!
    var panel: NSPanel!
    var textView: NSTextView!
    var statusLabel: NSTextField!
    var inputField: NSTextField!
    var statusItem: NSStatusItem!

    // Chat state
    var messages: [[String: Any]] = []     // full API conversation (images, text, thinking blocks)
    var transcript: [String] = []          // what the window shows, one entry per turn
    var pendingImages: [String] = []       // screenshots waiting to be sent
    var pendingText: [String] = []         // typed questions waiting to be sent
    var queuedLabels: [String] = []        // transcript lines for things waiting to be sent
    var streamingText: String?             // reply currently being typed out
    var shotCount = 0
    var busy = false
    var task: Task<Void, Never>?
    var chatID = 0                         // bumps on New Chat so stale replies are ignored

    func applicationDidFinishLaunching(_ n: Notification) {
        AppDelegate.shared = self
        buildMainMenu()
        buildPanel()
        buildStatusItem()
        registerHotKey()
        log("launched; screen permission = \(CGPreflightScreenCaptureAccess()); key saved = \(apiKey() != nil)")
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        if apiKey() == nil { showNeedKey() } else { showReady() }
        panel.orderFrontRegardless()
    }

    // Double-clicking the app while it's already running brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.orderFrontRegardless()
        return false
    }

    // MARK: UI

    func buildPanel() {
        let w: CGFloat = 380, h: CGFloat = 460
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let rect = NSRect(x: vf.maxX - w - 12, y: vf.maxY - h - 12, width: w, height: h)
        panel = NSPanel(contentRect: rect,
                        styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                        backing: .buffered, defer: false)
        panel.title = "Screen Answers"
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 260, height: 200)

        let bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        panel.contentView = bg

        let captureButton = NSButton(title: "📸 Capture  ⌃⌥A", target: self, action: #selector(capture))
        captureButton.bezelStyle = .rounded
        let newChatButton = NSButton(title: "New Chat", target: self, action: #selector(newChat))
        newChatButton.bezelStyle = .rounded
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let topRow = NSStackView(views: [captureButton, newChatButton, statusLabel])
        topRow.orientation = .horizontal
        topRow.spacing = 6

        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        textView = scroll.documentView as? NSTextView
        textView.isEditable = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 2, height: 6)

        inputField = NSTextField()
        inputField.target = self
        inputField.action = #selector(submitInput)

        let stack = NSStackView(views: [topRow, scroll, inputField])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 30, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bg.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            inputField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: "Screen Answers")
        let menu = NSMenu()
        menu.addItem(withTitle: "Capture Screen (⌃⌥A)", action: #selector(capture), keyEquivalent: "").target = self
        menu.addItem(withTitle: "New Chat", action: #selector(newChat), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Show / Hide Window", action: #selector(toggleWindow), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Change API Key…", action: #selector(resetKey), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Screen Answers", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    // Needed so ⌘V / ⌘C / ⌘A work in the text field.
    func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    func setStatus(_ s: String) { statusLabel.stringValue = s }

    /// Redraws the whole chat, plus an in-progress reply if there is one.
    func refresh() {
        var parts = transcript
        if let s = streamingText { parts.append(s.isEmpty ? "…" : s) }
        parts += queuedLabels
        let text = render(parts.joined(separator: "\n\n"))
        textView.textStorage?.setAttributedString(text)
        textView.scrollToEndOfDocument(nil)
    }

    func showMessage(_ s: String) {
        textView.textStorage?.setAttributedString(render(s))
    }

    func render(_ s: String) -> NSAttributedString {
        let size: CGFloat = 13
        let out = NSMutableAttributedString()
        let parsed = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
        for run in parsed.runs {
            var font = NSFont.systemFont(ofSize: size)
            var color = NSColor.labelColor
            if let i = run.inlinePresentationIntent {
                if i.contains(.stronglyEmphasized) { font = .boldSystemFont(ofSize: size) }
                if i.contains(.emphasized) {
                    font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                    color = .secondaryLabelColor
                }
                if i.contains(.code) { font = .monospacedSystemFont(ofSize: size - 1, weight: .regular) }
            }
            out.append(NSAttributedString(string: String(parsed[run.range].characters),
                                          attributes: [.font: font, .foregroundColor: color]))
        }
        return out
    }

    func showReady() {
        inputField.placeholderString = "Ask about anything in this chat…"
        setStatus("Ready")
        if transcript.isEmpty {
            showMessage("Press **⌃⌥A** (Control + Option + A) to capture your screen. Each capture adds to this chat, so you can grab a figure, scroll, then grab the question. **New Chat** starts fresh.")
        } else { refresh() }
    }

    func showNeedKey() {
        inputField.placeholderString = "Paste your Anthropic API key, then press Enter"
        setStatus("API key needed")
        showMessage("To get started, paste your Anthropic API key (starts with `sk-ant-`) in the box below and press Enter.\n\nGet one at console.anthropic.com → API Keys. It's saved only on this Mac.")
    }

    // MARK: Actions

    @objc func toggleWindow() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }

    @objc func resetKey() {
        try? FileManager.default.removeItem(at: keyFile)
        showNeedKey()
        panel.orderFrontRegardless()
    }

    @objc func newChat() {
        task?.cancel()
        chatID += 1
        busy = false
        messages = []
        transcript = []
        pendingImages = []
        pendingText = []
        queuedLabels = []
        streamingText = nil
        shotCount = 0
        if apiKey() == nil { showNeedKey() } else { showReady() }
    }

    @objc func submitInput() {
        let text = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputField.stringValue = ""
        guard apiKey() != nil else {
            guard text.hasPrefix("sk-ant-") else { setStatus("That doesn't look like an API key"); return }
            do {
                try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
                try text.write(to: keyFile, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
                showReady()
            } catch { setStatus("Couldn't save key: \(error.localizedDescription)") }
            return
        }
        pendingText.append(text)
        queuedLabels.append("_You: \(text)_")
        sendIfIdle()
        refresh()
    }

    @objc func capture() {
        guard apiKey() != nil else { showNeedKey(); panel.orderFrontRegardless(); return }
        log("capture pressed; preflight = \(CGPreflightScreenCaptureAccess())")
        let id = chatID
        Task { @MainActor in
            setStatus("Capturing…")
            let result: Result<String, Error>
            do { result = .success(try await Self.grabScreen()) } catch { result = .failure(error) }
            guard id == chatID else { return }
            switch result {
            case .success(let img):
                log("screenshot ok, \(img.count / 1024) KB base64")
                shotCount += 1
                pendingImages.append(img)
                queuedLabels.append("_📸 Screenshot \(shotCount)_")
                if busy { setStatus("Screenshot queued — sends when this answer finishes") }
                sendIfIdle()
                refresh()
            case .failure(let e):
                let ns = e as NSError
                log("screenshot failed: \(ns.domain) \(ns.code) \(e.localizedDescription)")
                setStatus("Permission needed")
                transcript.append("⚠️ Couldn't capture the screen (\(e.localizedDescription)).\n\nCheck System Settings → Privacy & Security → Screen & System Audio Recording: Screen Answers must be on. Then quit and reopen the app.")
                refresh()
            }
        }
    }

    /// Sends everything waiting (screenshots + typed questions) as one turn, unless a reply is already streaming.
    func sendIfIdle() {
        guard !busy, !(pendingImages.isEmpty && pendingText.isEmpty), let key = apiKey() else { return }
        var content: [[String: Any]] = pendingImages.map {
            ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": $0]]
        }
        let n = pendingImages.count
        var text = pendingText.joined(separator: "\n")
        if text.isEmpty {
            text = n == 1 ? "New screenshot. Answer any new questions (use earlier screenshots if needed)."
                          : "\(n) new screenshots. Answer any new questions (use earlier screenshots if needed)."
        }
        content.append(["type": "text", "text": text])
        pendingImages = []
        pendingText = []
        transcript += queuedLabels
        queuedLabels = []
        messages.append(["role": "user", "content": content])

        busy = true
        let id = chatID
        streamingText = ""
        refresh()
        task = Task { @MainActor in
            do {
                setStatus("Thinking…")
                let (shown, blocks) = try await stream(key: key)
                guard id == chatID else { return }
                streamingText = nil
                messages.append(["role": "assistant", "content": blocks])
                transcript.append(shown.isEmpty ? "(no answer)" : shown)
                setStatus("Done · ⌃⌥A to capture more")
                refresh()
            } catch {
                guard id == chatID else { return }
                streamingText = nil
                messages.removeLast()                  // drop the unanswered turn so the chat stays valid
                let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                if !cancelled {
                    setStatus("Error")
                    transcript.append("⚠️ \(error.localizedDescription)")
                }
                log("request ended: \(cancelled ? "cancelled" : error.localizedDescription)")
                refresh()
            }
            guard id == chatID else { return }
            busy = false
            sendIfIdle()                               // anything captured while we were answering
        }
    }

    // MARK: Screenshot

    /// Screenshots the main display with ScreenCaptureKit, leaving this app's own window out,
    /// scaled so the long edge is 1568px (a size Claude reads well). Returns base64 JPEG.
    static func grabScreen() async throws -> String {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first
        else { throw Msg("No display found") }
        let me = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
        let config = SCStreamConfiguration()
        let scale = min(1.0, 1568.0 / Double(max(display.width, display.height) * 2))
        config.width = Int(Double(display.width * 2) * scale)
        config.height = Int(Double(display.height * 2) * scale)
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        else { throw Msg("Couldn't encode screenshot") }
        return jpeg.base64EncodedString()
    }

    // MARK: Claude API (streaming)

    /// Streams a reply to the current conversation. Returns the visible text and the full
    /// content blocks (including thinking), which must go back unchanged on the next turn.
    func stream(key: String) async throws -> (String, [[String: Any]]) {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "stream": true,
            "thinking": ["type": "adaptive"],
            "output_config": ["effort": effort],
            "fallbacks": "default",
            "cache_control": ["type": "ephemeral"],   // reuse earlier screenshots cheaply
            "system": systemPrompt,
            "messages": messages,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        log("API response status \(status)")
        if status != 200 {
            var raw = ""
            for try await line in bytes.lines { raw += line }
            let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
            let message = (obj?["error"] as? [String: Any])?["message"] as? String ?? raw
            if status == 401 { throw Msg("Your API key was rejected. Use the menu bar icon → Change API Key.") }
            throw Msg("API error \(status): \(message)")
        }

        var blocks: [Int: [String: Any]] = [:]
        var text = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: "),
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any]
            else { continue }
            let index = obj["index"] as? Int ?? 0
            switch obj["type"] as? String {
            case "content_block_start":
                blocks[index] = obj["content_block"] as? [String: Any] ?? [:]
            case "content_block_delta":
                guard let d = obj["delta"] as? [String: Any], var b = blocks[index] else { continue }
                switch d["type"] as? String {
                case "text_delta":
                    let t = d["text"] as? String ?? ""
                    b["text"] = (b["text"] as? String ?? "") + t
                    text += t
                    setStatus("Answering…")
                    streamingText = text
                    refresh()
                case "thinking_delta":
                    b["thinking"] = (b["thinking"] as? String ?? "") + (d["thinking"] as? String ?? "")
                case "signature_delta":
                    b["signature"] = d["signature"] as? String ?? ""
                default: break
                }
                blocks[index] = b
            case "message_delta":
                if let d = obj["delta"] as? [String: Any], d["stop_reason"] as? String == "refusal" {
                    text += "\n(Claude declined to answer this.)"
                }
            case "error":
                let m = (obj["error"] as? [String: Any])?["message"] as? String ?? "Unknown error"
                throw Msg("API error: \(m)")
            default: break
            }
        }
        // Strip empty text blocks (the API rejects them) and keep the rest in order.
        let ordered = blocks.keys.sorted().compactMap { blocks[$0] }.filter {
            !($0["type"] as? String == "text" && ($0["text"] as? String ?? "").isEmpty)
        }
        let content = ordered.isEmpty ? [["type": "text", "text": text.isEmpty ? "(no answer)" : text]] : ordered
        return (text, content)
    }

    // MARK: Hotkey & key storage

    func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Task { @MainActor in AppDelegate.shared.capture() }
            return noErr
        }, 1, &spec, nil, nil)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(kVK_ANSI_A), UInt32(controlKey | optionKey),
                            EventHotKeyID(signature: OSType(0x53414E53), id: 1),
                            GetApplicationEventTarget(), 0, &ref)
    }

    func apiKey() -> String? {
        if let k = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !k.isEmpty { return k }
        guard let k = try? String(contentsOf: keyFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !k.isEmpty else { return nil }
        return k
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
