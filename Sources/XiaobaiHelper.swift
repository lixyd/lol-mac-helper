// xiaobai助手 · Mac 极简版 v0.8.0
// 匹配自动化：自动接受对局 / 自动开始匹配 / 自动重连 / 自动回到房间 / 备战席抢英雄
// 自动领取：奖励（lol-rewards）/ 任务（lol-missions）/ 事件中心（lol-event-hub）
// 游戏开始自动隐藏窗口，结束自动弹出（默认开启）
// 纯官方 LCU 本地 API —— 无注入 / 无内存读写 / 无键鼠模拟

import SwiftUI
import AppKit
import CoreGraphics
import Foundation

// MARK: - 查找游戏客户端窗口位置（不需要任何权限）

func clientWindowRect() -> CGRect? {
    let opts = CGWindowListOption([.optionOnScreenOnly, .excludeDesktopElements])
    guard let list = CGWindowListCopyWindowInfo(opts, CGWindowID(0)) as? [[String: Any]] else { return nil }
    var best: CGRect? = nil
    for w in list {
        guard (w[kCGWindowLayer as String] as? Int ?? -1) == 0 else { continue }
        let owner = w[kCGWindowOwnerName as String] as? String ?? ""
        guard owner.contains("League of Legends") || owner.contains("LeagueClientUx") else { continue }
        guard let raw = w[kCGWindowBounds as String],
              let r = CGRect(dictionaryRepresentation: raw as! CFDictionary) else { continue }
        guard r.width > 300, r.height > 200 else { continue }
        if best == nil || r.width * r.height > best!.width * best!.height { best = r }
    }
    return best
}

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

    private func req(_ m: String, _ p: String, _ body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        var r = URLRequest(url: URL(string: base + p)!)
        r.httpMethod = m
        r.setValue(auth, forHTTPHeaderField: "Authorization")
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = body
        }
        let (d, resp) = try await session.data(for: r)
        guard let h = resp as? HTTPURLResponse else { throw LCUError.badResponse }
        return (d, h)
    }

    func get(_ p: String) async throws -> (Data, HTTPURLResponse) { try await req("GET", p) }
    func post(_ p: String) async throws -> (Data, HTTPURLResponse) { try await req("POST", p) }
    func put(_ p: String) async throws -> (Data, HTTPURLResponse) { try await req("PUT", p) }
    func postBody(_ p: String, _ body: Data) async throws -> (Data, HTTPURLResponse) { try await req("POST", p, body) }
    func putBody(_ p: String, _ body: Data) async throws -> (Data, HTTPURLResponse) { try await req("PUT", p, body) }

    // 读取 LCU 内置资源（英雄头像等），带认证
    func imageData(_ path: String) async -> NSImage? {
        guard let url = URL(string: base + path) else { return nil }
        var r = URLRequest(url: url)
        r.setValue(auth, forHTTPHeaderField: "Authorization")
        r.timeoutInterval = 3
        if let (d, _) = try? await session.data(for: r) { return NSImage(data: d) }
        return nil
    }

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
struct LobbyMember: Decodable { let isLeader: Bool?; let ready: Bool? }
struct LobbyInfo: Decodable {
    let canStartActivity: Bool?
    let localMember: LobbyMember?
}
struct ChampSelectSession: Decodable {
    let benchEnabled: Bool?
    let benchChampions: [BenchChampion]?
}
struct BenchChampion: Decodable { let championId: Int }

// MARK: - 自动领取数据结构（对齐 LeagueAkari 的 claim-tools）

// lol-rewards：宝箱 / 胶囊 / 图标等（status=PENDING_SELECTION 为待领取）
struct RewardGrant: Decodable {
    struct Info: Decodable { let id: String }
    struct RewardGroup: Decodable {
        let id: String
        let rewards: [GrantReward]?
        let selectionStrategyConfig: SelectionConfig?
        let localizations: [String: String]?
    }
    struct GrantReward: Decodable { let id: String; let localizations: [String: String]? }
    struct SelectionConfig: Decodable {
        let maxSelectionsAllowed: Int?
        let minSelectionsAllowed: Int?
    }
    let info: Info
    let rewardGroup: RewardGroup
}

// lol-missions：任务奖励（status=SELECT_REWARDS 为待选择领取）
struct MissionEntry: Decodable {
    struct Reward: Decodable { let rewardGroup: String; let description: String? }
    struct Strategy: Decodable {
        let selectMaxGroupCount: Int?
        let selectMinGroupCount: Int?
    }
    let id: String
    let status: String?
    let title: String?
    let rewards: [Reward]?
    let rewardStrategy: Strategy?
}

// lol-event-hub：事件中心奖励轨（unclaimedRewardCount > 0 为有待领）
struct EventHubEntry: Decodable {
    struct Info: Decodable {
        let eventId: String?
        let eventName: String?
        let unclaimedRewardCount: Int?
    }
    let eventId: String
    let eventInfo: Info
}

// localizations 字段在不同客户端版本可能是 {"title": "..."} 或按语言分键，
// 统一按字典解析，取 title / zh_CN / 任意非空值，取不到返回 nil
func locName(_ dict: [String: String]?) -> String? {
    guard let dict, !dict.isEmpty else { return nil }
    if let t = dict["title"], !t.isEmpty { return t }
    if let t = dict["zh_CN"], !t.isEmpty { return t }
    return dict.values.first { !$0.isEmpty }
}

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
    @Published var autoClaim = true           // 自动领取奖励（奖励 / 任务 / 事件中心）
    @Published var autoHideOnGame = true      // 游戏开始自动隐藏窗口，结束自动弹出（默认开启）
    @Published var acceptDelay: Double = 1
    @Published var showDonate = false
    @Published var gamePath = ""   // 空 = 自动识别
    @Published var attachToClient = true   // 吸附到客户端窗口右侧
    @Published var benchChamps: [Int] = []          // 备战席英雄（选人阶段）
    @Published var champIcons: [Int: NSImage] = [:] // 英雄头像缓存
    @Published var pickTargetId: Int = 0            // 抢购目标（0 = 未设置）

    private var pollTask: Task<Void, Never>?
    private var acceptTask: Task<Void, Never>?
    private var attachTask: Task<Void, Never>?
    private var client: LCUClient?
    private var prevPhase = ""
    private var lastSearch: Date = .distantPast
    private var searchThrottle: Double = 5        // 失败后自动拉长，避免骚扰
    private var sawSearching = false              // 本轮房间里见过"排队中"（用于识别用户主动取消）
    private var cancelLogged = false
    private var lastReconnect: Date = .distantPast
    private var lastPlayAgain: Date = .distantPast
    private var lastClaim: Date = .distantPast
    private var warned: Set<String> = []
    private var everLoggedWaiting = false
    private var handledReadyCheck = false
    private var hiddenForGame = false         // 当前是否因对局中而隐藏了窗口

    private func logOnce(_ key: String, _ msg: String) {
        guard !warned.contains(key) else { return }
        warned.insert(key)
        log(msg)
    }

    // 设置持久化（~/Library/Application Support/xiaobai助手/settings.json）
    private let settingsURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("xiaobai助手", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }()

    init() {
        loadSettings()
        attachTask = Task { await attachLoop() }   // 常驻：跟随客户端窗口
    }

    private func loadSettings() {
        if let d = try? Data(contentsOf: settingsURL),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            gamePath = obj["game_path"] as? String ?? ""
            if let a = obj["attach_to_client"] as? Bool { attachToClient = a }
            if let h = obj["auto_hide_on_game"] as? Bool { autoHideOnGame = h }
        }
    }

    private func saveSettings() {
        let obj: [String: Any] = ["game_path": gamePath, "attach_to_client": attachToClient,
                                  "auto_hide_on_game": autoHideOnGame]
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) {
            try? d.write(to: settingsURL)
        }
    }

    func setGamePath(_ path: String) {
        gamePath = path
        saveSettings()
        log(path.isEmpty ? "游戏路径恢复自动识别" : "游戏路径已保存：\(path)")
    }

    func setAttach(_ on: Bool) {
        attachToClient = on
        saveSettings()
        log(on ? "已开启：吸附客户端窗口右侧" : "已关闭吸附")
    }

    func setAutoHide(_ on: Bool) {
        autoHideOnGame = on
        saveSettings()
        if !on { restoreWindowIfHidden() }        // 关闭开关时立刻恢复窗口
        log(on ? "已开启：游戏开始自动隐藏，结束自动弹出" : "已关闭：游戏隐藏")
    }

    // MARK: 游戏开始隐藏 / 结束弹出
    private func helperWindow() -> NSWindow? {
        NSApp.mainWindow ?? NSApp.windows.first(where: { $0.level == .normal })
    }

    private func hideHelperWindow() {
        guard let w = helperWindow(), w.isVisible else { return }
        w.orderOut(nil)
        hiddenForGame = true
        log("🎮 对局开始，助手已隐藏（结束后自动弹出）")
    }

    private func showHelperWindow() {
        guard let w = helperWindow() else { return }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        hiddenForGame = false
        log("🏁 对局结束，助手已弹出")
    }

    // 断开连接 / 停止自动化 / 关闭开关时：若窗口因游戏被隐藏，恢复出来
    private func restoreWindowIfHidden() {
        guard hiddenForGame else { return }
        hiddenForGame = false
        if let w = helperWindow() {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
        }
    }

    // 跟随客户端窗口：贴右侧，右边放不下则贴左侧，顶部对齐
    private func attachLoop() async {
        while !Task.isCancelled {
            if attachToClient,
               let r = clientWindowRect(),
               let win = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.level == .normal }) {
                let our = win.frame
                let screen = NSScreen.screens.first { s in
                    let mid = CGPoint(x: r.midX, y: r.midY)
                    let q = CGRect(x: s.frame.minX, y: s.frame.maxY - (mid.y), width: s.frame.width, height: 1)
                    return q.origin.x <= mid.x && mid.x <= s.frame.maxX && q.origin.y <= s.frame.minY + 1
                } ?? NSScreen.main
                let vis = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
                let screenH = screen?.frame.height ?? 900

                var x = r.maxX + 8                                  // 优先右侧
                if x + our.width > vis.maxX {                        // 右侧放不下 → 左侧
                    x = r.minX - our.width - 8
                }
                x = min(max(x, vis.minX), max(vis.minX, vis.maxX - our.width))

                let topQuartz = r.minY                               // 顶部对齐客户端
                var y = screenH - topQuartz - our.height             // Quartz → Cocoa
                y = min(max(y, vis.minY), max(vis.minY, vis.maxY - our.height))

                let target = NSPoint(x: x, y: y)
                if abs(our.origin.x - target.x) > 1 || abs(our.origin.y - target.y) > 1 {
                    win.setFrameOrigin(target)
                }
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
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
        sawSearching = false; cancelLogged = false
        warned.removeAll()
        searchThrottle = 5
        lastReconnect = .distantPast; lastPlayAgain = .distantPast
        restoreWindowIfHidden()                  // 停止时恢复被游戏隐藏的窗口
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
                    let phaseChanged = (p != prevPhase)
                    if phaseChanged {
                        log("阶段 → \(phaseDisplay(p))")
                        if p != "ReadyCheck" { handledReadyCheck = false }
                        // 游戏开始隐藏 / 结束弹出（默认开启）：
                        // 进入 GameStart / InProgress → 隐藏助手窗口；离开对局阶段 → 弹出
                        if autoHideOnGame {
                            let inGame = (p == "GameStart" || p == "InProgress")
                            if inGame, !hiddenForGame { hideHelperWindow() }
                            else if !inGame, hiddenForGame { showHelperWindow() }
                        }
                        // 进入新的结算阶段（WaitingForStats → PreEndOfGame → EndOfGame）时，
                        // 立即尝试一次回到房间（对齐 LeagueAkari 的分阶段处理）
                        if isEndOfGamePhase(p) { lastPlayAgain = .distantPast }
                        prevPhase = p
                    }
                    if p != "Lobby" {
                        // 离开房间后重置「用户取消排队」记忆
                        if sawSearching || cancelLogged {
                            sawSearching = false; cancelLogged = false
                            warned.remove("not-leader"); warned.remove("not-ready")
                        }
                        searchThrottle = 5
                    }
                    if p == "ReadyCheck" && autoAccept && !handledReadyCheck {
                        handledReadyCheck = true
                        acceptTask = Task { [weak self] in await self?.doAccept(client: c) }
                    }
                    // 自动重连（对齐 Windows 版：Reconnect 阶段 + 8s 冷却 + 检查返回值）
                    if p == "Reconnect" && autoReconnect {
                        if Date().timeIntervalSince(lastReconnect) >= 8 {
                            lastReconnect = Date()
                            if let (_, h) = try? await c.post("/lol-gameflow/v1/reconnect"),
                               (200..<300).contains(h.statusCode) {
                                log("✅ 已自动重连对局")
                            } else {
                                logOnce("reconnect-fail", "⚠ 自动重连请求未成功（客户端可能未就绪），稍后重试")
                            }
                        }
                    }
                    // 自动回到房间（对齐 Windows 版：结算三阶段 + 20s 冷却 + 检查返回值）
                    if autoPlayAgain && isEndOfGamePhase(p) {
                        if Date().timeIntervalSince(lastPlayAgain) >= 20 {
                            lastPlayAgain = Date()
                            if let (_, h) = try? await c.post("/lol-lobby/v2/play-again"),
                               (200..<300).contains(h.statusCode) {
                                log("✅ 已自动回到房间")
                            } else {
                                logOnce("playagain-fail", "⚠ 暂时无法回到房间（可能还在结算），稍后重试")
                            }
                        }
                    }
                    if p == "Lobby" && autoStart { await tryAutoStart(client: c) }
                    // 自动领取奖励：30 分钟节流（1800s），三个来源（奖励 / 任务 / 事件中心）各查一轮
                    // 首次连接即跑一轮（lastClaim 初始为 distantPast），之后每 30 分钟一次
                    if autoClaim && Date().timeIntervalSince(lastClaim) >= 1800 {
                        lastClaim = Date()
                        await claimPass(client: c)
                    }
                    // 备战席抢英雄：选人阶段盯守
                    if p == "ChampSelect" {
                        await refreshChampSelect(client: c)
                    } else if !benchChamps.isEmpty {
                        benchChamps = []             // 离开选人，清空头像墙
                    }
                } catch {
                    if connected { connected = false; log("连接出错，重新发现客户端…") }
                    client = nil; prevPhase = ""; phaseRaw = ""
                    restoreWindowIfHidden()      // 断开时恢复窗口，避免助手"消失"
                }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func isEndOfGamePhase(_ p: String) -> Bool {
        p == "PreEndOfGame" || p == "WaitingForStats" || p == "EndOfGame"
    }

    // MARK: 备战席抢英雄
    func setPickTarget(_ id: Int) {
        if id == 0 || id == pickTargetId {
            pickTargetId = 0
            log("已清除抢购目标")
        } else {
            pickTargetId = id
            log("🎯 已设抢购目标（id \(id)），它一出现在备战席就自动换上")
        }
    }

    private func refreshChampSelect(client c: LCUClient) async {
        guard let (d, h) = try? await c.get("/lol-champ-select/v1/session"), h.statusCode == 200 else {
            if !benchChamps.isEmpty { benchChamps = [] }   // 选人还没开始 / 已结束
            return
        }
        guard let s = try? JSONDecoder().decode(ChampSelectSession.self, from: d) else { return }
        let ids = (s.benchChampions ?? []).map { $0.championId }
        benchChamps = ids
        for id in ids where champIcons[id] == nil {
            if let img = await c.imageData("/lol-game-data/assets/v1/champion-icons/\(id).png") {
                champIcons[id] = img
            }
        }
        // 目标英雄出现在备战席 → 立刻自动换上
        if pickTargetId != 0, ids.contains(pickTargetId) {
            if let (_, h2) = try? await c.post("/lol-champ-select/v1/session/bench/swap/\(pickTargetId)"),
               (200..<300).contains(h2.statusCode) {
                log("✅ 备战席已自动换上目标英雄（id \(pickTargetId)）")
                pickTargetId = 0
            } else {
                logOnce("swap-fail", "⚠ 自动换英雄未成功，下一拍重试")
            }
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

    // MARK: 自动领取奖励（实现依据 LeagueAkari claim-tools：全部走 LCU 本地 API）
    //
    // ① lol-rewards：GET /grants?status=PENDING_SELECTION
    //    → POST /grants/{id}/select  {grantId, rewardGroupId, selections:[奖励id]}
    //    多选一按 selectionStrategyConfig.maxSelectionsAllowed 取前 N 个
    // ② lol-missions：GET /missions 筛 status=SELECT_REWARDS
    //    → PUT /player/{id}  {rewardGroups:[奖励组id]}
    // ③ lol-event-hub：GET /events 筛 eventInfo.unclaimedRewardCount>0
    //    → POST /events/{id}/reward-track/claim-all 一键全领

    // 返回本轮领取成功的条数
    @discardableResult
    private func claimPass(client c: LCUClient) async -> Int {
        var claimed = 0

        // ① 奖励（宝箱 / 胶囊 / 图标等）
        if let (d, h) = try? await c.get("/lol-rewards/v1/grants?status=PENDING_SELECTION"),
           h.statusCode == 200,
           let grants = try? JSONDecoder().decode([RewardGrant].self, from: d) {
            for g in grants {
                guard let rewards = g.rewardGroup.rewards, !rewards.isEmpty else { continue }
                let maxSel = g.rewardGroup.selectionStrategyConfig?.maxSelectionsAllowed ?? 1
                let n = max(1, min(maxSel, rewards.count))
                let ids = rewards.prefix(n).map { $0.id }
                let body: [String: Any] = [
                    "grantId": g.info.id,
                    "rewardGroupId": g.rewardGroup.id,
                    "selections": ids
                ]
                guard let bd = try? JSONSerialization.data(withJSONObject: body),
                      let (_, h2) = try? await c.postBody("/lol-rewards/v1/grants/\(g.info.id)/select", bd),
                      (200..<300).contains(h2.statusCode) else {
                    logOnce("claim-reward-fail", "⚠ 有奖励领取失败（可能需要手动选择），稍后自动重试")
                    continue
                }
                claimed += 1
                log("🎁 已领取：\(locName(g.rewardGroup.localizations) ?? "奖励")")
            }
        }

        // ② 任务奖励
        if let (d, h) = try? await c.get("/lol-missions/v1/missions"),
           h.statusCode == 200,
           let missions = try? JSONDecoder().decode([MissionEntry].self, from: d) {
            for m in missions where m.status == "SELECT_REWARDS" {
                guard let rewards = m.rewards, !rewards.isEmpty else { continue }
                let n = max(1, min(m.rewardStrategy?.selectMaxGroupCount ?? 1, rewards.count))
                let groups = rewards.prefix(n).map { $0.rewardGroup }
                let body: [String: Any] = ["rewardGroups": groups]
                guard let bd = try? JSONSerialization.data(withJSONObject: body),
                      let (_, h2) = try? await c.putBody("/lol-missions/v1/player/\(m.id)", bd),
                      (200..<300).contains(h2.statusCode) else {
                    logOnce("claim-mission-fail", "⚠ 有任务奖励领取失败，稍后自动重试")
                    continue
                }
                claimed += 1
                log("🎁 已领取任务奖励：\(m.title ?? m.rewards?.first?.description ?? "任务")")
            }
        }

        // ③ 事件中心（通行证 / 活动奖励轨）
        if let (d, h) = try? await c.get("/lol-event-hub/v1/events"),
           h.statusCode == 200,
           let events = try? JSONDecoder().decode([EventHubEntry].self, from: d) {
            for e in events where (e.eventInfo.unclaimedRewardCount ?? 0) > 0 {
                guard let (_, h2) = try? await c.post("/lol-event-hub/v1/events/\(e.eventId)/reward-track/claim-all"),
                      (200..<300).contains(h2.statusCode) else {
                    logOnce("claim-event-fail", "⚠ 事件中心奖励领取失败，稍后自动重试")
                    continue
                }
                claimed += 1
                log("🎁 已领取事件奖励：\(e.eventInfo.eventName ?? e.eventId)")
            }
        }

        return claimed
    }

    // 手动「立即领取」：不依赖自动化开关，自己发现客户端跑一轮
    func claimNow() {
        Task { [weak self] in
            guard let self else { return }
            var c = self.client
            if c == nil, let lf = discoverLockfile() {
                c = LCUClient(port: lf.port, password: lf.password)
            }
            guard let c else { self.log("未找到游戏客户端，无法领取"); return }
            self.log("正在检查可领取奖励…")
            let n = await self.claimPass(client: c)
            self.log(n > 0 ? "领取完成（本轮 \(n) 项）" : "暂无可领取的奖励")
        }
    }

    private func tryAutoStart(client c: LCUClient) async {
        guard Date().timeIntervalSince(lastSearch) >= searchThrottle else { return }
        lastSearch = Date()

        // 1. 队列状态
        guard let (d, h) = try? await c.get("/lol-lobby/v2/lobby/matchmaking/search-state"),
              h.statusCode == 200,
              let st = try? JSONDecoder().decode(SearchState.self, from: d) else { return }

        if st.searchState != "Invalid" {
            sawSearching = true          // 正在排队 / 有进度，标记本轮已搜过
            return
        }

        // 2. 本轮已搜过又回到未排队 → 是用户主动取消（或搜完未点），
        //    尊重用户意图，不再强行重排（离开房间后自动复位）
        if sawSearching {
            if !cancelLogged {
                cancelLogged = true
                log("⏸ 检测到排队已取消，本轮不再自动开始匹配")
            }
            return
        }

        // 3. 读取房间状态：canStartActivity = 客户端判定的「现在能不能开」
        //    （含队长权限、是否已准备、人数限制等，与 LeagueAkari 同源）
        guard let (d2, h2) = try? await c.get("/lol-lobby/v2/lobby"),
              h2.statusCode == 200,
              let lobby = try? JSONDecoder().decode(LobbyInfo.self, from: d2) else {
            logOnce("lobby-fail", "⚠ 无法读取房间状态，暂不自动开始匹配")
            return
        }

        if lobby.localMember?.isLeader == false {
            logOnce("not-leader", "⏸ 你不是队长，无法开始匹配（已跳过）")
            return
        }

        // 4. 还不能开 → 多半是没点「准备」（联盟战棋/排位）。
        //    自动帮你点准备：PUT /lol-lobby/v1/parties/ready（即客户端 ✓ 按钮的请求）
        if lobby.canStartActivity != true {
            if lobby.localMember?.ready == false {
                if let (_, rh) = try? await c.put("/lol-lobby/v1/parties/ready"),
                   (200..<300).contains(rh.statusCode) {
                    log("✅ 已自动点「准备」")
                    return                       // 下一轮确认可开后再搜索
                } else {
                    searchThrottle = 10
                    logOnce("ready-fail", "⚠ 自动点「准备」未成功，稍后重试")
                    return
                }
            }
            searchThrottle = 10
            logOnce("cannot-start", "⏸ 客户端提示当前不可开始匹配（等待条件满足）")
            return
        }

        // 4. 真正开始匹配 —— 检查返回值，如实上报
        if let (_, h3) = try? await c.post("/lol-lobby/v2/lobby/matchmaking/search"),
           (200..<300).contains(h3.statusCode) {
            log("✅ 已自动开始匹配")
        } else {
            searchThrottle = 30          // 失败拉长间隔，避免高频骚扰触发风控
            logOnce("search-fail", "⚠ 开始匹配未成功，30 秒后重试")
        }
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
            claimRow
            settingsCard
            benchWall
            logCard
        }
        .padding(12)
        .frame(width: 300, height: 660)
        .background(bg)
        .preferredColorScheme(.light)
        .onAppear {
            // 启动即居中并置前，避免"点了没反应"
            NSApp.activate(ignoringOtherApps: true)
            if let w = NSApp.windows.first {
                w.center()
                w.makeKeyAndOrderFront(nil)
            }
        }
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

    // 立即领取奖励（手动触发一轮：奖励 / 任务 / 事件中心）
    private var claimRow: some View {
        Button(action: { engine.claimNow() }) {
            Text("🎁 领取奖励")
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
                Text("接受延迟").font(.system(size: 10)).foregroundColor(sub)
                Picker("", selection: $engine.acceptDelay) {
                    Text("1s").tag(Double(1)); Text("3s").tag(Double(3)); Text("5s").tag(Double(5))
                }
                .pickerStyle(.segmented).frame(width: 120).disabled(!engine.autoAccept)
                Spacer()
            }
            Toggle("自动开始匹配", isOn: $engine.autoStart).foregroundColor(ink)
            Toggle("自动重连", isOn: $engine.autoReconnect).foregroundColor(ink)
            Toggle("自动回到房间", isOn: $engine.autoPlayAgain).foregroundColor(ink)
            Toggle("自动领取奖励", isOn: $engine.autoClaim).foregroundColor(ink)
            Toggle("游戏开始隐藏 / 结束弹出", isOn: Binding(
                get: { engine.autoHideOnGame },
                set: { engine.setAutoHide($0) }
            )).foregroundColor(ink)
            Toggle("吸附客户端右侧", isOn: Binding(
                get: { engine.attachToClient },
                set: { engine.setAttach($0) }
            )).foregroundColor(ink)
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

    // 备战席头像墙：2 排 × 5 格，点头像设为抢购目标（蓝环）
    private var benchWall: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("备战席抢英雄").font(.system(size: 10, weight: .semibold)).foregroundColor(sub)
                Spacer()
                if engine.pickTargetId != 0 {
                    Button("清除目标") { engine.setPickTarget(0) }
                        .font(.system(size: 9)).buttonStyle(.plain).foregroundColor(.red)
                } else {
                    Text("选人后点头像设为抢购目标").font(.system(size: 9)).foregroundColor(sub)
                }
            }
            VStack(spacing: 6) {
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: 6) {
                        ForEach(0..<5, id: \.self) { col in
                            benchCell(row * 5 + col)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(cardColor)
        .cornerRadius(8)
    }

    @ViewBuilder
    private func benchCell(_ idx: Int) -> some View {
        let id = idx < engine.benchChamps.count ? engine.benchChamps[idx] : 0
        Button(action: { engine.setPickTarget(id) }) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(id != 0 ? Color(red: 0.93, green: 0.94, blue: 0.97)
                                  : Color(red: 0.965, green: 0.965, blue: 0.975))
                if id != 0 {
                    if let img = engine.champIcons[id] {
                        Image(nsImage: img).resizable().scaledToFit().padding(3)
                    } else {
                        Text("?").font(.system(size: 15, weight: .semibold)).foregroundColor(sub)
                    }
                    if engine.pickTargetId == id {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.accentColor, lineWidth: 3)
                    }
                } else {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 14)).foregroundColor(Color(red: 0.85, green: 0.86, blue: 0.88))
                }
            }
            .frame(width: 49, height: 49)
        }
        .buttonStyle(.plain)
        .disabled(id == 0)
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
        .defaultPosition(.center)
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
