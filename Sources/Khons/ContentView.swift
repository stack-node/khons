import MapKit
import SwiftUI

private struct Preset: Identifiable {
    var id: String { title }
    let title: String
    let latitude: Double
    let longitude: Double
}

struct ContentView: View {
    @StateObject private var model = KhonsViewModel()
    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090),
            span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
        )
    )

    private let presets: [Preset] = [
        Preset(title: "Apple Park", latitude: 37.3349, longitude: -122.0090),
        Preset(title: "Giza Pyramids", latitude: 29.9792, longitude: 31.1342),
        Preset(title: "Null Island", latitude: 0, longitude: 0),
    ]

    var body: some View {
        ZStack(alignment: .topLeading) {
            MapReader { proxy in
                Map(position: $cameraPosition, interactionModes: .all) {
                    Marker("Target", coordinate: model.targetCoordinate)
                        .tint(.blue)
                    if let simulated = model.simulatedCoordinate {
                        Marker("Device (simulated)", coordinate: simulated)
                            .tint(.orange)
                    }
                }
                .mapStyle(.standard(elevation: .realistic))
                .onTapGesture(count: 1, coordinateSpace: .local) { point in
                    if let coordinate = proxy.convert(point, from: .local) {
                        model.setTargetCoordinate(coordinate)
                    }
                }
            }
            .ignoresSafeArea()
        }
        .overlay(alignment: .bottomLeading) {
            if !model.statusMessage.isEmpty {
                statusOverlay
                    .padding(12)
            }
        }
        .navigationTitle("Khons")
        .navigationSubtitle(titleCoordinateText)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    centerCamera(on: model.simulatedCoordinate ?? model.targetCoordinate)
                } label: {
                    Image(systemName: "location.north.fill")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.95))
                        .frame(width: 34, height: 34)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(
                            Circle()
                                .strokeBorder(.teal.opacity(0.7), lineWidth: 1.2)
                        )
                }
                .buttonStyle(.plain)
                .buttonStyle(RecenterButtonStyle())
                .help("Recenter map")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if model.deviceUDIDs.isEmpty {
                        Text("No connected devices")
                    } else {
                        ForEach(model.deviceUDIDs, id: \.self) { udid in
                            Button {
                                model.selectedUDID = udid
                            } label: {
                                if model.selectedUDID == udid {
                                    Label(model.deviceDisplayLabel(for: udid), systemImage: "checkmark")
                                } else {
                                    Text(model.deviceDisplayLabel(for: udid))
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "iphone")
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                    }
                }
                .help("Select connected device")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Install Dependencies") {
                        Task { await model.installDependencies() }
                    }
                    .disabled(model.dependenciesInstalled)
                    Divider()
                    ForEach(KhonsViewModel.ToolGroup.allCases) { group in
                        Button {
                            model.selectedToolGroup = group
                        } label: {
                            if model.selectedToolGroup == group {
                                Label(group.rawValue, systemImage: "checkmark")
                            } else {
                                Text(group.rawValue)
                            }
                        }
                    }
                } label: {
                    Label("iOS tool group", systemImage: "slider.horizontal.3")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.refreshDevices() }
                } label: {
                    Label("Refresh devices", systemImage: "arrow.clockwise")
                }
                .disabled(model.isBusy)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.setSimulatedLocation() }
                } label: {
                    Image(systemName: "play.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(.green.opacity(0.9), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(model.isBusy)
                .help("Set simulated location")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.resetLocation() }
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(.red.opacity(0.9), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(model.isBusy)
                .help("Reset to real location")
            }
        }
        .overlay {
            if model.isBusy {
                VStack(spacing: 14) {
                    ProgressView(model.busyTitle.isEmpty ? "Working…" : model.busyTitle)
                        .scaleEffect(1.1)
                    if !model.installLog.isEmpty {
                        ScrollView {
                            Text(model.installLog)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .padding(10)
                        }
                        .frame(width: 560, height: 180)
                        .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                        )
                    }
                }
                .padding(20)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.thinMaterial)
            }
        }
        .task {
            await model.refreshDevices()
            centerCamera(on: model.targetCoordinate)
        }
    }

    private var sidebarPanel: some View {
        Form {
            Section("Tools") {
                LabeledContent("idevice_id") {
                    Text(model.ideviceIdPath ?? "not found")
                        .font(.caption)
                        .foregroundStyle(model.ideviceIdPath == nil ? .red : .secondary)
                        .textSelection(.enabled)
                }
                LabeledContent("idevicesetlocation") {
                    Text(model.idevicesetlocationPath ?? "not found")
                        .font(.caption)
                        .foregroundStyle(model.idevicesetlocationPath == nil ? .red : .secondary)
                        .textSelection(.enabled)
                }
            }

            Section("Device") {
                if model.deviceUDIDs.isEmpty {
                    Text("No UDIDs from idevice_id. Connect USB, unlock, tap Trust, then refresh.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if model.deviceUDIDs.count == 1, let u = model.deviceUDIDs.first {
                    LabeledContent("Device") {
                        Text(model.deviceDisplayLabel(for: u))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                } else {
                    Picker("UDID", selection: $model.selectedUDID) {
                        Text("Select...").tag(Optional<String>.none)
                        ForEach(model.deviceUDIDs, id: \.self) { udid in
                            Text(model.deviceDisplayLabel(for: udid)).tag(Optional(udid))
                        }
                    }
                }
            }

            Section("Coordinates") {
                TextField("Latitude", text: $model.latitudeText)
                    .font(.body.monospacedDigit())
                TextField("Longitude", text: $model.longitudeText)
                    .font(.body.monospacedDigit())
                Button("Use typed coordinates") {
                    model.syncTargetFromTextFields()
                }
                .buttonStyle(GlassButtonStyle())
                Menu {
                    ForEach(presets) { p in
                        Button(p.title) {
                            model.applyPreset(latitude: p.latitude, longitude: p.longitude)
                        }
                    }
                } label: {
                    Text("Presets")
                }
                .buttonStyle(GlassButtonStyle())
            }

            Section {
                Button("Set simulated location") {
                    Task { await model.setSimulatedLocation() }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(GlassButtonStyle())

                Button("Reset to real location") {
                    Task { await model.resetLocation() }
                }
                .foregroundStyle(.secondary)
                .buttonStyle(GlassButtonStyle())
            }
            .disabled(model.isBusy || model.idevicesetlocationPath == nil)

        }
        .formStyle(.grouped)
        .frame(width: 360)
        .frame(maxHeight: .infinity, alignment: .top)
        .scrollContentBackground(.hidden)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.2), radius: 18, x: 0, y: 8)
    }

    private var statusOverlay: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Status")
                .font(.caption.weight(.semibold))
            Text(model.statusMessage)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.22), lineWidth: 1)
        )
        .frame(maxWidth: 340, alignment: .leading)
    }

    private func centerCamera(on coordinate: CLLocationCoordinate2D) {
        cameraPosition = .region(
            MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
            )
        )
    }
    
    private var titleCoordinateText: String {
        let coordinate = model.simulatedCoordinate ?? model.targetCoordinate
        return String(format: "Lat %.6f, Lon %.6f", coordinate.latitude, coordinate.longitude)
    }

}

private struct RecenterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .shadow(
                color: .black.opacity(configuration.isPressed ? 0.14 : 0.2),
                radius: configuration.isPressed ? 4 : 8,
                x: 0,
                y: configuration.isPressed ? 2 : 4
            )
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

private struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.bold))
            .foregroundStyle(.white.opacity(0.95))
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(configuration.isPressed ? 0.08 : 0.12),
                                    Color.white.opacity(configuration.isPressed ? 0.01 : 0.04),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 1)
            )
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(configuration.isPressed ? 0.10 : 0.24), lineWidth: 0.8)
                    .blur(radius: 0.2)
                    .padding(1)
            }
            .shadow(color: .black.opacity(configuration.isPressed ? 0.14 : 0.24), radius: 10, x: 0, y: 5)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .brightness(configuration.isPressed ? -0.04 : 0)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}
