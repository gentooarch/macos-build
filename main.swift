//swiftc -O -target-cpu native -parse-as-library main.swift -o Gemini
/*
 ===========================================================================
 Gemini macOS Client (Swift Version) - High Performance Edition
 [Upload Logic Modified]
 
 1. 修复：编译错误 (NSTextField.BezelStyle)
 2. 修复：移除所有系统蓝色 (Focus Ring / Button Tint)
 3. 优化：界面风格完全统一为"纸张"与"墨水"配色
 4. 修改：Upload 按钮改为上传历史记录到指定服务器 (POST t=content)
 ===========================================================================
 */

import Cocoa
import UniformTypeIdentifiers
import Foundation

// ==========================================
// 1. 全局配置与常量
// ==========================================

struct AppConfig {
    static var apiKey: String = "YOUR_API_KEY_HERE"
    // [修改] 上传的目标服务器地址
    static var uploadServerUrl: String = "https://abc.dpdns.org"
    
    static let historyFilePath = "/tmp/gemini_chat_history_swift.json"
    static let modelEndpoint = "https://generativelanguage.googleapis.com/v1beta/models/gemini-3-flash-preview:generateContent?key="
    
    static let maxHistoryMessages = 50 
    
    struct Fonts {
        static let text = NSFont.systemFont(ofSize: 28.0)
        static let header = NSFont.boldSystemFont(ofSize: 30.0)
        static let lineHeightMult: CGFloat = 1.2
    }
    
    struct Colors {
        // 纸张背景
        static let paperBackground = NSColor(srgbRed: 0.98, green: 0.976, blue: 0.965, alpha: 1.0)
        // 按钮背景（深一点的纸张色，去蓝）
        static let buttonBackground = NSColor(srgbRed: 0.90, green: 0.88, blue: 0.86, alpha: 1.0)
        // 按钮边框
        static let buttonBorder = NSColor(srgbRed: 0.80, green: 0.78, blue: 0.76, alpha: 0.8)
        
        static let user = NSColor(srgbRed: 0.20, green: 0.20, blue: 0.20, alpha: 1.0)
        static let model = NSColor(srgbRed: 0.17, green: 0.24, blue: 0.31, alpha: 1.0)
        static let thought = NSColor(srgbRed: 0.50, green: 0.55, blue: 0.55, alpha: 1.0)
        static let system = NSColor(srgbRed: 0.60, green: 0.60, blue: 0.60, alpha: 1.0)
        static let error = NSColor(srgbRed: 0.75, green: 0.22, blue: 0.17, alpha: 1.0)
    }
}

// ==========================================
// 2. 数据模型
// ==========================================

struct ChatPart: Codable {
    let text: String?
    let thought: String?
}

struct ChatMessage: Codable {
    let role: String
    let parts: [ChatPart]
}

struct APIRequest: Codable {
    let contents: [ChatMessage]
}

struct APIResponse: Codable {
    struct Candidate: Codable {
        struct Content: Codable {
            let parts: [ChatPart]?
        }
        let content: Content
    }
    struct APIError: Codable {
        let message: String
    }
    
    let candidates: [Candidate]?
    let error: APIError?
}

// ==========================================
// 3. ChatWindowController
// ==========================================

class ChatWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    
    private var textView: NSTextView!
    private var textContentStorage: NSTextContentStorage!
    private var textLayoutManager: NSTextLayoutManager!
    private var textContainer: NSTextContainer!
    
    private var inputField: NSTextField!
    private var sendButton: NSButton!
    private var effectView: NSVisualEffectView!
    
    private var chatHistory: [ChatMessage] = []
    private let ioQueue = DispatchQueue(label: "com.gemini.ioQueue", qos: .background)
    
    init() {
        let frame = NSRect(x: 0, y: 0, width: 1200, height: 900)
        let style: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        
        let window = NSWindow(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
        window.title = "Gemini Reader"
        window.minSize = NSSize(width: 800, height: 600)
        window.collectionBehavior = .fullScreenPrimary
        
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .aqua)
        
        super.init(window: window)
        
        setupUI()
        loadHistoryFromDisk()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        guard let window = self.window, let contentView = window.contentView else { return }
        let bounds = contentView.bounds
        
        // --- 尺寸调整区 ---
        let bottomMargin: CGFloat = 30
        let controlHeight: CGFloat = 64
        let controlsPadding: CGFloat = 20
        let bottomAreaTotalHeight = bottomMargin + controlHeight + controlsPadding
        
        // 1. 背景层
        effectView = NSVisualEffectView(frame: bounds)
        effectView.autoresizingMask = [.width, .height]
        effectView.material = .underPageBackground
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        window.contentView = effectView
        
        let tintView = NSView(frame: bounds)
        tintView.autoresizingMask = [.width, .height]
        tintView.wantsLayer = true
        tintView.layer?.backgroundColor = AppConfig.Colors.paperBackground.withAlphaComponent(0.85).cgColor
        effectView.addSubview(tintView)
        
        // 2. 文本区域
        let scrollView = NSScrollView(frame: NSRect(x: 30, y: bottomAreaTotalHeight, width: bounds.width - 60, height: bounds.height - bottomAreaTotalHeight - 30))
        scrollView.hasVerticalScroller = true
        scrollView.autoresizingMask = [.width, .height]
        scrollView.drawsBackground = false
        scrollView.wantsLayer = true
        
        textContentStorage = NSTextContentStorage()
        textLayoutManager = NSTextLayoutManager()
        textContentStorage.addTextLayoutManager(textLayoutManager)
        
        textContainer = NSTextContainer(size: NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        textLayoutManager.textContainer = textContainer
        
        textView = NSTextView(frame: scrollView.bounds, textContainer: textContainer)
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = .width
        textView.isEditable = false
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 20, height: 30)
        textView.font = AppConfig.Fonts.text
        textView.drawsBackground = false
        textView.wantsLayer = true
        
        scrollView.documentView = textView
        effectView.addSubview(scrollView)
        
        // 3. 底部 UI
        let buttonWidth: CGFloat = 120
        let buttonGap: CGFloat = 15
        let totalButtonWidth = (buttonWidth * 3) + (buttonGap * 2)
        
        let inputX: CGFloat = 30
        let btnStartX = bounds.width - 30 - totalButtonWidth
        
        // --- 输入框 ---
        inputField = NSTextField(frame: NSRect(x: inputX, y: bottomMargin, width: btnStartX - inputX - 20, height: controlHeight))
        inputField.placeholderString = "Ask Gemini..."
        inputField.font = NSFont.systemFont(ofSize: 28)
        
        // 无边框
        inputField.isBordered = false
        inputField.drawsBackground = false
        inputField.focusRingType = .none
        
        inputField.delegate = self
        inputField.target = self
        inputField.action = #selector(onEnterPressed)
        inputField.autoresizingMask = [.width, .maxYMargin]
        
        // 手动绘制背景层
        inputField.wantsLayer = true
        inputField.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.6).cgColor
        inputField.layer?.cornerRadius = 12
        inputField.layer?.borderWidth = 1.0
        inputField.layer?.borderColor = AppConfig.Colors.buttonBorder.cgColor
        
        effectView.addSubview(inputField)
        
        // 按钮生成器
        func createButton(title: String, x: CGFloat) -> NSButton {
            let btn = NSButton(title: title, target: self, action: nil)
            
            btn.bezelStyle = .shadowlessSquare
            btn.isBordered = false
            btn.focusRingType = .none 
            
            btn.wantsLayer = true
            btn.layer?.backgroundColor = AppConfig.Colors.buttonBackground.cgColor
            btn.layer?.cornerRadius = 10
            btn.layer?.borderWidth = 1.0
            btn.layer?.borderColor = AppConfig.Colors.buttonBorder.cgColor
            
            btn.frame = NSRect(x: x, y: bottomMargin, width: buttonWidth, height: controlHeight)
            btn.autoresizingMask = [.minXMargin, .maxYMargin]
            
            let pStyle = NSMutableParagraphStyle()
            pStyle.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: AppConfig.Colors.user,
                .font: NSFont.systemFont(ofSize: 22, weight: .medium)
            ]
            btn.attributedTitle = NSAttributedString(string: title, attributes: attrs)
            
            return btn
        }
        
        sendButton = createButton(title: "Send", x: btnStartX)
        sendButton.action = #selector(onSendClicked)
        sendButton.keyEquivalent = "\r"
        effectView.addSubview(sendButton)
        
        let uploadBtn = createButton(title: "Upload", x: btnStartX + buttonWidth + buttonGap)
        uploadBtn.action = #selector(onUploadClicked) // 目标动作修改
        effectView.addSubview(uploadBtn)
        
        let clearBtn = createButton(title: "Clear", x: btnStartX + (buttonWidth + buttonGap) * 2)
        clearBtn.action = #selector(onClearClicked)
        effectView.addSubview(clearBtn)
    }
    
    // ==========================================
    // 逻辑处理
    // ==========================================
    
    @objc private func onEnterPressed() {
        onSendClicked()
    }
    
    @objc private func onSendClicked() {
        let input = inputField.stringValue
        guard !input.isEmpty else { return }
        
        if input == "/clear" {
            onClearClicked()
            inputField.stringValue = ""
            return
        }
        
        processUserMessage(input)
        inputField.stringValue = ""
    }
    
    // [修改] 核心功能：上传历史记录
    @objc private func onUploadClicked() {
        // 1. 检查是否有历史记录
        guard !chatHistory.isEmpty else {
            appendLog(header: "[System]", content: "No history to upload.", color: AppConfig.Colors.system)
            return
        }
        
        // 2. 格式化历史记录为纯文本
        let historyText = chatHistory.map { msg -> String in
            let roleDisplay = msg.role == "user" ? "User" : "Gemini"
            let content = msg.parts.compactMap { $0.text }.joined(separator: "\n")
            // 简单格式化：分割线 + 角色 + 内容
            return "----------------\n[\(roleDisplay)]\n\(content)"
        }.joined(separator: "\n\n")
        
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let fullContent = "Chat History Export (\(timestamp))\n\n\(historyText)"
        
        appendLog(header: "[System]", content: "Uploading history...", color: AppConfig.Colors.system)
        
        // 3. 构建 POST 请求 (curl -d "t=content")
        guard let url = URL(string: AppConfig.uploadServerUrl) else {
            appendLog(header: "[Error]", content: "Invalid Upload URL configuration.", color: AppConfig.Colors.error)
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // 使用 application/x-www-form-urlencoded
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        // 4. 对内容进行 URL 编码
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~") // RFC 3986 Unreserved characters
        
        // 简单的编码处理，将文本放在 t= 后面
        if let encodedContent = fullContent.addingPercentEncoding(withAllowedCharacters: allowed) {
            let bodyString = "t=\(encodedContent)"
            request.httpBody = bodyString.data(using: .utf8)
            
            // 5. 异步发送
            let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    
                    if let error = error {
                        self.appendLog(header: "[Upload Error]", content: error.localizedDescription, color: AppConfig.Colors.error)
                        return
                    }
                    
                    if let httpResponse = response as? HTTPURLResponse {
                        if (200...299).contains(httpResponse.statusCode) {
                            self.appendLog(header: "[System]", content: "Upload successful! (Code: \(httpResponse.statusCode))", color: AppConfig.Colors.system)
                        } else {
                            self.appendLog(header: "[Upload Failed]", content: "Server returned code: \(httpResponse.statusCode)", color: AppConfig.Colors.error)
                        }
                    }
                }
            }
            task.resume()
        } else {
            appendLog(header: "[Error]", content: "Failed to encode history content.", color: AppConfig.Colors.error)
        }
    }
    
    @objc private func onClearClicked() {
        chatHistory.removeAll()
        saveHistoryInBackground()
        
        textContentStorage.performEditingTransaction {
            textContentStorage.textStorage?.deleteCharacters(in: NSRange(location: 0, length: textContentStorage.textStorage!.length))
        }
        appendLog(header: "[System]", content: "History cleared.", color: AppConfig.Colors.system)
    }
    
    private func processUserMessage(_ text: String) {
        appendLog(header: "You", content: text, color: AppConfig.Colors.user)
        
        let userMsg = ChatMessage(role: "user", parts: [ChatPart(text: text, thought: nil)])
        chatHistory.append(userMsg)
        
        saveHistoryInBackground()
        callGeminiAPI()
    }
    
    // ==========================================
    // API 网络请求
    // ==========================================
    
    private func callGeminiAPI() {
        setUIEnabled(false)
        
        Task {
            do {
                let contextHistory = Array(chatHistory.suffix(AppConfig.maxHistoryMessages))
                let response = try await fetchGeminiResponse(history: contextHistory)
                
                await MainActor.run {
                    self.handleAPIResponse(response)
                    self.setUIEnabled(true)
                }
            } catch {
                await MainActor.run {
                    self.appendLog(header: "[Network Error]", content: error.localizedDescription, color: AppConfig.Colors.error)
                    self.setUIEnabled(true)
                }
            }
        }
    }
    
    private func fetchGeminiResponse(history: [ChatMessage]) async throws -> APIResponse {
        guard let url = URL(string: AppConfig.modelEndpoint + AppConfig.apiKey) else {
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let payload = APIRequest(contents: history)
        request.httpBody = try JSONEncoder().encode(payload)
        
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(APIResponse.self, from: data)
    }
    
    private func handleAPIResponse(_ response: APIResponse) {
        if let error = response.error {
            appendLog(header: "[API Error]", content: error.message, color: AppConfig.Colors.error)
            return
        }
        
        guard let candidate = response.candidates?.first,
              let parts = candidate.content.parts, !parts.isEmpty else {
            return
        }
        
        var fullText = ""
        var fullThought = ""
        
        for part in parts {
            if let thought = part.thought {
                fullThought += thought + "\n"
            }
            if let text = part.text {
                fullText += text
            }
        }
        
        if !fullThought.isEmpty {
            appendLog(header: "Thinking", content: fullThought.trimmingCharacters(in: .whitespacesAndNewlines), color: AppConfig.Colors.thought)
        }
        
        if !fullText.isEmpty {
            appendLog(header: "Gemini", content: fullText, color: AppConfig.Colors.model)
            
            let modelMsg = ChatMessage(role: "model", parts: [ChatPart(text: fullText, thought: fullThought.isEmpty ? nil : fullThought)])
            chatHistory.append(modelMsg)
            saveHistoryInBackground()
        }
    }
    
    // ==========================================
    // 辅助方法：UI与存储
    // ==========================================
    
    private func appendLog(header: String, content: String, color: NSColor) {
        let paraStyle = NSMutableParagraphStyle()
        paraStyle.lineBreakMode = .byWordWrapping
        paraStyle.lineHeightMultiple = AppConfig.Fonts.lineHeightMult
        paraStyle.paragraphSpacing = 20
        
        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: AppConfig.Fonts.header,
            .foregroundColor: color,
            .paragraphStyle: paraStyle
        ]
        
        let contentAttrs: [NSAttributedString.Key: Any] = [
            .font: AppConfig.Fonts.text,
            .foregroundColor: color,
            .paragraphStyle: paraStyle
        ]
        
        let mas = NSMutableAttributedString()
        mas.append(NSAttributedString(string: "\(header)\n", attributes: headerAttrs))
        mas.append(NSAttributedString(string: "\(content)\n\n", attributes: contentAttrs))
        
        textContentStorage.performEditingTransaction {
            textContentStorage.textStorage?.append(mas)
        }
        
        scrollToBottom()
    }
    
    private func scrollToBottom() {
        DispatchQueue.main.async {
            self.textView.scrollToEndOfDocument(nil)
        }
    }
    
    private func setUIEnabled(_ enabled: Bool) {
        inputField.isEnabled = enabled
        sendButton.isEnabled = enabled
    }
    
    // ==========================================
    // 历史记录：异步 I/O
    // ==========================================
    
    private func loadHistoryFromDisk() {
        let fileURL = URL(fileURLWithPath: AppConfig.historyFilePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let data = try Data(contentsOf: fileURL)
                let loadedHistory = try JSONDecoder().decode([ChatMessage].self, from: data)
                
                DispatchQueue.main.async {
                    self.chatHistory = loadedHistory
                    self.appendLog(header: "[System]", content: "Restored \(loadedHistory.count) messages", color: AppConfig.Colors.system)
                    
                    for msg in loadedHistory {
                        let roleDisplay = msg.role == "user" ? "You" : "Gemini"
                        let color = msg.role == "user" ? AppConfig.Colors.user : AppConfig.Colors.model
                        let text = msg.parts.first?.text ?? ""
                        self.appendLog(header: roleDisplay, content: text, color: color)
                    }
                }
            } catch {
                print("Failed to load history: \(error)")
            }
        }
    }
    
    private func saveHistoryInBackground() {
        let historyToSave = self.chatHistory
        
        ioQueue.async {
            let fileURL = URL(fileURLWithPath: AppConfig.historyFilePath)
            do {
                let data = try JSONEncoder().encode(historyToSave)
                try data.write(to: fileURL, options: .atomic)
            } catch {
                print("Background save failed: \(error)")
            }
        }
    }
}

// ==========================================
// 4. App Entry
// ==========================================

class AppDelegate: NSObject, NSApplicationDelegate {
    var windowController: ChatWindowController!
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        windowController = ChatWindowController()
        windowController.showWindow(self)
        NSApp.activate(ignoringOtherApps: true)
        windowController.window?.makeKeyAndOrderFront(nil)
        windowController.window?.toggleFullScreen(nil)
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
    
    private func setupMainMenu() {
        let mainMenu = NSMenu()
        NSApp.mainMenu = mainMenu
        
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit Gemini", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    }
}

@main
struct GeminiApp {
    static func main() {
        if CommandLine.arguments.count > 1 {
            AppConfig.apiKey = CommandLine.arguments[1]
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
