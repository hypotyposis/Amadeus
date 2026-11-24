import Foundation

struct WallpaperFrameClock {
    private let period: Double
    private var deadline: Double?

    init(fps: Int) { period = 1 / Double(fps) }

    mutating func reset() { deadline = nil }

    mutating func shouldPresent(at time: Double, refreshPeriod: Double) -> Bool {
        guard let deadline else {
            self.deadline = time + period
            return true
        }
        // Select the vsync nearest the target deadline. Retaining the
        // fractional remainder supports 60 FPS on 144 Hz, for example.
        guard time + min(refreshPeriod, period) / 2 + 1e-7 >= deadline else { return false }
        self.deadline = (time - deadline >= period ? time : deadline) + period
        return true
    }
}
