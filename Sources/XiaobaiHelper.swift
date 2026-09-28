// xiaobai助手 · Mac 极简版 v0.2.0
// 匹配自动化：自动接受对局 / 自动开始匹配 / 自动重连 / 自动回到房间
// 纯官方 LCU 本地 API —— 无注入 / 无内存读写 / 无键鼠模拟

import SwiftUI
import AppKit
import Foundation

// MARK: - Lockfile

struct LockfileInfo { let port: Int; let password: String }

func discoverLockfile() -> LockfileInfo? {
    let fm = FileManager.default
    var candidates = ["/Applications/League of Legends.app/Contents/LoL/lockfile"]
    let home = fm.homeDirectoryForCurrentUser.path
    for dir in ["/Applications", home + "/Applications"] {
        if let es = try? fm.contentsOfDirectory(atPath: dir) {
            for e in es where e.hasSuffix(".app") {
                candidates.append("\(dir)/\(e)/Contents/LoL/lockfile")
            }
        }
    }
    for c in candidates {
        guard let s = try? String(contentsOfFile: c, encoding: .utf8) else { continue }
        let parts = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", omittingEmptySubsequences: false)
        if parts.count >= 5, let port = Int(parts[2]) {
            return LockfileInfo(port: port, password: String(parts[3]))
        }
    }
    return nil
}

// MARK: - LCU 客户端

enum LCUError: Error { case badResponse }

final class InsecureTrustDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ s: URLSession, didReceive ch: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if ch.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let t = ch.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: t))
        } else { completionHandler(.performDefaultHandling, nil) }
    }
}

final class LCUClient {
    private let base: String
    private let auth: String
    private let session: URLSession

    init(port: Int, password: String) {
        base = "https://127.0.0.1:\(port)"
        auth = "Basic " + Data("riot:\(password)".utf8).base64EncodedString()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 4
        cfg.timeoutIntervalForResource = 6
        session = URLSession(configuration: cfg, delegate: InsecureTrustDelegate(), delegateQueue: nil)
    }

    private func req(_ m: String, _ p: String) async throws -> (Data, HTTPURLResponse) {
        var r = URLRequest(url: URL(string: base + p)!)
        r.httpMethod = m
        r.setValue(auth, forHTTPHeaderField: "Authorization")
        let (d, resp) = try await session.data(for: r)
        guard let h = resp as? HTTPURLResponse else { throw LCUError.badResponse }
        return (d, h)
    }

    func get(_ p: String) async throws -> (Data, HTTPURLResponse) { try await req("GET", p) }
    func post(_ p: String) async throws -> (Data, HTTPURLResponse) { try await req("POST", p) }

    func phase() async throws -> String {
        let (d, h) = try await get("/lol-gameflow/v1/gameflow-phase")
        guard h.statusCode == 200 else { throw LCUError.badResponse }
        return String(data: d, encoding: .utf8)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\" \n\r")) ?? ""
    }
}

// MARK: - 阶段名

func phaseDisplay(_ raw: String) -> String {
    switch raw {
    case "": return "—"
    case "None": return "空闲"
    case "Lobby": return "房间"
    case "Matchmaking": return "排队中"
    case "ReadyCheck": return "等待确认"
    case "ChampSelect": return "选人"
    case "GameStart": return "游戏启动"
    case "InProgress": return "对局中"
    case "Reconnect": return "掉线重连"
    case "WaitingForStats": return "结算中"
    case "EndOfGame": return "结算完毕"
    case "TerminatedInError": return "异常退出"
    default: return raw
    }
}

// MARK: - 引擎

struct SearchState: Decodable { let searchState: String }
struct ReadyCheckState: Decodable { let state: String?; let playerResponse: String? }

@MainActor
final class Engine: ObservableObject {
    @Published var running = false
    @Published var connected = false
    @Published var phaseRaw = ""
    @Published var logs: [String] = []
    @Published var autoAccept = true
    @Published var autoStart = true
    @Published var autoReconnect = true
    @Published var autoPlayAgain = false
    @Published var acceptDelay: Double = 1
    @Published var showDonate = false
    @Published var gamePath = ""   // 空 = 自动识别

    private var pollTask: Task<Void, Never>?
    private var acceptTask: Task<Void, Never>?
    private var client: LCUClient?
    private var prevPhase = ""
    private var lastSearch: Date = .distantPast
    private var everLoggedWaiting = false
    private var handledReadyCheck = false

    // 游戏路径设置持久化（~/Library/Application Support/xiaobai助手/settings.json）
    private let settingsURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("xiaobai助手", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }()

    init() { loadGamePath() }

    private func loadGamePath() {
        if let d = try? Data(contentsOf: settingsURL),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            gamePath = obj["game_path"] as? String ?? ""
        }
    }

    func setGamePath(_ path: String) {
        gamePath = path
        if let d = try? JSONSerialization.data(withJSONObject: ["game_path": path],
                                               options: [.prettyPrinted]) {
            try? d.write(to: settingsURL)
        }
        log(path.isEmpty ? "游戏路径恢复自动识别" : "游戏路径已保存：\(path)")
    }

    func toggle() { running ? stop() : start() }

    func start() {
        running = true
        log("▶ 自动化已启动")
        pollTask = Task { await run() }
    }

    func stop() {
        running = false
        pollTask?.cancel(); acceptTask?.cancel()
        pollTask = nil; acceptTask = nil
        client = nil; connected = false
        phaseRaw = ""; prevPhase = ""
        everLoggedWaiting = false; handledReadyCheck = false
        log("■ 自动化已停止")
    }

    func log(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        logs.append("\(f.string(from: Date()))  \(s)")
        if logs.count > 200 { logs.removeFirst(logs.count - 200) }
    }

    private func run() async {
        while !Task.isCancelled {
            if client == nil {
                if let lf = discoverLockfile() {
                    client = LCUClient(port: lf.port, password: lf.password)
                    connected = true; everLoggedWaiting = false
                    prevPhase = ""; handledReadyCheck = false
                    log("已连接客户端（端口 \(lf.port)）")
                } else if !everLoggedWaiting {
                    connected = false
                    log("等待客户端启动…")
                    everLoggedWaiting = true
                }
            }
            if let c = client {
                do {
                    let p = try await c.phase()
                    phaseRaw = p
                    if p != prevPhase {
                        log("阶段 → \(phaseDisplay(p))")
                        if p != "ReadyCheck" { handledReadyCheck = false }
                        prevPhase = p
                    }
                    if p == "ReadyCheck" && autoAccept && !handledReadyCheck {
                        handledReadyCheck = true
                        acceptTask = Task { [weak self] in await self?.doAccept(client: c) }
                    }
                    if p == "Lobby" && autoStart { await tryAutoStart(client: c) }
                } catch {
                    if connected { connected = false; log("连接出错，重新发现客户端…") }
                    client = nil; prevPhase = ""; phaseRaw = ""
                }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func doAccept(client c: LCUClient) async {
        if acceptDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(acceptDelay * 1_000_000_000)) }
        var logged = false
        var failLogged = false
        for _ in 0..<30 {
            guard !Task.isCancelled, phaseRaw == "ReadyCheck" else { return }
            var needAccept = true
            if let (d, h) = try? await c.get("/lol-matchmaking/v1/ready-check"),
               h.statusCode == 200,
               let rc = try? JSONDecoder().decode(ReadyCheckState.self, from: d) {
                if let pr = rc.playerResponse, pr.lowercased() != "none" {
                    if !logged { log("已手动接受，跳过") }
                    return
                }
            }
            if needAccept {
                if let (_, h2) = try? await c.post("/lol-matchmaking/v1/ready-check/accept"),
                   (200..<300).contains(h2.statusCode) {
                    if !logged { log("已自动接受对局（延迟 \(Int(acceptDelay))s）"); logged = true }
                    failLogged = false
                } else if !failLogged {
                    log("接受请求失败，重试中…")
                    failLogged = true
                }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func tryAutoStart(client c: LCUClient) async {
        guard Date().timeIntervalSince(lastSearch) >= 5 else { return }
        lastSearch = Date()
        guard let (d, h) = try? await c.get("/lol-lobby/v2/lobby/matchmaking/search-state"),
              h.statusCode == 200,
              let st = try? JSONDecoder().decode(SearchState.self, from: d),
              st.searchState == "Invalid" else { return }
        _ = try? await c.post("/lol-lobby/v2/lobby/matchmaking/search")
        log("已自动开始匹配")
    }

    // 一键启动游戏客户端：自定义路径优先，否则自动识别
    func launchGame() {
        if !gamePath.isEmpty {
            if FileManager.default.fileExists(atPath: gamePath) {
                NSWorkspace.shared.open(URL(fileURLWithPath: gamePath))
                log("已启动游戏客户端（自定义路径）")
                return
            }
            log("自定义路径已失效，改用自动识别")
        }
        let candidates = [
            "/Applications/League of Legends.app",
            FileManager.default.homeDirectoryForCurrentUser.path + "/Applications/League of Legends.app",
            "/Users/Shared/Riot Games/Riot Client.app",
        ]
        for p in candidates where FileManager.default.fileExists(atPath: p) {
            NSWorkspace.shared.open(URL(fileURLWithPath: p))
            log("已启动游戏客户端：\(URL(fileURLWithPath: p).lastPathComponent)")
            return
        }
        log("未找到游戏客户端，可在「游戏路径」手动指定")
    }
}

// MARK: - 界面（窗口锁定 300×430，按钮通栏）

private let bg = Color(red: 0.961, green: 0.961, blue: 0.969)
private let cardColor = Color.white
private let accent = Color(red: 0, green: 0.443, blue: 0.890)
private let sub = Color(red: 0.45, green: 0.45, blue: 0.47)
private let ink = Color(red: 0.1, green: 0.1, blue: 0.12)

struct ContentView: View {
    @EnvironmentObject var engine: Engine

    var body: some View {
        VStack(spacing: 8) {
            header
            mainButton
            launchRow
            settingsCard
            logCard
        }
        .padding(12)
        .frame(width: 300, height: 430)
        .background(bg)
        .preferredColorScheme(.light)
        .sheet(isPresented: $engine.showDonate) { DonateSheet(show: $engine.showDonate) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("xiaobai助手")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(ink)
            Spacer()
            Button(action: { engine.showDonate = true }) {
                Text("打赏 ❤")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(accent)
            }
            .buttonStyle(.plain)
            HStack(spacing: 4) {
                Circle().fill(engine.connected ? Color.green : Color.gray).frame(width: 7, height: 7)
                Text(engine.connected ? "已连接" : "未连接").font(.system(size: 10)).foregroundColor(sub)
            }
        }
    }

    private var mainButton: some View {
        Button(action: { engine.toggle() }) {
            Text(engine.running ? "■ 停止自动化" : "▶ 启动自动化")
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(.plain)
        .background(engine.running ? Color(red: 1.0, green: 0.24, blue: 0.24) : accent)
        .foregroundColor(.white)
        .cornerRadius(8)
    }

    // 一键启动游戏（次按钮，浅灰底）
    private var launchRow: some View {
        Button(action: { engine.launchGame() }) {
            Text("🎮 启动游戏")
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 26)
        }
        .buttonStyle(.plain)
        .background(Color(red: 0.88, green: 0.89, blue: 0.91))
        .foregroundColor(ink)
        .cornerRadius(8)
    }

    // 手动指定游戏客户端路径（选 .app 包）
    private func pickGamePath() {
        let panel = NSOpenPanel()
        panel.title = "选择游戏客户端"
        panel.message = "选择 League of Legends.app 或 Riot Client.app"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url {
            engine.setGamePath(url.path)
        }
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("自动化选项").font(.system(size: 10, weight: .semibold)).foregroundColor(sub)
            Toggle("自动接受对局", isOn: $engine.autoAccept).foregroundColor(ink)
            HStack {
                Toggle("自动开始匹配", isOn: $engine.autoStart)
                Picker("", selection: $engine.acceptDelay) {
                    Text("1s").tag(Double(1)); Text("3s").tag(Double(3)); Text("5s").tag(Double(5))
                }
                .pickerStyle(.segmented).frame(width: 100).disabled(!engine.autoAccept)
            }
            Toggle("自动重连", isOn: $engine.autoReconnect).foregroundColor(ink)
            Toggle("自动回到房间", isOn: $engine.autoPlayAgain).foregroundColor(ink)
            HStack(spacing: 6) {
                Text(engine.gamePath.isEmpty ? "游戏路径：自动识别" : "游戏路径：自定义")
                    .font(.system(size: 10))
                    .foregroundColor(sub)
                Spacer()
                if !engine.gamePath.isEmpty {
                    Button("默认") { engine.setGamePath("") }
                        .font(.system(size: 10)).controlSize(.small)
                }
                Button("更改") { pickGamePath() }
                    .font(.system(size: 10)).controlSize(.small)
            }
        }
        .font(.system(size: 11))
        .padding(10)
        .background(cardColor)
        .cornerRadius(8)
    }

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("运行状态").font(.system(size: 10, weight: .semibold)).foregroundColor(sub)
                Spacer()
                Text("当前：\(phaseDisplay(engine.phaseRaw))")
                    .font(.system(size: 10, weight: .medium)).foregroundColor(accent)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if engine.logs.isEmpty {
                            Text("等待运行…").font(.system(size: 9, design: .monospaced)).foregroundColor(sub)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ForEach(Array(engine.logs.enumerated()), id: \.offset) { i, line in
                                Text(line).font(.system(size: 9, design: .monospaced)).foregroundColor(ink)
                                    .frame(maxWidth: .infinity, alignment: .leading).id(i)
                            }
                        }
                    }
                    .padding(5)
                }
                .background(Color(red: 0.97, green: 0.97, blue: 0.98))
                .cornerRadius(6)
                .onChange(of: engine.logs.count) { _ in
                    if let last = engine.logs.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
        .padding(10)
        .background(cardColor)
        .cornerRadius(8)
    }
}

@main
struct XiaobaiHelperApp: App {
    var body: some Scene {
        WindowGroup("xiaobai助手") {
            ContentView().environmentObject(Engine())
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - 打赏弹窗

struct DonateSheet: View {
    @Binding var show: Bool

    var body: some View {
        VStack(spacing: 10) {
            Text("感谢支持 xiaobai助手")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(ink)
            Group {
                if let url = Bundle.main.url(forResource: "donate", withExtension: "jpg"),
                   let img = NSImage(contentsOf: url) {
                    Image(nsImage: img).resizable().scaledToFit()
                } else {
                    Text("未找到打赏码资源").font(.system(size: 11)).foregroundColor(sub)
                }
            }
            .frame(maxHeight: 280)
            .cornerRadius(8)
            Text("微信扫码打赏").font(.system(size: 10)).foregroundColor(sub)
            Button(action: { show = false }) {
                Text("关闭").font(.system(size: 11)).frame(minWidth: 80, minHeight: 24)
            }
            .buttonStyle(.plain)
            .background(accent).foregroundColor(.white).cornerRadius(6)
        }
        .padding(14)
        .frame(width: 300, height: 430)
        .background(bg)
        .preferredColorScheme(.light)
    }
}
