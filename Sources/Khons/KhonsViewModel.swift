import Combine
import CoreLocation
import Foundation

@MainActor
final class KhonsViewModel: ObservableObject {
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
    @Published var simulatedCoordinate: CLLocationCoordinate2D?

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
        let udid = resolvedTargetUDID()
        if deviceUDIDs.count > 1, udid == nil {
            statusMessage = "Select a device."
            return
        }

        isBusy = true
        statusMessage = "Setting location…"
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
            let result = await LocationToolRunner.setLocation(
                idevicesetlocation: url,
                udid: udid,
                latitude: lat,
                longitude: lon
            )
            effectiveResult = result
        case .modernIOS:
            effectiveResult = await LocationToolRunner.startIOS17LocationSimulation(
                udid: udid,
                latitude: lat,
                longitude: lon
            )
        }
        isBusy = false
        if effectiveResult.exitCode == 0 {
            targetCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            simulatedCoordinate = targetCoordinate
            statusMessage = "Location set to \(lat), \(lon)."
        } else {
            let detail = [effectiveResult.stdout, effectiveResult.stderr].joined().trimmingCharacters(in: .whitespacesAndNewlines)
            statusMessage = interpretedLocationFailureMessage(
                detail: detail,
                fallback: "Location simulation failed (exit \(effectiveResult.exitCode))."
            )
        }
    }

    func resetLocation() async {
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
