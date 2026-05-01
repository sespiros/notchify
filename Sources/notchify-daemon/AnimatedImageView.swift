import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// Layer-backed NSView that plays animated images frame-by-frame.
/// Handles GIF and animated WebP by reading per-frame delays via
/// CGImageSource. Static images render as a single frame with the
/// timer disabled. Cached frames + delays so each chip arriving
/// from the same file doesn't re-decode.
final class AnimatedImageNSView: NSView {
    private var timer: Timer?
    private var frames: [CGImage] = []
    private var delays: [TimeInterval] = []
    private var frameIndex: Int = 0

    var contentsPath: String? {
        didSet {
            guard contentsPath != oldValue else { return }
            reload()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.minificationFilter = .linear
        layer?.magnificationFilter = .linear
    }

    deinit {
        timer?.invalidate()
    }

    private func reload() {
        timer?.invalidate()
        timer = nil
        frames = []
        delays = []
        frameIndex = 0
        guard let path = contentsPath else {
            layer?.contents = nil
            return
        }
        let url = URL(fileURLWithPath: path)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            layer?.contents = nil
            return
        }
        let count = CGImageSourceGetCount(src)
        for i in 0..<count {
            guard let img = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            frames.append(img)
            delays.append(Self.frameDelay(source: src, index: i))
        }
        layer?.contents = frames.first
        if frames.count > 1 {
            scheduleNext()
        }
    }

    private func scheduleNext() {
        let delay = delays[frameIndex % max(delays.count, 1)]
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.frameIndex = (self.frameIndex + 1) % self.frames.count
            self.layer?.contents = self.frames[self.frameIndex]
            self.scheduleNext()
        }
    }

    /// Per-frame delay extracted from the image's container-specific
    /// metadata (GIF or WebP dictionaries). Falls back to 100ms
    /// when no delay is recorded; clamps the lower bound to 20ms
    /// because some encoders emit zero and we'd spin the timer.
    private static func frameDelay(source: CGImageSource, index: Int) -> TimeInterval {
        let fallback: TimeInterval = 0.1
        let minDelay: TimeInterval = 0.02
        guard let raw = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else {
            return fallback
        }
        for key in [kCGImagePropertyGIFDictionary, kCGImagePropertyWebPDictionary] {
            guard let dict = raw[key] as? [CFString: Any] else { continue }
            let unclamped = (dict[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (dict[kCGImagePropertyWebPUnclampedDelayTime] as? Double)
            let clamped = (dict[kCGImagePropertyGIFDelayTime] as? Double)
                ?? (dict[kCGImagePropertyWebPDelayTime] as? Double)
            if let d = unclamped ?? clamped, d > 0 {
                return max(d, minDelay)
            }
        }
        return fallback
    }
}

/// SwiftUI wrapper for `AnimatedImageNSView`. Drop-in replacement
/// for `Image(nsImage:)` when the file might be animated.
struct AnimatedImage: NSViewRepresentable {
    let path: String

    func makeNSView(context: Context) -> AnimatedImageNSView {
        let v = AnimatedImageNSView()
        v.contentsPath = path
        return v
    }

    func updateNSView(_ nsView: AnimatedImageNSView, context: Context) {
        nsView.contentsPath = path
    }
}
