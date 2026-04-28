import Combine
import CoreLocation
import Foundation

@MainActor
final class KhonsViewModel: ObservableObject {
    enum RouteAnchorLock: Equatable {
        case target
        case waypoint(Int)
    }

    enum RouteEndBehavior: String, CaseIterable, Identifiable {
        case stayAtDestination = "Stay at destination"
        case returnToOrigin = "Return to origin"
        case reverse = "Reverse"
        case loop = "Loop"
        case reverseLoop = "Reverse loop"

        var id: String { rawValue }

        var requiresLoopCount: Bool {
            self == .loop || self == .reverseLoop
        }
    }

    enum LoopCountOption: String, CaseIterable, Identifiable {
        case one = "1x"
        case two = "2x"
        case three = "3x"
        case five = "5x"
        case ten = "10x"
        case infinite = "Infinite"

        var id: String { rawValue }

        var cycleCount: Int? {
            switch self {
            case .one: return 1
            case .two: return 2
            case .three: return 3
            case .five: return 5
            case .ten: return 10
            case .infinite: return nil
            }
        }
    }

    enum ToolGroup: String, CaseIterable, Identifiable {
        case legacyIOS = "< iOS 17"
        case modernIOS = ">= iOS 17"

        var id: String { rawValue }
    }

    @Published var deviceUDIDs: [String] = []
    @Published var selectedUDID: String?
    @Published var latitudeText = "37.3349"
    @Published var longitudeText = "-122.0090"
    @Published var statusMessage = ""
    @Published var isBusy = false
    @Published var busyTitle = ""
    @Published var installLog = ""
    @Published var ideviceIdPath: String?
    @Published var ideviceInfoPath: String?
    @Published var idevicesetlocationPath: String?
    @Published var deviceNamesByUDID: [String: String] = [:]
    @Published var selectedToolGroup: ToolGroup = .modernIOS
    @Published var dependenciesInstalled = false
    @Published var targetCoordinate = CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090)
    @Published var travelCoordinates: [CLLocationCoordinate2D] = []
    @Published var simulatedCoordinate: CLLocationCoordinate2D?
    @Published var isTraveling = false
    @Published var isTravelPaused = false
    @Published var lockedRouteAnchor: RouteAnchorLock?
    @Published var selectedRouteEndBehavior: RouteEndBehavior = .stayAtDestination
    @Published var selectedLoopCount: LoopCountOption = .infinite

    private let travelStepCount = 40
    private let travelStepDelayNanoseconds: UInt64 = 1_000_000_000
    private var travelTask: Task<Void, Never>?

    init() {
        refreshToolPaths()
    }

    func refreshToolPaths() {
        ideviceIdPath = LocationToolRunner.resolvedExecutable(named: "idevice_id")?.path
        ideviceInfoPath = LocationToolRunner.resolvedExecutable(named: "ideviceinfo")?.path
        idevicesetlocationPath = LocationToolRunner.resolvedExecutable(named: "idevicesetlocation")?.path
        dependenciesInstalled = areDependenciesInstalled()
        if ideviceIdPath == nil || idevicesetlocationPath == nil {
            statusMessage =
                "Install libimobiledevice (e.g. brew install libimobiledevice) so idevice_id and idevicesetlocation are on your PATH."
        }
    }

    func refreshDevices() async {
        refreshToolPaths()
        guard let path = ideviceIdPath else {
            statusMessage =
                "idevice_id not found. Install with: brew install libimobiledevice"
            deviceUDIDs = []
            return
        }
        let execURL = URL(fileURLWithPath: path)
        isBusy = true
        statusMessage = "Scanning for devices…"
        let list = await LocationToolRunner.listDeviceUDIDs(ideviceId: execURL)
        deviceUDIDs = list
        if let infoPath = ideviceInfoPath {
            let infoURL = URL(fileURLWithPath: infoPath)
            var updatedNames: [String: String] = [:]
            for udid in list {
                if let name = await LocationToolRunner.deviceName(ideviceInfo: infoURL, udid: udid) {
                    updatedNames[udid] = name
                }
            }
            deviceNamesByUDID = updatedNames
        } else {
            deviceNamesByUDID = [:]
        }
        if selectedUDID.map({ !list.contains($0) }) ?? true {
            selectedUDID = list.first
        }
        if list.isEmpty {
            statusMessage =
                "No devices reported by idevice_id. Unlock the iPhone, trust this Mac, and ensure a developer disk image is mounted (open the device in Xcode once)."
        } else {
            statusMessage = "Found \(list.count) device(s)."
        }
        isBusy = false
    }
    
    func installDependencies() async {
        isBusy = true
        busyTitle = "Installing dependencies…"
        installLog = ""
        statusMessage = "Checking Homebrew…"
        appendInstallLog("$ command -v brew")
        
        let hasBrew = await LocationToolRunner.runInShellStreaming("command -v brew >/dev/null 2>&1") { _ in }
        guard hasBrew.exitCode == 0 else {
            isBusy = false
            busyTitle = ""
            statusMessage = "Homebrew is required. Install it first from https://brew.sh"
            appendInstallLog("Homebrew not found.")
            return
        }
        appendInstallLog("Homebrew found.")
        
        statusMessage = "Installing brew dependencies (python, swig, openssl, libimobiledevice)…"
        let brewInstall = await runInstallCommand(
            "brew install python swig openssl@3 libimobiledevice"
        )
        guard brewInstall.exitCode == 0 else {
            isBusy = false
            busyTitle = ""
            let detail = [brewInstall.stdout, brewInstall.stderr].joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            appendInstallLog(detail.isEmpty ? "brew install failed." : detail)
            statusMessage = detail.isEmpty ? "brew install failed." : detail
            return
        }
        
        statusMessage = "Creating Python venv for iOS 17+ tooling…"
        let createVenv = await runInstallCommand(
            "python3 -m venv \"$HOME/.venvs/khons-pmd3\""
        )
        guard createVenv.exitCode == 0 else {
            isBusy = false
            busyTitle = ""
            let detail = [createVenv.stdout, createVenv.stderr].joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            appendInstallLog(detail.isEmpty ? "Failed to create venv." : detail)
            statusMessage = detail.isEmpty ? "Failed to create venv." : detail
            return
        }
        appendInstallLog("Virtual environment ready.")
        
        statusMessage = "Installing pymobiledevice3 in venv…"
        let pipInstall = await runInstallCommand(
            "source \"$HOME/.venvs/khons-pmd3/bin/activate\" && python -m pip install -U pip setuptools wheel && python -m pip install -U pymobiledevice3"
        )
        guard pipInstall.exitCode == 0 else {
            isBusy = false
            busyTitle = ""
            let detail = [pipInstall.stdout, pipInstall.stderr].joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            appendInstallLog(detail.isEmpty ? "pymobiledevice3 install failed." : detail)
            statusMessage = detail.isEmpty ? "pymobiledevice3 install failed." : detail
            return
        }
        
        refreshToolPaths()
        isBusy = false
        busyTitle = ""
        appendInstallLog("Done.")
        statusMessage = """
        Dependencies installed.
        For iOS 17+ DVT tools, launch Khons from a shell with:
        source "$HOME/.venvs/khons-pmd3/bin/activate"
        """
    }

    func applyPreset(latitude: Double, longitude: Double) {
        latitudeText = formatCoord(latitude)
        longitudeText = formatCoord(longitude)
        targetCoordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    func setTargetCoordinate(_ coordinate: CLLocationCoordinate2D) {
        guard isValidCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude) else {
            return
        }
        targetCoordinate = coordinate
        latitudeText = formatCoord(coordinate.latitude)
        longitudeText = formatCoord(coordinate.longitude)
    }

    func handleMapCoordinateSelection(_ coordinate: CLLocationCoordinate2D) {
        guard isValidCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude) else {
            return
        }

        switch lockedRouteAnchor {
        case .target:
            setTravelCoordinate(after: nil, to: coordinate)
            statusMessage = "Created or updated P1 from the locked target."
        case .waypoint(let index):
            setTravelCoordinate(after: index, to: coordinate)
            statusMessage = "Created or updated P\(index + 2) from the locked waypoint."
        case nil:
            setTargetCoordinate(coordinate)
        }
    }

    func toggleRouteAnchorLock(_ anchor: RouteAnchorLock) {
        if lockedRouteAnchor == anchor {
            lockedRouteAnchor = nil
        } else {
            lockedRouteAnchor = anchor
        }
    }

    func isRouteAnchorLocked(_ anchor: RouteAnchorLock) -> Bool {
        lockedRouteAnchor == anchor
    }

    func lockLatestRouteAnchor() {
        if let lastIndex = travelCoordinates.indices.last {
            lockedRouteAnchor = .waypoint(lastIndex)
            statusMessage = "Locked latest waypoint P\(lastIndex + 1). The next map click creates P\(lastIndex + 2)."
        } else {
            lockedRouteAnchor = .target
            statusMessage = "Locked target. The next map click creates P1."
        }
    }

    func setTravelCoordinate(after anchorIndex: Int?, to coordinate: CLLocationCoordinate2D) {
        guard isValidCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude) else {
            return
        }
        let insertionIndex = (anchorIndex ?? -1) + 1
        if insertionIndex < travelCoordinates.count {
            travelCoordinates[insertionIndex] = coordinate
        } else {
            travelCoordinates.append(coordinate)
        }
    }

    func removeTravelCoordinate(at index: Int) {
        guard travelCoordinates.indices.contains(index) else {
            return
        }
        travelCoordinates.remove(at: index)
        switch lockedRouteAnchor {
        case .waypoint(let lockedIndex) where lockedIndex == index:
            lockedRouteAnchor = nil
        case .waypoint(let lockedIndex) where lockedIndex > index:
            lockedRouteAnchor = .waypoint(lockedIndex - 1)
        default:
            break
        }
    }

    var hasTravelRoute: Bool {
        !travelCoordinates.isEmpty
    }

    var routeCoordinates: [CLLocationCoordinate2D] {
        [targetCoordinate] + travelCoordinates
    }

    func coordinateDescription(for coordinate: CLLocationCoordinate2D) -> String {
        "\(formatCoord(coordinate.latitude)), \(formatCoord(coordinate.longitude))"
    }

    func syncTargetFromTextFields() {
        guard
            let lat = Double(latitudeText.trimmingCharacters(in: .whitespacesAndNewlines)),
            let lon = Double(longitudeText.trimmingCharacters(in: .whitespacesAndNewlines)),
            isValidCoordinate(latitude: lat, longitude: lon)
        else {
            return
        }
        targetCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    func setSimulatedLocation() async {
        guard let lat = Double(latitudeText.trimmingCharacters(in: .whitespacesAndNewlines)),
            let lon = Double(longitudeText.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            statusMessage = "Enter valid numbers for latitude and longitude."
            return
        }
        guard isValidCoordinate(latitude: lat, longitude: lon) else {
            statusMessage = "Latitude must be −90…90 and longitude −180…180."
            return
        }

        let target = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        targetCoordinate = target

        guard validateSimulationTargetSelection() else {
            return
        }

        if hasTravelRoute {
            startTravel()
        } else {
            await setStaticSimulatedLocation(to: target)
        }
    }

    func startTravel() {
        let route = routeCoordinates
        guard route.count > 1 else {
            statusMessage = "Create a travel point by dragging out from the target pin."
            return
        }
        guard validateSimulationTargetSelection() else {
            return
        }

        cancelTravelLoop(markPaused: false)
        isTraveling = true
        isTravelPaused = false
        statusMessage = "Starting travel simulation…"

        let plan = buildTravelPlan(from: route)
        let initialState = travelState(for: simulatedCoordinate, path: plan.path)

        travelTask = Task { [weak self] in
            guard let self else { return }
            await self.runTravelLoop(
                path: plan.path,
                repeatsInfinitely: plan.repeatsInfinitely,
                completionMessage: plan.completionMessage,
                initialSegmentIndex: initialState.segmentIndex,
                initialProgress: initialState.progress
            )
        }
    }

    func pauseTravel() {
        guard isTraveling else {
            return
        }
        cancelTravelLoop(markPaused: true)
        let coordinate = simulatedCoordinate ?? targetCoordinate
        statusMessage = """
        Travel paused at \(formatCoord(coordinate.latitude)), \(formatCoord(coordinate.longitude)).
        """
    }

    private func setStaticSimulatedLocation(to coordinate: CLLocationCoordinate2D) async {
        cancelTravelLoop(markPaused: false)
        isBusy = true
        statusMessage = "Setting location…"
        let effectiveResult = await applyLocationSimulation(to: coordinate)
        isBusy = false
        if effectiveResult.exitCode == 0 {
            targetCoordinate = coordinate
            simulatedCoordinate = coordinate
            isTravelPaused = false
            if selectedToolGroup == .modernIOS {
                statusMessage = """
                Location set to \(formatCoord(coordinate.latitude)), \(formatCoord(coordinate.longitude)).
                Keep Khons open while iOS 17+ simulation is active.
                """
            } else {
                statusMessage = "Location set to \(formatCoord(coordinate.latitude)), \(formatCoord(coordinate.longitude))."
            }
        } else {
            let detail = [effectiveResult.stdout, effectiveResult.stderr].joined().trimmingCharacters(in: .whitespacesAndNewlines)
            statusMessage = interpretedLocationFailureMessage(
                detail: detail,
                fallback: "Location simulation failed (exit \(effectiveResult.exitCode))."
            )
        }
    }

    private func runTravelLoop(
        path: [CLLocationCoordinate2D],
        repeatsInfinitely: Bool,
        completionMessage: String,
        initialSegmentIndex: Int,
        initialProgress: Double
    ) async {
        guard path.count > 1 else {
            cancelTravelLoop(markPaused: false)
            return
        }

        var segmentIndex = initialSegmentIndex
        var progress = initialProgress

        if simulatedCoordinate == nil {
            let initialResult = await applyLocationSimulation(to: path[0])
            if initialResult.exitCode == 0 {
                simulatedCoordinate = path[0]
            } else {
                finishTravelWithError(initialResult)
                return
            }
        }

        while !Task.isCancelled {
            let delta = 1.0 / Double(travelStepCount)
            let segmentStart = path[segmentIndex]
            let segmentEnd = path[segmentIndex + 1]
            progress = min(1, progress + delta)

            let nextCoordinate = interpolate(from: segmentStart, to: segmentEnd, progress: progress)
            let result = await applyLocationSimulation(to: nextCoordinate)
            if result.exitCode != 0 {
                finishTravelWithError(result)
                return
            }

            simulatedCoordinate = nextCoordinate
            statusMessage = """
            Traveling… \(coordinateDescription(for: nextCoordinate))
            """

            if progress >= 1 {
                if segmentIndex >= path.count - 2 {
                    if repeatsInfinitely {
                        segmentIndex = 0
                        progress = 0
                    } else {
                        finishTravelNormally(message: completionMessage)
                        return
                    }
                } else {
                    segmentIndex += 1
                    progress = 0
                }
            }

            do {
                try await Task.sleep(nanoseconds: travelStepDelayNanoseconds)
            } catch {
                return
            }
        }
    }

    private func finishTravelWithError(_ result: LocationToolRunner.RunResult) {
        cancelTravelLoop(markPaused: true)
        let detail = [result.stdout, result.stderr].joined().trimmingCharacters(in: .whitespacesAndNewlines)
        statusMessage = interpretedLocationFailureMessage(
            detail: detail,
            fallback: "Travel simulation failed (exit \(result.exitCode))."
        )
    }

    private func finishTravelNormally(message: String) {
        travelTask = nil
        isTraveling = false
        isTravelPaused = false
        statusMessage = message
    }

    private func cancelTravelLoop(markPaused: Bool) {
        travelTask?.cancel()
        travelTask = nil
        isTraveling = false
        isTravelPaused = markPaused
    }

    private func validateSimulationTargetSelection() -> Bool {
        let udid = resolvedTargetUDID()
        if deviceUDIDs.count > 1, udid == nil {
            statusMessage = "Select a device."
            return false
        }
        return true
    }

    private func applyLocationSimulation(to coordinate: CLLocationCoordinate2D) async -> LocationToolRunner.RunResult {
        let udid = resolvedTargetUDID()
        let effectiveResult: LocationToolRunner.RunResult
        switch selectedToolGroup {
        case .legacyIOS:
            guard let tool = idevicesetlocationPath else {
                refreshToolPaths()
                return LocationToolRunner.RunResult(
                    exitCode: 1,
                    stdout: "",
                    stderr: "idevicesetlocation not found."
                )
            }
            let url = URL(fileURLWithPath: tool)
            let result = await LocationToolRunner.setLocation(
                idevicesetlocation: url,
                udid: udid,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
            effectiveResult = result
        case .modernIOS:
            effectiveResult = await LocationToolRunner.startIOS17LocationSimulation(
                udid: udid,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
        }
        return effectiveResult
    }

    func resetLocation() async {
        cancelTravelLoop(markPaused: false)
        let udid = resolvedTargetUDID()
        if deviceUDIDs.count > 1, udid == nil {
            statusMessage = "Select a device."
            return
        }
        isBusy = true
        statusMessage = "Resetting location…"
        let effectiveResult: LocationToolRunner.RunResult
        switch selectedToolGroup {
        case .legacyIOS:
            guard let tool = idevicesetlocationPath else {
                refreshToolPaths()
                isBusy = false
                statusMessage = "idevicesetlocation not found."
                return
            }
            let url = URL(fileURLWithPath: tool)
            effectiveResult = await LocationToolRunner.resetLocation(idevicesetlocation: url, udid: udid)
        case .modernIOS:
            effectiveResult = await LocationToolRunner.clearIOS17LocationSimulation(udid: udid)
        }
        isBusy = false
        if effectiveResult.exitCode == 0 {
            simulatedCoordinate = nil
            isTravelPaused = false
            statusMessage = "Location simulation reset."
        } else {
            let detail = [effectiveResult.stdout, effectiveResult.stderr].joined().trimmingCharacters(in: .whitespacesAndNewlines)
            statusMessage = interpretedLocationFailureMessage(
                detail: detail,
                fallback: "Reset failed (exit \(effectiveResult.exitCode))."
            )
        }
    }

    private func formatCoord(_ value: Double) -> String {
        var s = String(value)
        if s.contains(".") {
            while s.last == "0", s.contains(".") { s.removeLast() }
            if s.last == "." { s.removeLast() }
        }
        return s
    }

    private func isValidCoordinate(latitude: Double, longitude: Double) -> Bool {
        (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }

    private func interpolate(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        progress: Double
    ) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: start.latitude + ((end.latitude - start.latitude) * progress),
            longitude: start.longitude + ((end.longitude - start.longitude) * progress)
        )
    }

    private func travelState(
        for coordinate: CLLocationCoordinate2D?,
        path: [CLLocationCoordinate2D]
    ) -> (segmentIndex: Int, progress: Double) {
        guard let coordinate, path.count > 1 else {
            return (0, 0)
        }

        var bestSegmentIndex = 0
        var bestProgress = 0.0
        var bestDistanceSquared = Double.greatestFiniteMagnitude

        for segmentIndex in 0..<(path.count - 1) {
            let start = path[segmentIndex]
            let end = path[segmentIndex + 1]
            let deltaLatitude = end.latitude - start.latitude
            let deltaLongitude = end.longitude - start.longitude
            let segmentLengthSquared = (deltaLatitude * deltaLatitude) + (deltaLongitude * deltaLongitude)
            guard segmentLengthSquared > 0 else {
                continue
            }

            let progress = min(
                1,
                max(
                    0,
                    (
                        ((coordinate.latitude - start.latitude) * deltaLatitude) +
                        ((coordinate.longitude - start.longitude) * deltaLongitude)
                    ) / segmentLengthSquared
                )
            )
            let projected = interpolate(from: start, to: end, progress: progress)
            let distanceSquared =
                pow(projected.latitude - coordinate.latitude, 2) +
                pow(projected.longitude - coordinate.longitude, 2)

            if distanceSquared < bestDistanceSquared {
                bestDistanceSquared = distanceSquared
                bestSegmentIndex = segmentIndex
                bestProgress = progress
            }
        }

        return (bestSegmentIndex, bestProgress)
    }

    private func buildTravelPlan(from route: [CLLocationCoordinate2D]) -> (
        path: [CLLocationCoordinate2D],
        repeatsInfinitely: Bool,
        completionMessage: String
    ) {
        let origin = route[0]

        switch selectedRouteEndBehavior {
        case .stayAtDestination:
            return (
                path: route,
                repeatsInfinitely: false,
                completionMessage: "Arrived at the final destination."
            )
        case .returnToOrigin:
            return (
                path: route + [origin],
                repeatsInfinitely: false,
                completionMessage: "Returned to the route origin."
            )
        case .reverse:
            return (
                path: route + Array(route.dropLast().reversed()),
                repeatsInfinitely: false,
                completionMessage: "Ran the route in reverse back to the origin."
            )
        case .loop:
            let cycle = route + [origin]
            return (
                path: repeatedPath(from: cycle, count: selectedLoopCount.cycleCount),
                repeatsInfinitely: selectedLoopCount.cycleCount == nil,
                completionMessage: selectedLoopCount.cycleCount == nil
                    ? "Looping route."
                    : "Completed \(selectedLoopCount.rawValue) of the route loop."
            )
        case .reverseLoop:
            let cycle = route + Array(route.dropLast().reversed())
            return (
                path: repeatedPath(from: cycle, count: selectedLoopCount.cycleCount),
                repeatsInfinitely: selectedLoopCount.cycleCount == nil,
                completionMessage: selectedLoopCount.cycleCount == nil
                    ? "Reverse looping route."
                    : "Completed \(selectedLoopCount.rawValue) of the reverse loop."
            )
        }
    }

    private func repeatedPath(from cycle: [CLLocationCoordinate2D], count: Int?) -> [CLLocationCoordinate2D] {
        guard let count else {
            return cycle
        }
        guard count > 1 else {
            return cycle
        }

        var path = cycle
        for _ in 2...count {
            path.append(contentsOf: cycle.dropFirst())
        }
        return path
    }

    private func interpretedLocationFailureMessage(detail: String, fallback: String) -> String {
        let lower = detail.lowercased()
        if lower.contains("this tool is currently not supported on ios 17+") ||
            lower.contains("could not start the simulatelocation service")
        {
            return """
            iOS 17+ no longer supports libimobiledevice's legacy simulatelocation service.
            Khons now falls back to pymobiledevice3 DVT simulation. If this still fails, install/update pymobiledevice3:
            python3 -m pip install -U pymobiledevice3
            """
        }
        return detail.isEmpty ? fallback : detail
    }

    private func runInstallCommand(_ command: String) async -> LocationToolRunner.RunResult {
        appendInstallLog("$ \(command)")
        return await LocationToolRunner.runInShellStreaming(command) { chunk in
            Task { @MainActor in
                self.appendInstallLogChunk(chunk)
            }
        }
    }
    
    private func appendInstallLog(_ line: String) {
        let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if installLog.isEmpty {
            installLog = cleaned
        } else {
            installLog += "\n\(cleaned)"
        }
    }

    private func appendInstallLogChunk(_ chunk: String) {
        let normalized = chunk.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        for line in lines {
            appendInstallLog(line)
        }
    }

    private func areDependenciesInstalled() -> Bool {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let venvPython = "\(home)/.venvs/khons-pmd3/bin/python"
        let hasVenv = fm.isExecutableFile(atPath: venvPython)
        return hasVenv && ideviceIdPath != nil && idevicesetlocationPath != nil
    }

    func deviceDisplayLabel(for udid: String) -> String {
        if let name = deviceNamesByUDID[udid], !name.isEmpty {
            return "\(name): \(udid)"
        }
        return udid
    }

    /// When several devices are attached, require an explicit pick; otherwise libimobiledevice default is fine.
    private func resolvedTargetUDID() -> String? {
        if deviceUDIDs.count > 1 {
            return selectedUDID
        }
        return selectedUDID ?? deviceUDIDs.first
    }
}
