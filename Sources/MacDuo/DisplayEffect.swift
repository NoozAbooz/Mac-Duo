import AppKit

/// Owns capture and rendering for one display. LidController supplies the
/// same animation angle to every display, but each captures its own contents.
@MainActor
final class DisplayEffect {
    let screen: NSScreen
    private let overlay = DepthOverlay()
    private let snapshotter: ScreenSnapshotter
    private let streamer: ScreenStreamer
    private var pictureTask: Task<Void, Never>?
    private var warmTask: Task<Void, Never>?
    private var isPresenting = false
    private var usesLivePicture = false
    private var hasRenderedFrame = false
    private var holdsPrewarmPresence = false
    private var holdsPresentationPresence = false
    private var warmGeneration = 0
    private var pictureGeneration = 0

    var hostWindow: NSWindow? { overlay.hostWindow }
    var isVisible: Bool { overlay.isVisible }
    var needsInitialRender: Bool { overlay.isVisible && overlay.isPictureReady && !hasRenderedFrame }

    init(screen: NSScreen, displayID: CGDirectDisplayID) {
        self.screen = screen
        snapshotter = ScreenSnapshotter(displayID: displayID)
        streamer = ScreenStreamer(displayID: displayID)
    }

    func warmUp() {
        overlay.warmUp()
        guard warmTask == nil else { return }
        warmGeneration += 1
        let generation = warmGeneration
        overlay.beginCapturePresence()
        warmTask = Task { [weak self] in
            guard let self else { return }
            defer {
                overlay.endCapturePresence()
                if warmGeneration == generation { warmTask = nil }
            }
            await snapshotter.warmFilter()
            // Give ScreenCaptureKit time to discover our presence window so
            // all of this app's overlays can be excluded from every capture.
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await streamer.warmFilter()
        }
    }

    func prewarm(isLive: Bool, isNeeded: Bool, captureNow: Bool) {
        guard isNeeded else {
            setPrewarmPresence(false)
            snapshotter.stop()
            streamer.stop()
            overlay.discardLive()
            return
        }
        overlay.warmUp()
        setPrewarmPresence(true)
        if isLive {
            snapshotter.endPrewarm()
            streamer.start()
        } else {
            streamer.stop()
            overlay.discardLive()
            if captureNow { snapshotter.requestPrewarmCapture() }
        }
    }

    func present(isLive: Bool, startAngle: Double, tuning: DepthTuning, fadeIn: TimeInterval) {
        isPresenting = true
        setPresentationPresence(true)
        setPrewarmPresence(false)
        snapshotter.endPrewarm()
        if overlay.isVisible {
            if usesLivePicture { streamer.start() }
            setPresentationPresence(false)
            return
        }
        guard pictureTask == nil else { return }
        usesLivePicture = false
        hasRenderedFrame = false

        if isLive, overlay.showLive(on: screen, startAngle: startAngle, tuning: tuning, fadeIn: fadeIn) {
            usesLivePicture = true
            // A quick close may skip prewarming entirely.
            streamer.start()
            setPresentationPresence(false)
            if let frame = streamer.newFrame() {
                overlay.absorb(frame)
                return
            }
            if let image = snapshotter.latestImage {
                overlay.seed(image: image)
                return
            }
        } else {
            streamer.stop()
            if let image = snapshotter.latestImage {
                overlay.show(image: image, on: screen, startAngle: startAngle, tuning: tuning, fadeIn: fadeIn)
                setPresentationPresence(false)
                return
            }
        }

        pictureGeneration += 1
        let generation = pictureGeneration
        pictureTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if pictureGeneration == generation {
                    pictureTask = nil
                    setPresentationPresence(false)
                }
            }
            await snapshotter.captureOnce()
            guard !Task.isCancelled, isPresenting else { return }
            guard let image = snapshotter.latestImage else { return }
            if overlay.isVisible {
                if !overlay.isPictureReady { overlay.seed(image: image) }
            } else {
                overlay.show(image: image, on: screen, startAngle: startAngle, tuning: tuning, fadeIn: fadeIn)
            }
        }
    }

    func update(progress: Double, angle: Double, tuning: DepthTuning) {
        if let frame = streamer.newFrame() { overlay.absorb(frame) }
        overlay.update(progress: progress, currentAngle: angle, tuning: tuning)
        if overlay.isPictureReady { hasRenderedFrame = true }
    }

    /// Prevent late screenshots from showing a new window during the exit
    /// animation. The live stream stays available until the animation ends.
    func endPresentation() {
        isPresenting = false
        pictureTask?.cancel()
        pictureTask = nil
        pictureGeneration += 1
        snapshotter.stop()
        setPrewarmPresence(false)
        setPresentationPresence(false)
    }

    func dismiss(animated: Bool) {
        endPresentation()
        warmTask?.cancel()
        warmTask = nil
        warmGeneration += 1
        streamer.stop()
        overlay.dismiss(animated: animated)
        overlay.discardLive()
        hasRenderedFrame = false
    }

    private func setPrewarmPresence(_ held: Bool) {
        guard held != holdsPrewarmPresence else { return }
        holdsPrewarmPresence = held
        if held {
            overlay.beginCapturePresence()
        } else {
            overlay.endCapturePresence()
        }
    }

    private func setPresentationPresence(_ held: Bool) {
        guard held != holdsPresentationPresence else { return }
        holdsPresentationPresence = held
        if held {
            overlay.beginCapturePresence()
        } else {
            overlay.endCapturePresence()
        }
    }

    /// Also release the invisible presence window when removing a display.
    func dispose() {
        dismiss(animated: false)
        overlay.dispose()
    }
}
