import Combine
import CoreLocation
import Foundation
import MapKit

@MainActor
final class KhonsViewModel: NSObject, ObservableObject {
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

    enum WaypointMappingMode: String, CaseIterable, Identifiable {
        case simple = "Simple"
        case advancedWalk = "Advanced walk"
        case advancedDrive = "Advanced drive"
        case advancedCombined = "Advanced combined"

        var id: String { rawValue }
    }

    struct SearchSuggestion: Identifiable, Equatable {
        var id: String { "\(title)|\(subtitle)" }
        let title: String
        let subtitle: String

        var query: String {
            subtitle.isEmpty ? title : "\(title), \(subtitle)"
        }

        var displayText: String {
            subtitle.isEmpty ? title : "\(title) \(subtitle)"
        }
    }

    struct RoutePreviewSegment: Identifiable {
        let index: Int
        let coordinates: [CLLocationCoordinate2D]

        var id: Int { index }
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
    @Published var searchText = "" {
        didSet {
            scheduleSearchSuggestionsRefresh()
        }
    }
    @Published var isSearching = false
    @Published var searchSuggestions: [SearchSuggestion] = []
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
    @Published var selectedWaypointMapping: WaypointMappingMode = .simple {
        didSet {
            scheduleRoutePreviewRefresh()
        }
    }
    @Published var routePreviewCoordinates: [CLLocationCoordinate2D] = []
    @Published var routePreviewSegments: [RoutePreviewSegment] = []
    @Published var hoveredRouteSegmentIndex: Int?
    @Published var hoveredRouteWaypointIndex: Int?
    @Published var activeTravelSegmentIndex: Int?
    @Published var activeTravelSegmentProgress: Double = 0
    @Published var activeTravelSegmentCount: Int = 0

    private let travelStepCount = 40
    private let travelStepDelayNanoseconds: UInt64 = 1_000_000_000
    private var travelTask: Task<Void, Never>?
    private var routePreviewTask: Task<Void, Never>?
    private var searchSuggestionsTask: Task<Void, Never>?
    private let searchCompleter = MKLocalSearchCompleter()

    override init() {
        super.init()
        searchCompleter.delegate = self
        searchCompleter.resultTypes = [.address, .pointOfInterest]
        refreshToolPaths()
        scheduleRoutePreviewRefresh()
        scheduleSearchSuggestionsRefresh()
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
        scheduleRoutePreviewRefresh()
    }

    func setTargetCoordinate(_ coordinate: CLLocationCoordinate2D) {
        guard isValidCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude) else {
            return
        }
        targetCoordinate = coordinate
        latitudeText = formatCoord(coordinate.latitude)
        longitudeText = formatCoord(coordinate.longitude)
        scheduleRoutePreviewRefresh()
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

    private func scheduleRoutePreviewRefresh() {
        routePreviewTask?.cancel()
        routePreviewTask = Task { [weak self] in
            guard let self else { return }
            let preview = await self.buildRoutePreview()
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.routePreviewCoordinates = preview.coordinates
                self.routePreviewSegments = preview.segments
            }
        }
    }

    func setHoveredRouteSegmentIndex(_ index: Int?) {
        hoveredRouteSegmentIndex = index
        hoveredRouteWaypointIndex = index
    }

    func clearRouteHover() {
        hoveredRouteSegmentIndex = nil
        hoveredRouteWaypointIndex = nil
    }

    var routeProgressFraction: Double {
        guard activeTravelSegmentCount > 0 else {
            return 0
        }
        let segmentIndex = Double(activeTravelSegmentIndex ?? 0)
        let fraction = (segmentIndex + activeTravelSegmentProgress) / Double(activeTravelSegmentCount)
        return min(1, max(0, fraction))
    }

    var routeProgressBannerTitle: String? {
        guard activeTravelSegmentCount > 0 else {
            return nil
        }
        if isTraveling {
            return "Traveling route"
        }
        if isTravelPaused {
            return "Route paused"
        }
        if simulatedCoordinate != nil {
            return "Route complete"
        }
        return "Route progress"
    }

    var routeProgressBannerSubtitle: String? {
        guard activeTravelSegmentCount > 0 else {
            return nil
        }
        let segmentNumber = min((activeTravelSegmentIndex ?? 0) + 1, activeTravelSegmentCount)
        let percent = Int((routeProgressFraction * 100).rounded())
        return "Leg \(segmentNumber) of \(activeTravelSegmentCount) • \(percent)%"
    }

    private func scheduleSearchSuggestionsRefresh() {
        searchSuggestionsTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchSuggestions = []
            searchCompleter.queryFragment = ""
            return
        }

        searchSuggestionsTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.searchCompleter.queryFragment = query
            }
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
        scheduleRoutePreviewRefresh()
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
        scheduleRoutePreviewRefresh()
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
        setTargetCoordinate(CLLocationCoordinate2D(latitude: lat, longitude: lon))
    }

    func searchLocation() async -> CLLocationCoordinate2D? {
        await searchLocation(using: searchText)
    }

    func searchLocation(using query: String) async -> CLLocationCoordinate2D? {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            statusMessage = "Enter a location or address to search."
            return nil
        }

        isSearching = true
        statusMessage = "Searching for “\(query)”…"

        let results = await geocodeAddress(query)
        isSearching = false

        guard let coordinate = results.first?.location?.coordinate else {
            statusMessage = "No matching location found for “\(query)”."
            return nil
        }

        statusMessage = "Found “\(query)” at \(coordinate.latitude), \(coordinate.longitude)."
        return coordinate
    }

    func selectSearchSuggestion(_ suggestion: SearchSuggestion) async -> CLLocationCoordinate2D? {
        searchText = suggestion.displayText
        guard let coordinate = await searchLocation(using: suggestion.query) else {
            return nil
        }
        setTargetCoordinate(coordinate)
        return coordinate
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
            await startTravel()
        } else {
            await setStaticSimulatedLocation(to: target)
        }
    }

    func startTravel() async {
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

        let plan = await buildTravelPlan(from: route)
        let initialState = travelState(for: simulatedCoordinate, path: plan.path)
        activeTravelSegmentCount = max(plan.path.count - 1, 0)
        activeTravelSegmentIndex = initialState.segmentIndex
        activeTravelSegmentProgress = initialState.progress

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
            activeTravelSegmentIndex = nil
            activeTravelSegmentProgress = 0
            activeTravelSegmentCount = 0
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
        activeTravelSegmentCount = max(path.count - 1, 0)

        if simulatedCoordinate == nil {
            let initialResult = await applyLocationSimulation(to: path[0])
            if initialResult.exitCode == 0 {
                simulatedCoordinate = path[0]
                activeTravelSegmentIndex = segmentIndex
                activeTravelSegmentProgress = progress
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
            activeTravelSegmentIndex = segmentIndex
            activeTravelSegmentProgress = progress
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
        if !markPaused {
            activeTravelSegmentIndex = nil
            activeTravelSegmentProgress = 0
            activeTravelSegmentCount = 0
        }
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
            activeTravelSegmentIndex = nil
            activeTravelSegmentProgress = 0
            activeTravelSegmentCount = 0
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

    private struct TravelPlan {
        let path: [CLLocationCoordinate2D]
        let repeatsInfinitely: Bool
        let completionMessage: String
    }

    private func buildTravelPlan(from route: [CLLocationCoordinate2D]) async -> TravelPlan {
        let mappedRoute = await mappedRouteCoordinates(from: route, includeEndBehavior: true)
        return travelPlan(from: mappedRoute)
    }

    private struct RoutePreview {
        let coordinates: [CLLocationCoordinate2D]
        let segments: [RoutePreviewSegment]
    }

    private func buildRoutePreview() async -> RoutePreview {
        let route = routeCoordinates
        guard route.count > 1 else {
            return RoutePreview(coordinates: route, segments: [])
        }

        let segments = await mappedRouteSegments(from: route, includeEndBehavior: true)
        let flattened = segments.flatMap(\.coordinates)
        return RoutePreview(
            coordinates: flattened.isEmpty ? route : flattened,
            segments: segments
        )
    }

    private func mappedRouteCoordinates(from route: [CLLocationCoordinate2D], includeEndBehavior: Bool = false) async -> [CLLocationCoordinate2D] {
        let segments = await mappedRouteSegments(from: route, includeEndBehavior: includeEndBehavior)
        guard let first = segments.first?.coordinates.first else {
            return route
        }

        var result: [CLLocationCoordinate2D] = [first]
        for segment in segments {
            guard !segment.coordinates.isEmpty else { continue }
            result.append(contentsOf: segment.coordinates.dropFirst())
        }
        return result
    }

    private func mappedRouteSegments(from route: [CLLocationCoordinate2D], includeEndBehavior: Bool) async -> [RoutePreviewSegment] {
        let previewRoute = previewRouteCoordinates(from: route, includeEndBehavior: includeEndBehavior)
        guard previewRoute.count > 1 else {
            return []
        }

        var segments: [RoutePreviewSegment] = []
        for segmentIndex in 0..<(previewRoute.count - 1) {
            let start = previewRoute[segmentIndex]
            let end = previewRoute[segmentIndex + 1]
            let coordinates = await mappedLegCoordinates(from: start, to: end)
            segments.append(RoutePreviewSegment(index: segmentIndex, coordinates: coordinates))
        }
        return segments
    }

    private func previewRouteCoordinates(
        from route: [CLLocationCoordinate2D],
        includeEndBehavior: Bool
    ) -> [CLLocationCoordinate2D] {
        guard includeEndBehavior, route.count > 1 else {
            return route
        }

        let origin = route[0]
        switch selectedRouteEndBehavior {
        case .stayAtDestination:
            return route
        case .returnToOrigin:
            return route + [origin]
        case .reverse:
            return route + Array(route.dropLast().reversed())
        case .loop:
            return route + [origin]
        case .reverseLoop:
            return route + Array(route.dropLast().reversed())
        }
    }

    private func travelPlan(from mappedRoute: [CLLocationCoordinate2D]) -> TravelPlan {
        let origin = mappedRoute[0]

        switch selectedRouteEndBehavior {
        case .stayAtDestination:
            return TravelPlan(
                path: mappedRoute,
                repeatsInfinitely: false,
                completionMessage: "Arrived at the final destination."
            )
        case .returnToOrigin:
            return TravelPlan(
                path: mappedRoute + [origin],
                repeatsInfinitely: false,
                completionMessage: "Returned to the route origin."
            )
        case .reverse:
            return TravelPlan(
                path: mappedRoute + Array(mappedRoute.dropLast().reversed()),
                repeatsInfinitely: false,
                completionMessage: "Ran the route in reverse back to the origin."
            )
        case .loop:
            let cycle = mappedRoute + [origin]
            return TravelPlan(
                path: repeatedPath(from: cycle, count: selectedLoopCount.cycleCount),
                repeatsInfinitely: selectedLoopCount.cycleCount == nil,
                completionMessage: selectedLoopCount.cycleCount == nil
                    ? "Looping route."
                    : "Completed \(selectedLoopCount.rawValue) of the route loop."
            )
        case .reverseLoop:
            let cycle = mappedRoute + Array(mappedRoute.dropLast().reversed())
            return TravelPlan(
                path: repeatedPath(from: cycle, count: selectedLoopCount.cycleCount),
                repeatsInfinitely: selectedLoopCount.cycleCount == nil,
                completionMessage: selectedLoopCount.cycleCount == nil
                    ? "Reverse looping route."
                    : "Completed \(selectedLoopCount.rawValue) of the reverse loop."
            )
        }
    }

    private func mappedLegCoordinates(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) async -> [CLLocationCoordinate2D] {
        switch selectedWaypointMapping {
        case .simple:
            return [start, end]
        case .advancedWalk:
            return await directionsPath(from: start, to: end, transportType: .walking) ?? [start, end]
        case .advancedDrive:
            return await directionsPath(from: start, to: end, transportType: .automobile) ?? [start, end]
        case .advancedCombined:
            let walking = await directionsPath(from: start, to: end, transportType: .walking)
            let driving = await directionsPath(from: start, to: end, transportType: .automobile)
            switch (walking, driving) {
            case let (walking?, driving?):
                return combineMappedPaths(walking, driving)
            case let (walking?, nil):
                return walking
            case let (nil, driving?):
                return driving
            default:
                return [start, end]
            }
        }
    }

    private func combineMappedPaths(
        _ walking: [CLLocationCoordinate2D],
        _ driving: [CLLocationCoordinate2D]
    ) -> [CLLocationCoordinate2D] {
        guard !walking.isEmpty else { return driving }
        guard !driving.isEmpty else { return walking }

        var path = walking
        if let last = path.last, let first = driving.first, last.latitude == first.latitude, last.longitude == first.longitude {
            path.append(contentsOf: driving.dropFirst())
        } else {
            path.append(contentsOf: driving)
        }
        return path
    }

    private func directionsPath(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        transportType: MKDirectionsTransportType
    ) async -> [CLLocationCoordinate2D]? {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
        request.transportType = transportType
        request.requestsAlternateRoutes = false

        return await withCheckedContinuation { continuation in
            MKDirections(request: request).calculate { response, _ in
                guard let route = response?.routes.first else {
                    continuation.resume(returning: nil)
                    return
                }
                let polyline = route.polyline
                guard polyline.pointCount > 0 else {
                    continuation.resume(returning: [])
                    return
                }
                let points = polyline.points()
                let coordinates = (0..<polyline.pointCount).map { points[$0].coordinate }
                continuation.resume(returning: coordinates)
            }
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

    private func geocodeAddress(_ query: String) async -> [CLPlacemark] {
        await withCheckedContinuation { continuation in
            let geocoder = CLGeocoder()
            geocoder.geocodeAddressString(query) { placemarks, _ in
                continuation.resume(returning: placemarks ?? [])
            }
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

extension KhonsViewModel: MKLocalSearchCompleterDelegate {
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let suggestions = completer.results.map {
            SearchSuggestion(title: $0.title, subtitle: $0.subtitle)
        }
        Task { @MainActor [suggestions] in
            self.searchSuggestions = suggestions
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in
            self.searchSuggestions = []
        }
    }
}
