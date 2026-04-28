import Foundation

/// Runs `idevice_id` / `idevicesetlocation` from libimobiledevice (e.g. `brew install libimobiledevice`).
enum LocationToolRunner {
    struct RunResult: Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }
    
    private static var activeDVTProcess: Process?
    private static var activeTunnelProcess: Process?
    private static var activeRSDHost: String?
    private static var activeRSDPort: String?
    
    private static func preferredPythonExecutable() -> String {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let venvPython = "\(home)/.venvs/khons-pmd3/bin/python"
        if fm.isExecutableFile(atPath: venvPython) {
            return venvPython
        }
        return "python3"
    }

    static func resolvedExecutable(named name: String) -> URL? {
        let paths = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        let brewPrefixes = ["/opt/homebrew/bin", "/usr/local/bin"]
        for dir in brewPrefixes + paths {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    static func run(executable: URL, arguments: [String]) async -> RunResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                do {
                    try process.run()
                    process.waitUntilExit()
                    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let stdout = String(data: outData, encoding: .utf8) ?? ""
                    let stderr = String(data: errData, encoding: .utf8) ?? ""
                    continuation.resume(
                        returning: RunResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr))
                } catch {
                    continuation.resume(
                        returning: RunResult(
                            exitCode: -1,
                            stdout: "",
                            stderr: error.localizedDescription))
                }
            }
        }
    }
    
    private static func runPyMobileDevice3(arguments: [String]) async -> RunResult {
        await run(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [preferredPythonExecutable(), "-m", "pymobiledevice3"] + arguments
        )
    }
    
    static func runInShell(_ command: String) async -> RunResult {
        await run(executable: URL(fileURLWithPath: "/bin/zsh"), arguments: ["-lc", command])
    }
    
    static func runInShellStreaming(
        _ command: String,
        onOutput: @escaping @Sendable (String) -> Void
    ) async -> RunResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-lc", command]
                
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                
                let outHandle = outPipe.fileHandleForReading
                let errHandle = errPipe.fileHandleForReading
                var stdoutData = Data()
                var stderrData = Data()
                
                outHandle.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    stdoutData.append(data)
                    if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                        onOutput(text)
                    }
                }
                
                errHandle.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    stderrData.append(data)
                    if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                        onOutput(text)
                    }
                }
                
                do {
                    try process.run()
                    process.waitUntilExit()
                    outHandle.readabilityHandler = nil
                    errHandle.readabilityHandler = nil
                    
                    let trailingOut = outHandle.readDataToEndOfFile()
                    let trailingErr = errHandle.readDataToEndOfFile()
                    if !trailingOut.isEmpty { stdoutData.append(trailingOut) }
                    if !trailingErr.isEmpty { stderrData.append(trailingErr) }
                    
                    let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                    let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                    continuation.resume(
                        returning: RunResult(
                            exitCode: process.terminationStatus,
                            stdout: stdout,
                            stderr: stderr
                        )
                    )
                } catch {
                    outHandle.readabilityHandler = nil
                    errHandle.readabilityHandler = nil
                    continuation.resume(
                        returning: RunResult(exitCode: -1, stdout: "", stderr: error.localizedDescription)
                    )
                }
            }
        }
    }

    static func listDeviceUDIDs(ideviceId: URL) async -> [String] {
        let r = await run(executable: ideviceId, arguments: ["-l"])
        guard r.exitCode == 0 else { return [] }
        return r.stdout
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
    
    static func deviceName(ideviceInfo: URL, udid: String) async -> String? {
        let r = await run(executable: ideviceInfo, arguments: ["-u", udid, "-k", "DeviceName"])
        guard r.exitCode == 0 else { return nil }
        let name = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    static func setLocation(
        idevicesetlocation: URL,
        udid: String?,
        latitude: Double,
        longitude: Double
    ) async -> RunResult {
        var args: [String] = []
        if let udid {
            args += ["-u", udid]
        }
        args += ["--", String(latitude), String(longitude)]
        return await run(executable: idevicesetlocation, arguments: args)
    }
    
    static func startIOS17LocationSimulation(
        udid: String?,
        latitude: Double,
        longitude: Double
    ) async -> RunResult {
        await stopActiveIOS17Simulation()
        let preflight = await prepareDeveloperServices()
        guard preflight.exitCode == 0 else {
            return preflight
        }
        let tunnelResult = await ensureRSDTunnel()
        guard tunnelResult.exitCode == 0 else {
            return tunnelResult
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                
                var args = [preferredPythonExecutable(), "-m", "pymobiledevice3"]
                args += [
                    "developer", "dvt", "simulate-location", "set",
                    "--tunnel", "",
                    "--", String(latitude), String(longitude)
                ]
                process.arguments = args
                
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                
                let outHandle = outPipe.fileHandleForReading
                let errHandle = errPipe.fileHandleForReading
                var stdoutData = Data()
                var stderrData = Data()
                let readySemaphore = DispatchSemaphore(value: 0)
                let errorSemaphore = DispatchSemaphore(value: 0)
                var didSignalReady = false
                var didSignalError = false
                
                func parseChunk(_ text: String) {
                    let lower = text.lowercased()
                    if !didSignalReady, lower.contains("press ctrl+c") || lower.contains("send a sigint") {
                        didSignalReady = true
                        readySemaphore.signal()
                    }
                    if !didSignalError, lower.contains("error") || lower.contains("traceback") {
                        didSignalError = true
                        errorSemaphore.signal()
                    }
                }
                
                outHandle.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    stdoutData.append(data)
                    if let text = String(data: data, encoding: .utf8) {
                        parseChunk(text)
                    }
                }
                
                errHandle.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    stderrData.append(data)
                    if let text = String(data: data, encoding: .utf8) {
                        parseChunk(text)
                    }
                }
                
                do {
                    try process.run()
                    let ready = readySemaphore.wait(timeout: .now() + 8)
                    
                    if ready == .success, process.isRunning {
                        outHandle.readabilityHandler = nil
                        errHandle.readabilityHandler = nil
                        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                        activeDVTProcess = process
                        continuation.resume(
                            returning: RunResult(
                                exitCode: 0,
                                stdout: "DVT location simulation confirmed active.\n\(stdout)",
                                stderr: ""
                            )
                        )
                        return
                    }
                    
                    if process.isRunning {
                        process.terminate()
                        process.waitUntilExit()
                    }
                    outHandle.readabilityHandler = nil
                    errHandle.readabilityHandler = nil
                    
                    let trailingOut = outHandle.readDataToEndOfFile()
                    let trailingErr = errHandle.readDataToEndOfFile()
                    if !trailingOut.isEmpty { stdoutData.append(trailingOut) }
                    if !trailingErr.isEmpty { stderrData.append(trailingErr) }
                    let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                    let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                    
                    continuation.resume(
                        returning: RunResult(
                            exitCode: process.terminationStatus == 0 ? 2 : process.terminationStatus,
                            stdout: stdout,
                            stderr: stderr.isEmpty
                                ? "Simulation backend did not confirm activation on-device."
                                : stderr
                        )
                    )
                } catch {
                    outHandle.readabilityHandler = nil
                    errHandle.readabilityHandler = nil
                    continuation.resume(
                        returning: RunResult(exitCode: -1, stdout: "", stderr: error.localizedDescription)
                    )
                }
            }
        }
    }
    
    static func stopActiveIOS17Simulation() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                if let process = activeDVTProcess, process.isRunning {
                    process.terminate()
                    process.waitUntilExit()
                }
                activeDVTProcess = nil
                continuation.resume(returning: ())
            }
        }
    }
    
    static func clearIOS17LocationSimulation(udid: String?) async -> RunResult {
        await stopActiveIOS17Simulation()
        let preflight = await prepareDeveloperServices()
        guard preflight.exitCode == 0 else {
            return preflight
        }
        let tunnelResult = await ensureRSDTunnel()
        guard tunnelResult.exitCode == 0 else {
            return tunnelResult
        }
        
        var args: [String] = []
        args += ["developer", "dvt", "simulate-location", "clear", "--tunnel", ""]
        return await runPyMobileDevice3(arguments: args)
    }
    
    static func isIOS17LegacyServiceFailure(_ result: RunResult) -> Bool {
        let detail = [result.stdout, result.stderr].joined().lowercased()
        return detail.contains("this tool is currently not supported on ios 17+") ||
            detail.contains("could not start the simulatelocation service")
    }

    static func resetLocation(idevicesetlocation: URL, udid: String?) async -> RunResult {
        var args: [String] = []
        if let udid {
            args += ["-u", udid]
        }
        args.append("reset")
        return await run(executable: idevicesetlocation, arguments: args)
    }

    private static func ensureRSDTunnel() async -> RunResult {
        let probe = await runPyMobileDevice3(arguments: ["developer", "dvt", "ls", "/", "--tunnel", ""])
        if probe.exitCode == 0 {
            return RunResult(exitCode: 0, stdout: "tunneld already available.", stderr: "")
        }
        let detail = [probe.stdout, probe.stderr].joined().lowercased()
        if detail.contains("requires root privileges") {
            let adminStart = runAdminTunnelStart()
            if adminStart.exitCode == 0 {
                return RunResult(exitCode: 0, stdout: "Privileged tunneld daemon started.", stderr: "")
            }
        }
        return RunResult(
            exitCode: probe.exitCode == 0 ? 1 : probe.exitCode,
            stdout: probe.stdout,
            stderr: tunnelFailureMessage(stderr: probe.stderr)
        )
    }

    private static func tunnelFailureMessage(stderr: String) -> String {
        let cleaned = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = cleaned.lowercased()
        if lower.contains("requires root privileges") {
            let adminStart = runAdminTunnelStart()
            if adminStart.exitCode == 0 {
                return "Started privileged tunneld daemon. Retry setting location now."
            }
            return """
            This command requires admin permissions.
            Please run once in Terminal:
            sudo \(preferredPythonExecutable()) -m pymobiledevice3 remote tunneld
            Then retry in Khons.
            """
        }
        if cleaned.isEmpty {
            return "Failed to establish iOS 17+/26 tunnel. Ensure Developer Mode is enabled and device is unlocked."
        }
        return cleaned
    }
    
    private static func prepareDeveloperServices() async -> RunResult {
        let mount = await runPyMobileDevice3(arguments: ["mounter", "auto-mount"])
        if mount.exitCode == 0 {
            return RunResult(exitCode: 0, stdout: mount.stdout, stderr: "")
        }
        
        let detail = [mount.stdout, mount.stderr].joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = detail.lowercased()
        
        if lower.contains("developerdiskimage already mounted") ||
            lower.contains("personalizedimage already mounted")
        {
            return RunResult(exitCode: 0, stdout: detail, stderr: "")
        }
        
        if lower.contains("developer mode") || lower.contains("enable-developer-mode") {
            return RunResult(
                exitCode: mount.exitCode == 0 ? 1 : mount.exitCode,
                stdout: "",
                stderr: """
                Developer Mode is not enabled on the iPhone.
                Enable it on device (Settings > Privacy & Security > Developer Mode), reboot the phone, unlock it, then retry.
                """
            )
        }
        
        if lower.contains("failed to start service") || lower.contains("invalidservice") {
            return RunResult(
                exitCode: mount.exitCode == 0 ? 1 : mount.exitCode,
                stdout: "",
                stderr: """
                Developer services are unavailable on this device session.
                Keep the iPhone unlocked and trusted, open Xcode once with the device attached, then retry.
                
                Raw error:
                \(detail)
                """
            )
        }
        
        return mount
    }

    private static func runAdminTunnelStart() -> RunResult {
        let python = preferredPythonExecutable()
        let shellCommand = "\(python) -m pymobiledevice3 remote tunneld >/tmp/khons-tunneld.log 2>&1 &"
        let escaped = shellCommand.replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
            process.waitUntilExit()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            return RunResult(
                exitCode: process.terminationStatus,
                stdout: String(data: outData, encoding: .utf8) ?? "",
                stderr: String(data: errData, encoding: .utf8) ?? ""
            )
        } catch {
            return RunResult(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }
    }
}
