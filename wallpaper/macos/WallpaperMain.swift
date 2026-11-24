import AppKit
import JavaScriptCore
import MetalKit
import VideoToolbox

private struct VideoCatalog: Decodable {
    struct Entry: Decodable { let label: String }
    let clips: [Entry]
}

private final class Timers {
    private var next = 0
    private var pending: [Int: DispatchWorkItem] = [:]

    func install(in context: JSContext) {
        let schedule: @convention(block) (JSValue, Double) -> Int = { [weak self] callback, milliseconds in
            guard let self else { return -1 }
            self.next += 1
            let id = self.next
            let task = DispatchWorkItem { [weak self] in
                self?.pending.removeValue(forKey: id)
                callback.call(withArguments: [])
            }
            self.pending[id] = task
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, milliseconds) / 1000, execute: task)
            return id
        }
        let cancel: @convention(block) (Int) -> Void = { [weak self] in self?.pending.removeValue(forKey: $0)?.cancel() }
        context.setObject(schedule, forKeyedSubscript: "setTimeout" as NSString)
        context.setObject(cancel, forKeyedSubscript: "clearTimeout" as NSString)
        context.evaluateScript("globalThis.console = { log() {}, warn() {} };")
    }
}

@MainActor
private final class WallpaperPlayer {
    private let window: NSWindow
    private let view: WallpaperView
    private let origin: URL
    private let events: URL
    private let config: URL
    private let js: JSContext
    private let timers = Timers()
    private let decoder = DispatchQueue(label: "Amadeus.Wallpaper.Video", qos: .userInteractive)
    private var graph: JSValue!
    private var backgroundReady = false
    private var assetBase: URL?
    private var labels: Set<String> = []
    private var fileLists: [String: [String]] = [:]
    private var fittedCanvases: [String: CGSize] = [:]
    private var onceClips: Set<String> = []
    private var closedIndices: [String: Int] = [:]
    private var profile: [String: Any] = [:]
    private var captionClear: Task<Void, Never>?
    private var load: Task<Void, Never>?
    private var currentEmotion = ""
    private var clip: VideoClip?
    private var requestedIndex: Int?
    private var shownIndex = -1
    private var heldIndex: Int?
    private var elapsed = 0.0
    private var lastTick: Double?
    private var playing = true
    private var firstVisibleFrame = false
    private var cycleFinished = false

    init(assetPort: Int, bridgePort: Int, fps: Int, maxDensity: Double?, script: URL) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let screen = NSScreen.screens.first,
              let context = JSContext() else {
            throw WallpaperFailure("Metal, a desktop display and JavaScriptCore are required")
        }
        view = try WallpaperView(device: device, fps: fps, maxDensity: maxDensity)
        origin = URL(string: "http://127.0.0.1:\(assetPort)/")!
        events = URL(string: "http://127.0.0.1:\(bridgePort)/wallpaper/events")!
        config = URL(string: "http://127.0.0.1:\(assetPort)/wallpaper/bridge-info")!
        js = context
        window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = "Amadeus Native Wallpaper"
        window.contentView = view
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isMovable = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 6)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]

        timers.install(in: js)
        js.exceptionHandler = { _, error in
            if let error { fputs("[native-wallpaper] animation graph: \(error)\n", stderr) }
        }
        js.evaluateScript(try String(contentsOf: script, encoding: .utf8), withSourceURL: script)
        guard let constructor = js.objectForKeyedSubscript("SpriteForgeRuntime"), !constructor.isUndefined else {
            throw WallpaperFailure("The shared SpriteForge animation graph is unavailable")
        }
        let change: @convention(block) (String) -> Void = { [weak self] in self?.setEmotion($0) }
        let hold: @convention(block) (JSValue) -> Void = { [weak self] in self?.hold($0.isNumber ? Int($0.toInt32()) : nil) }
        let closed: @convention(block) () -> Void = { [weak self] in
            if let self { self.hold(self.closedIndices[self.currentEmotion]) }
        }
        let clear: @convention(block) () -> Void = { [weak self] in self?.heldIndex = nil }
        let speaking: @convention(block) (Bool) -> Void = { _ in }
        let sprite: [String: Any] = [
            "setEmotion": change, "setSpeaking": speaking, "holdFrame": hold,
            "holdClosedFrame": closed, "clearHold": clear,
        ]
        graph = constructor.construct(withArguments: [sprite])
        guard graph != nil, !graph.isUndefined else { throw WallpaperFailure("Unable to start SpriteForge") }
        view.onTick = { [weak self] in self?.tick() }
        view.onFirstPresentation = { [weak self] in
            print("ready")
            fflush(stdout)
            self?.reportStatus()
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self, let screen = NSScreen.screens.first { self.window.setFrame(screen.frame, display: true) }
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncVisibility() }
        }
    }

    func run() {
        Task {
            do {
                let (data, response) = try await URLSession.shared.bytes(for: URLRequest(url: events, timeoutInterval: 95))
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw WallpaperFailure("The wallpaper event stream is unavailable")
                }
                for try await line in data.lines where line.hasPrefix("data: ") {
                    guard let event = try JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8))
                        as? [String: Any], let method = event["method"] as? String,
                          let args = event["args"] as? [Any] else { continue }
                    try receive(method, args: args)
                }
                throw WallpaperFailure("The wallpaper event stream closed")
            } catch { fail(error) }
        }
    }

    private func get(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url?.host == origin.host, http.url?.port == origin.port else {
            throw WallpaperFailure("Wallpaper asset unavailable: \(url.lastPathComponent)")
        }
        return data
    }

    private func assetURL(_ path: String) throws -> URL {
        guard let url = URL(string: path, relativeTo: origin)?.absoluteURL,
              url.scheme == origin.scheme, url.host == origin.host, url.port == origin.port else {
            throw WallpaperFailure("Wallpaper assets must be on the local bridge")
        }
        return url
    }

    private func receive(_ method: String, args: [Any]) throws {
        let arg = args.first
        switch method {
        case "initDesktopScene":
            guard let scene = arg as? [String: Any] else { throw WallpaperFailure("Invalid wallpaper scene") }
            try configureScene(scene)
        case "configureCharacter":
            guard let config = arg as? [String: Any] else { throw WallpaperFailure("Invalid wallpaper character") }
            try configureCharacter(config)
        case "loadSpriteFrames":
            if let label = arg as? String, let frames = args.dropFirst().first as? [String] { fileLists[label] = frames }
        case "loadSpriteForgeGraph":
            if let payload = arg as? [String: Any] { graph.invokeMethod("loadGraph", withArguments: [payload]) }
        case "setSpriteClipConfig":
            if let label = arg as? String, let config = args.dropFirst().first as? [String: Any] {
                if config["loopMode"] as? String == "once_then_hold" { onceClips.insert(label) }
                if let width = config["canvasWidth"] as? Double, let height = config["canvasHeight"] as? Double,
                   width > 0, height > 0 { fittedCanvases[label] = CGSize(width: width, height: height) }
            }
        case "loadMouthConfig":
            if let label = arg as? String, let config = args.dropFirst().first as? [String: Any],
               let closed = config["closedFrameIdx"] as? Int { closedIndices[label] = closed }
        case "setSpeaking":
            graph.invokeMethod("setSpeaking", withArguments: [arg as? Bool ?? false])
        case "triggerCharacterIntent":
            if let label = arg as? String {
                let options = args.dropFirst().first as? [String: Any] ?? [:]
                if options["backend"] as? String == nil || options["backend"] as? String == "sprite" {
                    graph.invokeMethod("trigger", withArguments: [label, options])
                }
            }
        case "releaseCharacter":
            graph.invokeMethod("release", withArguments: [arg as? [String: Any] ?? [:]])
        case "setEmotion":
            if let label = arg as? String { setEmotion(label) }
        case "setIdleAnimation":
            playing = arg as? Bool ?? true
        case "holdSpriteFrame":
            hold(arg as? Int)
        case "clearSpriteHold":
            heldIndex = nil
        case "setSubtitle":
            showCaption(arg as? String ?? "")
        case "setCompanionActive":
            view.setCharacterVisible(!(arg as? Bool ?? false))
        default:
            break // Canvas and input remain Electron's separate window.
        }
    }

    private func configureScene(_ scene: [String: Any]) throws {
        guard let config = scene["crtConfig"] as? [String: Any],
              let size = config["img_size"] as? [Double], size.count == 2, size[0] > 0, size[1] > 0,
              let raw = (config["crt_polygon"] ?? config["crt_corners"]) as? [[Double]],
              (3...64).contains(raw.count), raw.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }),
              let path = scene["backgroundUrl"] as? String, !path.isEmpty else {
            throw WallpaperFailure("The native wallpaper needs a background and CRT geometry")
        }
        if (scene["scenario"] as? [String: Any])?["enabled"] as? Bool == true {
            throw WallpaperFailure("This wallpaper scene requires the web scenario renderer")
        }
        let url = try assetURL(path)
        Task {
            do {
                guard let image = try await NSImage(data: get(url)) else {
                    throw WallpaperFailure("Unable to decode the wallpaper image")
                }
                view.configure(image: image, artwork: CGSize(width: size[0], height: size[1]),
                               crt: raw.map { CGPoint(x: $0[0], y: $0[1]) },
                               scanline: config["scanline_alpha"] as? Float ?? 32)
                backgroundReady = true
                showWhenReady()
            } catch { fail(error) }
        }
    }

    private func configureCharacter(_ config: [String: Any]) throws {
        guard config["backend"] as? String == "sprite",
              let frameSource = config["frame_source"] as? [String: Any],
              let candidate = frameSource["candidate"] as? [String: Any],
              let path = candidate["baseUrl"] as? String else {
            throw WallpaperFailure("Native wallpaper requires a compatible SpriteForge video pack")
        }
        profile = config
        let base = try assetURL(path)
        if assetBase == base { return }
        assetBase = base
        Task {
            do {
                let catalog = try await JSONDecoder().decode(VideoCatalog.self, from: get(base.appendingPathComponent("bundle.json")))
                labels = Set(catalog.clips.map(\.label))
                startClip()
            } catch { fail(error) }
        }
    }

    private func setEmotion(_ label: String) {
        guard !label.isEmpty, currentEmotion != label else { return }
        currentEmotion = label
        view.canvasSize = fittedCanvases[label]
        clip = nil
        elapsed = 0
        shownIndex = -1
        heldIndex = nil
        cycleFinished = false
        startClip()
    }

    private func startClip() {
        guard let assetBase, !labels.isEmpty, !currentEmotion.isEmpty else { return }
        let emotion = currentEmotion
        let direct = labels.contains(emotion) ? emotion : nil
        let alias = fileLists[emotion].flatMap { frames in labels.first { fileLists[$0] == frames } }
        guard let label = direct ?? alias, !label.isEmpty,
              label.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 }) else {
            fail(WallpaperFailure("Native video clip is missing for \(emotion)"))
        }

        load?.cancel()
        let base = assetBase.appendingPathComponent(label, isDirectory: true)
        load = Task {
            do {
                async let metadata = get(base.appendingPathComponent("clip.json"))
                async let color = get(base.appendingPathComponent("color.ivf"))
                async let alpha = get(base.appendingPathComponent("alpha.ivf"))
                let inputs = try await (metadata, color, alpha)
                let prepared = try await withCheckedThrowingContinuation { continuation in
                    decoder.async {
                        continuation.resume(with: Result {
                            let clip = try VideoClip(metadataData: inputs.0, colorData: inputs.1, alphaData: inputs.2)
                            return (clip, try clip.frame(at: 0))
                        })
                    }
                }
                guard !Task.isCancelled, currentEmotion == emotion else { return }
                let (clip, first) = prepared
                let texture = try view.textures(for: first, metadata: clip.metadata)
                self.clip = clip
                view.frameToDisplay = texture
                shownIndex = 0
                lastTick = nil
                showWhenReady()
            } catch {
                if !Task.isCancelled { fail(error) }
            }
        }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        defer { lastTick = now }
        guard let clip else { return }
        let duration = clip.metadata.frameIntervalMs / 1000
        let frameCount = clip.metadata.frames
        if playing && heldIndex == nil && !(cycleFinished && onceClips.contains(currentEmotion)) {
            elapsed += min(max(0, now - (lastTick ?? now)), 0.1)
        }
        var index = min(frameCount - 1, Int(elapsed / duration))
        if let heldIndex { index = min(frameCount - 1, max(0, heldIndex)) }
        if shownIndex == index, heldIndex == nil, !cycleFinished, elapsed >= duration * Double(frameCount) {
            cycleFinished = true
            elapsed = onceClips.contains(currentEmotion) ? elapsed : elapsed.truncatingRemainder(dividingBy: duration * Double(frameCount))
            if !onceClips.contains(currentEmotion) { cycleFinished = false }
            graph.invokeMethod("onCycleComplete", withArguments: [currentEmotion])
            return
        }
        guard shownIndex != index, requestedIndex == nil else { return }
        requestedIndex = index
        let target = index
        decoder.async { [weak self] in
            let result = Result { try clip.frame(at: target) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.requestedIndex = nil
                guard self.clip === clip else { return }
                do {
                    self.view.frameToDisplay = try self.view.textures(for: result.get(), metadata: clip.metadata)
                    self.shownIndex = target
                } catch { self.fail(error) }
            }
        }
    }

    private func hold(_ index: Int?) {
        heldIndex = index == -1 ? max(0, (clip?.metadata.frames ?? 1) - 1) : index ?? max(0, shownIndex)
    }

    private func showCaption(_ text: String) {
        captionClear?.cancel()
        view.setCaption(text)
        if !text.isEmpty {
            captionClear = Task {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if !Task.isCancelled { view.setCaption("") }
            }
        }
    }

    private func syncVisibility() {
        lastTick = nil
        view.setPaused(!window.occlusionState.contains(.visible))
    }

    private func showWhenReady() {
        guard !firstVisibleFrame, backgroundReady, view.frameToDisplay != nil else { return }
        firstVisibleFrame = true
        window.orderFrontRegardless()
        view.setPaused(false)
    }

    private func reportStatus() {
        guard let runtimeID = profile["runtime_id"] else { return }
        let status: [String: Any] = [
            "surface": "wallpaper", "runtime_id": runtimeID, "revision": profile["revision"] ?? 0,
            "profile_id": profile["profile_id"] ?? "", "state": "ready",
            "diagnostic": ["frame_source": ["mode": "video", "reason": "native_videotoolbox"]],
        ]
        Task {
            guard let data = try? await get(config),
                  let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = info["bridgeToken"] as? String,
                  let url = URL(string: "/wallpaper/character-status", relativeTo: events) else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(token, forHTTPHeaderField: "X-Amadeus-Bridge-Token")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: status)
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    private func fail(_ error: Error) -> Never {
        fputs("[native-wallpaper] \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

@main
struct NativeWallpaper {
    @MainActor
    static func main() {
        do {
            VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
            let arguments = CommandLine.arguments
            if arguments.count == 3, arguments[1] == "--verify-clip" {
                let base = URL(fileURLWithPath: arguments[2], isDirectory: true)
                let clip = try VideoClip(metadataData: Data(contentsOf: base.appendingPathComponent("clip.json")),
                                         colorData: Data(contentsOf: base.appendingPathComponent("color.ivf")),
                                         alphaData: Data(contentsOf: base.appendingPathComponent("alpha.ivf")))
                let count = clip.metadata.frames
                for index in [0, min(6, count - 1), count - 1, 0] { _ = try clip.frame(at: index) }
                print("verified VP9 hardware decode, seek and restart (\(count)-frame clip)")
                return
            }
            guard arguments.count == 6, let asset = Int(arguments[1]), let bridge = Int(arguments[2]),
                  (1...65535).contains(asset), (1...65535).contains(bridge),
                  let fps = Int(arguments[3]), (10...240).contains(fps),
                  let density = Double(arguments[4]), density.isFinite, density >= 0 else {
                throw WallpaperFailure("Usage: AmadeusWallpaper <asset port> <event port> <fps> <max density, or 0> <renderer.js>")
            }
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let player = try WallpaperPlayer(assetPort: asset, bridgePort: bridge, fps: fps,
                                             maxDensity: density > 0 ? density : nil,
                                             script: URL(fileURLWithPath: arguments[5]))
            // Electron owns this display lifetime. EOF is also sent if the
            // parent disappears without an application quit event.
            DispatchQueue.global().async {
                _ = FileHandle.standardInput.readData(ofLength: 1)
                exit(0)
            }
            player.run()
            withExtendedLifetime(player) { app.run() }
        } catch {
            fputs("[native-wallpaper] \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
