import Foundation

@main
struct ClockCheck {
    static func main() {
        for hz in [60, 120, 144, 165] {
            var gate = WallpaperFrameClock(fps: 60)
            var frames = 0
            for index in 0..<(hz * 10) {
                if gate.shouldPresent(at: Double(index) / Double(hz), refreshPeriod: 1 / Double(hz)) { frames += 1 }
            }
            precondition(abs(frames - 600) <= 1, "\(hz) Hz produced \(frames) frames")
            precondition(gate.shouldPresent(at: 40, refreshPeriod: 1 / Double(hz)))
            if hz > 60 { precondition(!gate.shouldPresent(at: 40.0001, refreshPeriod: 1 / Double(hz))) }
            print("\(hz) Hz → \(frames) frames in 10 seconds")
        }
    }
}
