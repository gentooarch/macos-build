import Cocoa
import Foundation
import AVKit
import CoreMedia

// MARK: - ★★★ 配置区域 ★★★

let YTDLP_PATH = "/opt/homebrew/bin/yt-dlp" // 请确保路径正确
let DOWNLOAD_DIR = "/tmp"
let COOKIE_FILE_PATH = "/tmp/bili_safari_cookies.txt"

let FEED_COUNT = 30
let FORMAT_STRING = "100026+30216/30080+30216/bestvideo+bestaudio/best"

// MARK: - 0. 辅助工具 & 视图

class InteractiveListView: NSView {
    override var isFlipped: Bool { return true }
    override var acceptsFirstResponder: Bool { return true }
    var onKeyDown: ((NSEvent) -> Void)?
    
    override func keyDown(with event: NSEvent) {
        if let onKeyDown = onKeyDown { onKeyDown(event) } else { super.keyDown(with: event) }
    }
}

class CustomPlayerView: AVPlayerView { }

// MARK: - 1. 数据模型

// 统一的视频模型（用于 UI 显示）
struct BiliVideo: Codable {
    let title: String
    let pic: String
    let ownerName: String
    let viewCount: Int
    let bvid: String
}

// --- 推荐接口模型 ---
struct RcmdResponse: Codable { let code: Int; let message: String?; let data: RcmdData? }
struct RcmdData: Codable { let item: [RcmdItem]? }
struct RcmdItem: Codable {
    let title: String; let pic: String
    let owner: RcmdOwner; let stat: RcmdStat; let bvid: String
}
struct RcmdOwner: Codable { let name: String }
struct RcmdStat: Codable { let view: Int }

// --- ★★★ 搜索接口模型 ★★★ ---
struct SearchResponse: Codable { let code: Int; let message: String?; let data: SearchData? }
struct SearchData: Codable { let result: [SearchItem]? }
struct SearchItem: Codable {
    let title: String
    let pic: String
    let author: String
    let play: Int // 搜索接口返回的播放量通常是 Int
    let bvid: String
}

// MARK: - 2. Cookie 管理器

class CookieManager {
    static let shared = CookieManager()
    var sessData: String = ""
    
    func extractCookiesFromSafari(completion: @escaping (Bool, String) -> Void) {
        try? FileManager.default.removeItem(atPath: COOKIE_FILE_PATH)
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: YTDLP_PATH)
        process.currentDirectoryURL = URL(fileURLWithPath: DOWNLOAD_DIR)
        
        process.arguments = [
            "--cookies-from-browser", "safari",
            "--cookies", COOKIE_FILE_PATH,
            "--skip-download",
            "--no-warnings",
            "https://www.bilibili.com"
        ]
        
        print("🍪 [Cookie] 开始提取 Safari Cookies...")
        
        DispatchQueue.global(qos: .userInitiated).async {
            try? process.run()
            process.waitUntilExit()
            
            if FileManager.default.fileExists(atPath: COOKIE_FILE_PATH) {
                if let sess = self.parseSessDataFromFile() {
                    self.sessData = sess
                    print("🍪 [Cookie] 提取成功，SESSDATA 已获取")
                    completion(true, "Cookie 同步成功")
                } else {
                    print("⚠️ [Cookie] 文件生成但未找到 SESSDATA")
                    completion(true, "Cookie 文件已生成 (无 SESSDATA)")
                }
            } else {
                print("❌ [Cookie] 导出失败")
                completion(false, "Cookie 导出失败")
            }
        }
    }
    
    private func parseSessDataFromFile() -> String? {
        guard let content = try? String(contentsOfFile: COOKIE_FILE_PATH, encoding: .utf8) else { return nil }
        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            if line.hasPrefix("#") || line.isEmpty { continue }
            let parts = line.components(separatedBy: "\t")
            if parts.count >= 7 && parts[5] == "SESSDATA" {
                return parts[6].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }
}

// MARK: - 3. 主应用逻辑

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate {
    var window: NSWindow!
    var scrollView: NSScrollView!
    var documentView: InteractiveListView!
    var statusLabel: NSTextField!
    
    // ★★★ 搜索控件 ★★★
    var searchField: NSTextField!
    var searchBtn: NSButton!
    
    var playerView: CustomPlayerView?
    var currentPlayingPath: String?
    var playerEventMonitor: Any?
    
    var currentList: [BiliVideo] = []
    var currentDataTask: URLSessionDataTask?
    let topBarHeight: CGFloat = 60
    var selectedIndex: Int = 0
    
    // 尺寸配置
    let cardHeight: CGFloat = 220
    let imageWidth: CGFloat = 320
    let imageHeight: CGFloat = 180
    let titleFontSize: CGFloat = 26
    let infoFontSize: CGFloat = 18

    lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let windowRect = NSRect(x: 0, y: 0, width: 1400, height: 1000)
        window = NSWindow(
            contentRect: windowRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Bili Player (Search Edition)"
        window.center()
        window.delegate = self
        
        let contentView = NSView(frame: windowRect)
        contentView.wantsLayer = true
        window.contentView = contentView
        
        // --- Top Bar ---
        let topBar = NSView()
        topBar.wantsLayer = true
        topBar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        topBar.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(topBar)
        
        // 刷新按钮
        let refreshBtn = NSButton(title: "刷新推荐 (R)", target: self, action: #selector(refreshLogic))
        refreshBtn.bezelStyle = .rounded
        refreshBtn.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(refreshBtn)
        
        // Cookie 按钮
        let cookieBtn = NSButton(title: "同步 Cookie", target: self, action: #selector(syncCookiesBtn))
        cookieBtn.bezelStyle = .rounded
        cookieBtn.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(cookieBtn)
        
        // ★★★ 搜索框 ★★★
        searchField = NSTextField()
        searchField.placeholderString = "搜索视频..."
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.target = self
        searchField.action = #selector(triggerSearch) // 回车触发
        topBar.addSubview(searchField)
        
        // ★★★ 搜索按钮 ★★★
        searchBtn = NSButton(title: "搜索", target: self, action: #selector(triggerSearch))
        searchBtn.bezelStyle = .rounded
        searchBtn.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(searchBtn)
        
        // 状态标签
        statusLabel = NSTextField(labelWithString: "准备就绪")
        statusLabel.font = .systemFont(ofSize: 14)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(statusLabel)
        
        // --- List View ---
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(scrollView)
        
        documentView = InteractiveListView(frame: NSRect(x: 0, y: 0, width: 1000, height: 10))
        documentView.wantsLayer = true
        documentView.onKeyDown = { [weak self] event in self?.handleListKeyDown(event) }
        scrollView.documentView = documentView
        
        // --- Layout ---
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: contentView.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: topBarHeight + 30),
            
            refreshBtn.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 20),
            refreshBtn.bottomAnchor.constraint(equalTo: topBar.bottomAnchor, constant: -12),
            
            cookieBtn.leadingAnchor.constraint(equalTo: refreshBtn.trailingAnchor, constant: 12),
            cookieBtn.bottomAnchor.constraint(equalTo: refreshBtn.bottomAnchor),
            
            // 搜索框布局
            searchField.leadingAnchor.constraint(equalTo: cookieBtn.trailingAnchor, constant: 20),
            searchField.bottomAnchor.constraint(equalTo: refreshBtn.bottomAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 250),
            searchField.heightAnchor.constraint(equalToConstant: 22),
            
            searchBtn.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 8),
            searchBtn.bottomAnchor.constraint(equalTo: refreshBtn.bottomAnchor),
            
            statusLabel.leadingAnchor.constraint(equalTo: searchBtn.trailingAnchor, constant: 15),
            statusLabel.centerYAnchor.constraint(equalTo: searchBtn.centerYAnchor),
            
            scrollView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
        
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        syncCookies(autoFetch: true)
    }

    @objc func syncCookiesBtn() { syncCookies(autoFetch: true) }

    func syncCookies(autoFetch: Bool = false) {
        updateStatus("正在提取 Cookies...")
        CookieManager.shared.extractCookiesFromSafari { [weak self] success, msg in
            DispatchQueue.main.async {
                self?.updateStatus(msg)
                if autoFetch || success { self?.loadRecommendData() }
            }
        }
    }
    
    @objc func refreshLogic() { loadRecommendData() }

    // MARK: - ★★★ 搜索逻辑 (带错误输出) ★★★
    @objc func triggerSearch() {
        let keyword = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else {
            updateStatus("请输入搜索关键词")
            return
        }
        
        currentDataTask?.cancel()
        updateStatus("正在搜索: \(keyword)...")
        print("🔍 [Search] 开始搜索关键词: \(keyword)")
        
        // 构造搜索 URL
        guard let encodedKeyword = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return }
        let urlStr = "https://api.bilibili.com/x/web-interface/search/type?search_type=video&keyword=\(encodedKeyword)"
        
        guard let url = URL(string: urlStr) else {
            print("❌ [Search] URL构造失败: \(urlStr)")
            return
        }
        
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        // 搜索通常需要 Referer
        req.setValue("https://search.bilibili.com", forHTTPHeaderField: "Referer")
        
        let sessData = CookieManager.shared.sessData
        if !sessData.isEmpty { req.setValue("SESSDATA=\(sessData)", forHTTPHeaderField: "Cookie") }
        
        print("🔍 [Search] Request URL: \(url.absoluteString)")
        
        currentDataTask = session.dataTask(with: req) { [weak self] data, response, error in
            if let error = error {
                print("❌ [Network Error] 请求失败: \(error.localizedDescription)")
                self?.updateStatus("网络错误")
                return
            }
            
            if let httpResp = response as? HTTPURLResponse {
                print("📡 [Search] HTTP Status Code: \(httpResp.statusCode)")
                if httpResp.statusCode != 200 {
                    print("❌ [Search] HTTP 状态码异常")
                }
            }
            
            guard let data = data else {
                print("❌ [Search] 未接收到数据")
                return
            }
            
            // 调试用：打印原始 JSON (如果太长可以注释掉)
            // if let jsonStr = String(data: data, encoding: .utf8) {
            //    print("📄 [Search Raw Data]: \(jsonStr.prefix(500))... (truncated)")
            // }
            
            do {
                let decoder = JSONDecoder()
                let res = try decoder.decode(SearchResponse.self, from: data)
                
                if res.code == 0, let list = res.data?.result {
                    print("✅ [Search] 解析成功，获取到 \(list.count) 个视频")
                    
                    let videos = list.map { item -> BiliVideo in
                        // 去除标题中的 HTML 标签 (e.g. <em class="keyword">...</em>)
                        let rawTitle = item.title
                        let cleanTitle = rawTitle.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil)
                        
                        return BiliVideo(
                            title: cleanTitle,
                            pic: item.pic,
                            ownerName: item.author,
                            viewCount: item.play,
                            bvid: item.bvid
                        )
                    }
                    
                    DispatchQueue.main.async {
                        if videos.isEmpty {
                            self?.updateStatus("未找到相关视频")
                            print("⚠️ [Search] 结果列表为空")
                        } else {
                            self?.currentList = videos
                            self?.selectedIndex = 0
                            self?.renderList(videos)
                            self?.statusLabel.stringValue = "搜索结果: \(keyword) (Enter下载)"
                            self?.window.makeFirstResponder(self?.documentView)
                        }
                    }
                } else {
                    print("❌ [Search] API 返回错误码: \(res.code), Message: \(res.message ?? "nil")")
                    // 如果解析结构不匹配，往往会抛出 Catch block 的错误，这里处理逻辑错误
                    self?.updateStatus("API 错误: \(res.message ?? "未知")")
                }
                
            } catch {
                print("❌ [Search JSON Error] 解析失败: \(error)")
                // 打印一部分数据以便调试
                if let str = String(data: data, encoding: .utf8) {
                    print("📄 [Data content]: \(str)")
                }
                self?.updateStatus("搜索结果解析失败，请看控制台")
            }
        }
        currentDataTask?.resume()
    }

    // MARK: - 键盘 & 交互
    func handleListKeyDown(_ event: NSEvent) {
        guard !currentList.isEmpty else { return }
        let chars = event.charactersIgnoringModifiers?.lowercased()
        switch event.keyCode {
        case 36: triggerSelection() // Enter
        case 126: moveSelection(-1) // Up
        case 125: moveSelection(1)  // Down
        case 116: scrollPage(direction: -1) // PageUp
        case 121: scrollPage(direction: 1)  // PageDown
        default: if chars == "r" { loadRecommendData() }
        }
    }
    
    func moveSelection(_ delta: Int) {
        let newIndex = selectedIndex + delta
        if newIndex >= 0 && newIndex < currentList.count {
            selectedIndex = newIndex
            updateSelectionVisuals()
        }
    }
    
    func updateSelectionVisuals() {
        let subviews = documentView.subviews
        for (i, view) in subviews.enumerated() {
            if i == selectedIndex {
                view.layer?.borderColor = NSColor.darkGray.cgColor
                view.layer?.borderWidth = 5
                view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.1).cgColor
                
                var scrollRect = view.frame
                scrollRect.origin.y -= 10
                scrollRect.size.height += 20
                documentView.scrollToVisible(scrollRect)
            } else {
                view.layer?.borderColor = NSColor.separatorColor.cgColor
                view.layer?.borderWidth = 1
                view.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            }
        }
    }
    
    func scrollPage(direction: Int) {
        let pageHeight = scrollView.contentSize.height
        let currentPoint = scrollView.contentView.bounds.origin
        var newY = currentPoint.y + (CGFloat(direction) * pageHeight)
        let maxY = documentView.frame.height - pageHeight
        newY = max(0, min(newY, maxY))
        
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: newY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func triggerSelection() {
        guard selectedIndex >= 0 && selectedIndex < currentList.count else { return }
        startDownloadProcess(video: currentList[selectedIndex])
    }

    @objc func cardClicked(_ sender: NSClickGestureRecognizer) {
        guard let bvid = sender.view?.identifier?.rawValue else { return }
        if let idx = currentList.firstIndex(where: { $0.bvid == bvid }) {
            selectedIndex = idx
            updateSelectionVisuals()
            triggerSelection()
        }
    }
    
    // MARK: - 下载 & 播放
    func startDownloadProcess(video: BiliVideo) {
        let videoUrl = "https://www.bilibili.com/video/\(video.bvid)"
        updateStatus("正在处理: \(video.title)...")
        DispatchQueue.global(qos: .userInitiated).async {
            self.runDownloadAndPlay(url: videoUrl, displayTitle: video.title)
        }
    }
    
    func runDownloadAndPlay(url: String, displayTitle: String) {
        updateStatus("正在下载 (yt-dlp)...")
        print("🎬 [Download] 开始下载: \(displayTitle) -> \(url)")
        
        let ytProcess = Process()
        ytProcess.executableURL = URL(fileURLWithPath: YTDLP_PATH)
        ytProcess.currentDirectoryURL = URL(fileURLWithPath: DOWNLOAD_DIR)
        
        var args = [
            "--format", FORMAT_STRING,
            "--merge-output-format", "mp4",
            "--no-part", "--no-mtime",
            "--replace-in-metadata", "title", "[^0-9A-Za-z\\u4e00-\\u9fa5]+", "",
            "-o", "%(title)s_%(id)s.%(ext)s",
            "--print", "after_move:filepath",
            url
        ]
        
        if FileManager.default.fileExists(atPath: COOKIE_FILE_PATH) {
            args.insert(contentsOf: ["--cookies", COOKIE_FILE_PATH], at: 0)
        } else {
            args.insert(contentsOf: ["--cookies-from-browser", "safari"], at: 0)
        }
        
        ytProcess.arguments = args
        let pipe = Pipe()
        let errorPipe = Pipe() // 捕获标准错误输出以便排查 yt-dlp 错误
        ytProcess.standardOutput = pipe
        ytProcess.standardError = errorPipe
        
        do {
            try ytProcess.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            
            let finalOutput = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
            
            ytProcess.waitUntilExit()
            
            if !finalOutput.isEmpty && FileManager.default.fileExists(atPath: finalOutput) {
                print("✅ [Download] 成功，文件路径: \(finalOutput)")
                updateStatus("下载成功！")
                DispatchQueue.main.async { self.playVideoInApp(filePath: finalOutput) }
            } else {
                print("❌ [Download] 失败。Code: \(ytProcess.terminationStatus)")
                print("❌ [Download Error Log]: \(errorOutput)")
                updateStatus("下载失败 (code: \(ytProcess.terminationStatus))")
            }
        } catch {
            print("❌ [Execution Error]: \(error)")
            updateStatus("执行错误: \(error.localizedDescription)")
        }
    }
    
    func playVideoInApp(filePath: String) {
        guard let contentView = window.contentView else { return }
        closePlayer()
        currentPlayingPath = filePath
        let player = AVPlayer(url: URL(fileURLWithPath: filePath))
        let pView = CustomPlayerView()
        pView.player = player
        pView.controlsStyle = .floating
        pView.translatesAutoresizingMaskIntoConstraints = false
        pView.wantsLayer = true
        pView.layer?.backgroundColor = NSColor.black.cgColor
        contentView.addSubview(pView)
        self.playerView = pView
        
        NSLayoutConstraint.activate([
            pView.topAnchor.constraint(equalTo: contentView.topAnchor),
            pView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            pView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            pView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        ])
        
        playerEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.playerView != nil else { return event }
            let chars = event.charactersIgnoringModifiers?.lowercased()
            if event.keyCode == 123 { self.adjustPlayerProgress(by: -10); return nil }
            if event.keyCode == 124 { self.adjustPlayerProgress(by: 10); return nil }
            if chars == "q" { self.closePlayer(); return nil }
            if chars == "d" { self.deleteCurrentVideo(); return nil }
            return event
        }
        
        window.makeFirstResponder(pView)
        player.play()
        updateStatus("播放: [←/→] 10s [Q]退出 [D]删除")
    }
    
    func adjustPlayerProgress(by seconds: Double) {
        guard let player = playerView?.player else { return }
        let currentSeconds = CMTimeGetSeconds(player.currentTime())
        let targetTime = CMTime(seconds: currentSeconds + seconds, preferredTimescale: 600)
        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }
    
    func deleteCurrentVideo() {
        guard let path = currentPlayingPath else { return }
        playerView?.player?.pause()
        try? FileManager.default.removeItem(atPath: path)
        print("🗑 [File] 已删除: \(path)")
        closePlayer()
        updateStatus("已删除本地文件")
    }
    
    func closePlayer() {
        if let monitor = playerEventMonitor { NSEvent.removeMonitor(monitor); playerEventMonitor = nil }
        playerView?.player?.pause()
        playerView?.removeFromSuperview()
        playerView = nil
        currentPlayingPath = nil
        window.makeFirstResponder(documentView)
    }
    
    func updateStatus(_ text: String) {
        DispatchQueue.main.async { self.statusLabel.stringValue = text }
    }

    // MARK: - 推荐网络请求
    @objc func loadRecommendData() {
        currentDataTask?.cancel()
        statusLabel.stringValue = "正在获取推荐列表..."
        print("🌐 [Recommend] 开始请求推荐列表...")
        
        let url = "https://api.bilibili.com/x/web-interface/index/top/feed/rcmd?ps=\(FEED_COUNT)"
        guard let u = URL(string: url) else { return }
        
        var req = URLRequest(url: u)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        
        let sessData = CookieManager.shared.sessData
        if !sessData.isEmpty { req.setValue("SESSDATA=\(sessData)", forHTTPHeaderField: "Cookie") }
        
        currentDataTask = self.session.dataTask(with: req) { [weak self] data, response, error in
            if let error = error {
                 print("❌ [Recommend Error]: \(error)")
                 return
            }
            guard let data = data else { return }
            do {
                let res = try JSONDecoder().decode(RcmdResponse.self, from: data)
                if res.code == 0 {
                    print("✅ [Recommend] 获取成功: \(res.data?.item?.count ?? 0) 条数据")
                    let videos = (res.data?.item ?? []).map {
                        BiliVideo(title: $0.title, pic: $0.pic, ownerName: $0.owner.name, viewCount: $0.stat.view, bvid: $0.bvid)
                    }
                    DispatchQueue.main.async {
                        self?.currentList = videos
                        self?.selectedIndex = 0
                        self?.renderList(videos)
                        self?.statusLabel.stringValue = "列表更新成功 (↑/↓选择, Enter下载)"
                        self?.window.makeFirstResponder(self?.documentView)
                    }
                } else {
                    print("❌ [Recommend] API Error Code: \(res.code)")
                }
            } catch {
                print("❌ [Recommend Decode Error]: \(error)")
                self?.updateStatus("解析失败，请检查 Cookie")
            }
        }
        currentDataTask?.resume()
    }

    // MARK: - UI 渲染
    func renderList(_ list: [BiliVideo]) {
        documentView.subviews.forEach { $0.removeFromSuperview() }
        let contentWidth = scrollView.bounds.width
        let sidePadding: CGFloat = 40
        let spacing: CGFloat = 25
        
        let cardWidth = min(contentWidth - (sidePadding * 2), 1200)
        let leftMargin = (contentWidth - cardWidth) / 2
        let totalHeight = CGFloat(list.count) * (cardHeight + spacing) + spacing
        
        documentView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: totalHeight)
        
        for (i, video) in list.enumerated() {
            let yPos = spacing + CGFloat(i) * (cardHeight + spacing)
            let card = NSView(frame: NSRect(x: leftMargin, y: yPos, width: cardWidth, height: cardHeight))
            card.wantsLayer = true
            card.layer?.cornerRadius = 16
            card.layer?.borderColor = NSColor.separatorColor.cgColor
            card.layer?.borderWidth = 1
            card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            
            // 封面图
            let imgView = NSImageView(frame: NSRect(x: 20, y: 20, width: imageWidth, height: imageHeight))
            imgView.imageScaling = .scaleAxesIndependently
            imgView.wantsLayer = true
            imgView.layer?.cornerRadius = 10
            imgView.layer?.masksToBounds = true
            card.addSubview(imgView)
            downloadImage(video.pic, to: imgView)
            
            // 标题
            let titleLabel = NSTextField(labelWithString: video.title)
            titleLabel.frame = NSRect(x: imageWidth + 45, y: 90, width: cardWidth - imageWidth - 65, height: 110)
            titleLabel.maximumNumberOfLines = 2
            titleLabel.font = .systemFont(ofSize: titleFontSize, weight: .bold)
            titleLabel.lineBreakMode = .byWordWrapping
            card.addSubview(titleLabel)
            
            // 信息栏
            let infoLabel = NSTextField(labelWithString: "UP: \(video.ownerName)  |  播放: \(formatViewCount(video.viewCount))")
            infoLabel.frame = NSRect(x: imageWidth + 45, y: 35, width: cardWidth - imageWidth - 65, height: 35)
            infoLabel.font = .systemFont(ofSize: infoFontSize)
            infoLabel.textColor = .secondaryLabelColor
            card.addSubview(infoLabel)
            
            let click = NSClickGestureRecognizer(target: self, action: #selector(cardClicked(_:)))
            card.addGestureRecognizer(click)
            card.identifier = NSUserInterfaceItemIdentifier(video.bvid)
            documentView.addSubview(card)
        }
        updateSelectionVisuals()
    }
    
    func formatViewCount(_ count: Int) -> String {
        if count > 10000 { return String(format: "%.1f万", Double(count)/10000.0) }
        return "\(count)"
    }

    func downloadImage(_ urlStr: String, to view: NSImageView) {
        let cleanUrl = urlStr.hasPrefix("//") ? "https:" + urlStr : urlStr
        guard let url = URL(string: cleanUrl) else { return }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        self.session.dataTask(with: req) { data, _, _ in
            if let d = data, let img = NSImage(data: d) { 
                DispatchQueue.main.async { view.image = img } 
            }
        }.resume()
    }

    func windowDidResize(_ notification: Notification) { if !currentList.isEmpty { renderList(currentList) } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
