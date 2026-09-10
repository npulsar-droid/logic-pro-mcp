import ApplicationServices
import Foundation

/// Channel that reads and mutates Logic Pro state via the macOS Accessibility API.
/// Primary channel for state queries (transport, tracks, mixer) and UI mutations
/// (clicking mute/solo buttons, reading fader values, etc.)
actor AccessibilityChannel: Channel {
    let id: ChannelID = .accessibility

    func start() async throws {
        // Verify AX trust. If not trusted, the process needs to be added to
        // System Preferences > Privacy & Security > Accessibility.
        let trusted = PermissionChecker.checkAccessibility()
        guard trusted else {
            throw AccessibilityError.notTrusted
        }
        guard ProcessUtils.isLogicProRunning else {
            Log.warn("Logic Pro not running at AX channel start", subsystem: "ax")
            return
        }
        Log.info("Accessibility channel started", subsystem: "ax")
    }

    func stop() async {
        Log.info("Accessibility channel stopped", subsystem: "ax")
    }

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        guard ProcessUtils.isLogicProRunning else {
            return .error("Logic Pro is not running")
        }

        switch operation {
        // MARK: - Transport reads
        case "transport.get_state":
            return getTransportState()

        // MARK: - Transport mutations
        case "transport.toggle_cycle":
            return toggleTransportButton(named: "Cycle")
        case "transport.toggle_metronome":
            return toggleTransportButton(named: "Metronome")
        case "transport.set_tempo":
            return await setTempo(params: params)
        case "transport.set_cycle_range":
            return setCycleRange(params: params)

        // MARK: - Track reads
        case "track.get_tracks":
            return getTracks()
        case "track.get_selected":
            return getSelectedTrack()

        // MARK: - Track mutations
        case "track.select":
            return selectTrack(params: params)
        case "track.set_mute":
            return setTrackToggle(params: params, button: "Mute")
        case "track.set_solo":
            return setTrackToggle(params: params, button: "Solo")
        case "track.set_arm":
            return setTrackToggle(params: params, button: "Record")
        case "track.rename":
            return renameTrack(params: params)
        case "track.set_color":
            return .error("Track color setting not supported via AX")

        // MARK: - Mixer reads
        case "mixer.get_state":
            return getMixerState()
        case "mixer.get_channel_strip":
            return getChannelStrip(params: params)

        // MARK: - Mixer mutations
        case "mixer.set_volume":
            return setMixerValue(params: params, target: .volume)
        case "mixer.set_pan":
            return setMixerValue(params: params, target: .pan)
        case "mixer.set_send":
            return .error("Send adjustment not yet implemented via AX")
        case "mixer.set_input", "mixer.set_output":
            return .error("I/O routing not yet implemented via AX")
        case "mixer.toggle_eq":
            return .error("EQ toggle not yet implemented via AX")
        case "mixer.reset_strip":
            return .error("Strip reset not yet implemented via AX")

        // MARK: - Navigation
        case "nav.get_markers":
            return .error("Marker reading not yet implemented via AX")
        case "nav.rename_marker":
            return .error("Marker renaming not yet implemented via AX")

        // MARK: - Project
        case "project.get_info":
            return getProjectInfo()

        // MARK: - Regions
        case "region.get_regions":
            return .error("Region reading not yet implemented via AX")
        case "region.select", "region.loop", "region.set_name", "region.move", "region.resize":
            return .error("Region operations not yet implemented via AX")

        // MARK: - Plugins
        case "plugin.list", "plugin.insert", "plugin.bypass", "plugin.remove":
            return .error("Plugin operations not yet implemented via AX")

        // MARK: - Automation
        case "automation.get_mode":
            return .error("Automation mode reading not yet implemented via AX")
        case "automation.set_mode":
            return .error("Automation mode setting not yet implemented via AX")

        default:
            return .error("Unsupported AX operation: \(operation)")
        }
    }

    func healthCheck() async -> ChannelHealth {
        guard PermissionChecker.checkAccessibility() else {
            return .unavailable("Accessibility not trusted — add this process in System Preferences")
        }
        guard ProcessUtils.isLogicProRunning else {
            return .unavailable("Logic Pro is not running")
        }
        // Quick smoke test: can we reach the app root?
        guard AXLogicProElements.appRoot() != nil else {
            return .unavailable("Cannot access Logic Pro AX element")
        }
        return .healthy(detail: "AX connected to Logic Pro")
    }

    // MARK: - Transport

    private func getTransportState() -> ChannelResult {
        guard let transport = AXLogicProElements.getTransportBar() else {
            return .error("Cannot locate transport bar")
        }
        let state = AXValueExtractors.extractTransportState(from: transport)
        return encodeResult(state)
    }

    private func toggleTransportButton(named name: String) -> ChannelResult {
        guard let button = AXLogicProElements.findTransportButton(named: name) else {
            return .error("Cannot find transport button: \(name)")
        }
        guard AXHelpers.performAction(button, kAXPressAction) else {
            return .error("Failed to press transport button: \(name)")
        }
        return .success("{\"toggled\":\"\(name)\"}")
    }

    /// Set the project tempo using the Control Bar's tempo slider.
    ///
    /// The slider does not accept an absolute value. Measured on Logic Pro
    /// 12.2: with the slider reading 120, writing 140 leaves it at 121 and
    /// writing 200 also leaves it at 121 — a write moves it exactly one BPM
    /// toward the number written, whatever that number is. AXIncrement and
    /// AXDecrement move it in coarser steps (10 BPM in that same build).
    ///
    /// So the tempo has to be converged on rather than assigned: coarse
    /// actions while the gap is wide, single-BPM writes to land exactly, and
    /// a readback before reporting success. Neither step size is hardcoded —
    /// every pass re-reads the slider and stops as soon as it stops closing
    /// the gap, so the loop still terminates if a later Logic Pro changes them.
    private func setTempo(params: [String: String]) async -> ChannelResult {
        // The router passes the dispatcher's params through untouched, and the
        // dispatcher sends "bpm" — the key OSCChannel reads. This channel used
        // to read "tempo", so the AX fallback could only ever answer "missing
        // parameter" and no set_tempo ever reached the slider. Accept both.
        guard let target = Self.parseTempo(params) else {
            return .error("Missing or invalid '\(ChannelParam.tempo)' parameter")
        }
        guard let slider = AXLogicProElements.getTempoSlider() else {
            return .error("Cannot locate the tempo slider in the Control Bar")
        }
        guard var current = tempoSliderValue(slider) else {
            return .error("Cannot read the current tempo")
        }

        var steps = 0

        // Coarse pass: AXIncrement/AXDecrement.
        coarse: while steps < ServerConfig.tempoNudgeStepBudget {
            let gap = target - current
            guard abs(gap) > Self.tempoTolerance else { break coarse }
            // Re-resolve the slider every pass. Logic Pro invalidates the
            // element partway through a long nudge sequence — AXError -25202,
            // kAXErrorInvalidUIElement — and a held reference would strand the
            // tempo wherever it happened to be, then report that as a failure.
            guard let slider = AXLogicProElements.getTempoSlider() else { break coarse }
            let action = gap > 0 ? kAXIncrementAction : kAXDecrementAction
            steps += 1
            switch await nudgeTempo(slider, apply: {
                AXHelpers.performActionResult(slider, action)
            }) {
            case .cancelled:
                return .error(Self.cancelledMessage(at: current))
            case .stuck:
                break coarse
            case .moved(let next):
                let stalled = next == current       // slider is against a limit
                let overshot = abs(target - next) >= abs(gap)
                current = next
                // An overshooting step would ping-pong forever. Hand the
                // remainder to the fine pass instead.
                if stalled || overshot { break coarse }
            }
        }

        // Fine pass: each write moves the slider one BPM toward the value
        // written, whatever that value is.
        fine: while steps < ServerConfig.tempoNudgeStepBudget {
            let gap = target - current
            guard abs(gap) > Self.tempoTolerance else { break fine }
            guard let slider = AXLogicProElements.getTempoSlider() else { break fine }
            steps += 1
            switch await nudgeTempo(slider, apply: {
                AXHelpers.setAttributeResult(slider, kAXValueAttribute, NSNumber(value: target))
            }) {
            case .cancelled:
                return .error(Self.cancelledMessage(at: current))
            case .stuck:
                break fine
            case .moved(let next):
                if next == current { break fine }   // at a limit
                current = next
            }
        }

        // Report what the slider actually reads, never what was asked for.
        guard abs(target - current) <= Self.tempoTolerance else {
            return .error(
                "Tempo did not reach \(Self.format(target)) BPM; the slider stopped at "
                + "\(Self.format(current)) BPM after \(steps) step(s)"
            )
        }
        return .success("{\"tempo\":\(Self.format(current))}")
    }

    /// Read the target tempo out of the params the router forwarded.
    ///
    /// Accepts "tempo" as well as the canonical key so a caller that predates
    /// `ChannelParam` still reaches the slider. Not private: the tests pin the
    /// dispatcher's key to the one this channel reads, which is the check that
    /// would have caught the original mismatch.
    static func parseTempo(_ params: [String: String]) -> Double? {
        guard let raw = params[ChannelParam.tempo] ?? params["tempo"] else { return nil }
        return Double(raw)
    }

    /// Half a BPM: the slider reports whole numbers, so anything closer than
    /// this is the same tempo.
    private static let tempoTolerance = 0.5

    private func tempoSliderValue(_ slider: AXUIElement) -> Double? {
        (AXHelpers.getValue(slider) as? NSNumber)?.doubleValue
    }

    private enum NudgeOutcome {
        case moved(Double)
        /// AX kept refusing, or the slider would not budge.
        case stuck
        case cancelled
    }

    /// Apply one nudge and report where the slider settled.
    ///
    /// Retries, because this is not the only thing using the Accessibility
    /// actor: StatePoller reads transport state on its own schedule, and its
    /// reads land in the `await` gaps between nudges. Logic Pro intermittently
    /// refuses a nudge while it is servicing those, and treating the first
    /// refusal as fatal left the tempo stranded partway to the target. The
    /// caller re-resolves the slider between passes, so a retry here also
    /// gets a fresh element rather than re-poking an invalidated one.
    private func nudgeTempo(
        _ slider: AXUIElement, apply: () -> AXError
    ) async -> NudgeOutcome {
        var lastError = AXError.success
        for attempt in 0..<ServerConfig.tempoNudgeRetries {
            lastError = apply()
            // Back off between attempts, so a retry does not arrive while
            // Logic Pro is still busy with whatever refused the last one.
            let settle = ServerConfig.tempoNudgeSettleDelay * Double(attempt + 1)
            do {
                try await Task.sleep(for: .seconds(settle))
            } catch {
                // `try?` here would swallow cancellation and keep nudging a
                // slider nobody is waiting on any more.
                return .cancelled
            }
            if lastError == .success, let value = tempoSliderValue(slider) {
                return .moved(value)
            }
        }
        Log.debug(
            "Tempo nudge gave up after \(ServerConfig.tempoNudgeRetries) attempts, "
            + "last AXError \(lastError.rawValue)",
            subsystem: "ax"
        )
        return .stuck
    }

    private static func cancelledMessage(at tempo: Double) -> String {
        "Cancelled while setting the tempo; it now reads \(format(tempo)) BPM"
    }

    /// Trim the trailing ".0" so a whole-number tempo reads as "140".
    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    private func setCycleRange(params: [String: String]) -> ChannelResult {
        // Cycle range setting via AX is fragile — requires locating the cycle locators
        guard let _ = params["start"], let _ = params["end"] else {
            return .error("Missing 'start' and/or 'end' parameters")
        }
        return .error("Cycle range setting not yet fully implemented via AX")
    }

    // MARK: - Tracks

    private func getTracks() -> ChannelResult {
        let headers = AXLogicProElements.allTrackHeaders()
        if headers.isEmpty {
            return .error("No track headers found — is a project open?")
        }
        var tracks: [TrackState] = []
        for (index, header) in headers.enumerated() {
            let track = AXValueExtractors.extractTrackState(from: header, index: index)
            tracks.append(track)
        }
        return encodeResult(tracks)
    }

    private func getSelectedTrack() -> ChannelResult {
        let headers = AXLogicProElements.allTrackHeaders()
        for (index, header) in headers.enumerated() {
            if AXValueExtractors.isTrackSelected(header) {
                let track = AXValueExtractors.extractTrackState(from: header, index: index)
                return encodeResult(track)
            }
        }
        return .error("No track is currently selected")
    }

    private func selectTrack(params: [String: String]) -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr) else {
            return .error("Missing or invalid 'index' parameter")
        }
        guard let header = AXLogicProElements.findTrackHeader(at: index) else {
            return .error("Track at index \(index) not found")
        }
        guard AXHelpers.performAction(header, kAXPressAction) else {
            return .error("Failed to select track \(index)")
        }
        return .success("{\"selected\":\(index)}")
    }

    private func setTrackToggle(params: [String: String], button buttonName: String) -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr) else {
            return .error("Missing or invalid 'index' parameter")
        }
        let finder: (Int) -> AXUIElement? = switch buttonName {
        case "Mute": AXLogicProElements.findTrackMuteButton
        case "Solo": AXLogicProElements.findTrackSoloButton
        case "Record": AXLogicProElements.findTrackArmButton
        default: { _ in nil }
        }
        guard let button = finder(index) else {
            return .error("Cannot find \(buttonName) button on track \(index)")
        }
        guard AXHelpers.performAction(button, kAXPressAction) else {
            return .error("Failed to click \(buttonName) on track \(index)")
        }
        return .success("{\"track\":\(index),\"toggled\":\"\(buttonName)\"}")
    }

    private func renameTrack(params: [String: String]) -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr),
              let name = params["name"] else {
            return .error("Missing 'index' or 'name' parameter")
        }
        guard let field = AXLogicProElements.findTrackNameField(trackIndex: index) else {
            return .error("Cannot find name field for track \(index)")
        }
        // Double-click to enter edit mode, then set value
        AXHelpers.performAction(field, kAXPressAction)
        AXHelpers.setAttribute(field, kAXValueAttribute, name as CFTypeRef)
        AXHelpers.performAction(field, kAXConfirmAction)
        return .success("{\"track\":\(index),\"name\":\"\(name)\"}")
    }

    // MARK: - Mixer

    private enum MixerTarget {
        case volume
        case pan
    }

    private func getMixerState() -> ChannelResult {
        guard let mixer = AXLogicProElements.getMixerArea() else {
            return .error("Cannot locate mixer — is it visible?")
        }
        let strips = AXHelpers.getChildren(mixer)
        let channelStrips = strips.enumerated().map { index, strip in
            Self.channelStripState(for: strip, index: index)
        }
        return encodeResult(channelStrips)
    }

    private func getChannelStrip(params: [String: String]) -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr) else {
            return .error("Missing or invalid 'index' parameter")
        }
        guard let mixer = AXLogicProElements.getMixerArea() else {
            return .error("Cannot locate mixer — is it visible?")
        }
        let strips = AXHelpers.getChildren(mixer)
        guard index >= 0 && index < strips.count else {
            return .error("Channel strip index \(index) out of range")
        }
        return encodeResult(Self.channelStripState(for: strips[index], index: index))
    }

    /// Read one channel strip. Shared by mixer.get_state and
    /// mixer.get_channel_strip so both resolve controls the same way.
    private static func channelStripState(for strip: AXUIElement, index: Int) -> ChannelStripState {
        let fader = AXLogicProElements.stripControl(
            strip, role: kAXSliderRole, description: AXLogicProElements.StripControl.volume
        )
        let panKnob = AXLogicProElements.stripControl(
            strip, role: kAXSliderRole, description: AXLogicProElements.StripControl.pan
        )
        let eqButton = AXLogicProElements.stripControl(
            strip, role: kAXButtonRole, description: AXLogicProElements.StripControl.eq
        )
        return ChannelStripState(
            trackIndex: index,
            name: AXHelpers.getDescription(strip),
            volume: fader.flatMap { AXValueExtractors.extractSliderValue($0) } ?? 0.0,
            pan: panKnob.flatMap { AXValueExtractors.extractSliderValue($0) } ?? 0.0,
            eqEnabled: eqButton.flatMap { AXHelpers.getAttribute($0, kAXValueAttribute) } == "on"
        )
    }

    private func setMixerValue(params: [String: String], target: MixerTarget) -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr),
              let valueStr = params["value"], let value = Double(valueStr) else {
            return .error("Missing 'index' or 'value' parameter")
        }
        let element: AXUIElement?
        switch target {
        case .volume:
            element = AXLogicProElements.findFader(trackIndex: index)
        case .pan:
            element = AXLogicProElements.findPanKnob(trackIndex: index)
        }
        guard let slider = element else {
            return .error("Cannot find \(target) control for track \(index)")
        }
        AXHelpers.setAttribute(slider, kAXValueAttribute, NSNumber(value: value))
        let label = target == .volume ? "volume" : "pan"
        return .success("{\"\(label)\":\(value),\"track\":\(index)}")
    }

    // MARK: - Project

    private func getProjectInfo() -> ChannelResult {
        guard let window = AXLogicProElements.mainWindow() else {
            return .error("Cannot locate Logic Pro main window")
        }
        let title = AXHelpers.getTitle(window) ?? "Unknown"
        var info = ProjectInfo()
        info.name = title
        info.lastUpdated = Date()
        return encodeResult(info)
    }

    // MARK: - JSON encoding

    private func encodeResult<T: Encodable>(_ value: T) -> ChannelResult {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(value)
            guard let json = String(data: data, encoding: .utf8) else {
                return .error("Failed to encode result to UTF-8")
            }
            return .success(json)
        } catch {
            return .error("JSON encoding failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Errors

enum AccessibilityError: Error, CustomStringConvertible {
    case notTrusted

    var description: String {
        switch self {
        case .notTrusted:
            return "Process is not trusted for Accessibility. Add it in System Preferences > Privacy & Security > Accessibility."
        }
    }
}
