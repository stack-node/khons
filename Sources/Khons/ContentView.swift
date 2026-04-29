import AppKit
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
    @FocusState private var isSearchFieldFocused: Bool
    @State private var cameraRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090),
        span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
    )

    private let presets: [Preset] = [
        Preset(title: "Apple Park", latitude: 37.3349, longitude: -122.0090),
        Preset(title: "Giza Pyramids", latitude: 29.9792, longitude: 31.1342),
        Preset(title: "Null Island", latitude: 0, longitude: 0),
    ]

    var body: some View {
        ZStack(alignment: .topLeading) {
            MacMapView(
                region: cameraRegion,
                targetCoordinate: model.targetCoordinate,
                travelCoordinates: model.travelCoordinates,
                routePreviewCoordinates: model.routePreviewCoordinates,
                routePreviewSegments: model.routePreviewSegments,
                simulatedCoordinate: model.simulatedCoordinate,
                selectedWaypointMapping: model.selectedWaypointMapping,
                onCoordinateSelected: { coordinate in
                    model.handleMapCoordinateSelection(coordinate)
                },
                onTravelCoordinateUpdated: { anchorIndex, coordinate in
                    model.setTravelCoordinate(after: anchorIndex, to: coordinate)
                },
                onRegionChanged: { region in
                    cameraRegion = region
                }
            )
            .ignoresSafeArea()
        }
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 10) {
                searchPanel
                routePanel
            }
            .padding(12)
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
                .padding(.leading, 8)
                .disabled(model.isBusy)
                .help(model.hasTravelRoute ? "Start or resume travel simulation" : "Set simulated location")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.pauseTravel()
                } label: {
                    Image(systemName: "pause.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(model.isTraveling ? .white : .white.opacity(0.35))
                        .frame(width: 30, height: 30)
                        .background((model.isTraveling ? Color.yellow.opacity(0.95) : Color.white.opacity(0.12)), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!model.isTraveling)
                .help("Pause travel at the current spoofed location")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.resetLocation() }
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(model.isTraveling || model.simulatedCoordinate != nil ? .white : .white.opacity(0.35))
                        .frame(width: 30, height: 30)
                        .background((model.isTraveling || model.simulatedCoordinate != nil ? Color.red.opacity(0.9) : Color.white.opacity(0.12)), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 12)
                .disabled(model.isBusy || (!model.isTraveling && model.simulatedCoordinate == nil))
                .help("Reset to real location")
            }
        }
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbarRole(.editor)
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

    private var searchPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Search")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                if model.isSearching {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }

            HStack(spacing: 8) {
                TextField("Search address or place", text: $model.searchText)
                    .focused($isSearchFieldFocused)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                    )
                    .onSubmit {
                        Task {
                            await runSearchAndCenter()
                            isSearchFieldFocused = false
                        }
                    }

                Button {
                    Task {
                        await runSearchAndCenter()
                        isSearchFieldFocused = false
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.95))
                        .frame(width: 30, height: 30)
                        .background(.teal.opacity(0.9), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(model.isSearching)
                .help("Search for a place or address")
            }

            if shouldShowSearchSuggestions {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.searchSuggestions.prefix(5)) { suggestion in
                        Button {
                            Task {
                                if let coordinate = await model.selectSearchSuggestion(suggestion) {
                                    centerCamera(on: coordinate, spanDelta: 0.16, animated: true)
                                }
                                isSearchFieldFocused = false
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(suggestion.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                if !suggestion.subtitle.isEmpty {
                                    Text(suggestion.subtitle)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
        )
        .frame(maxWidth: 290, alignment: .leading)
    }

    private var routePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text("Route")
                    .font(.caption.weight(.semibold))

                Spacer(minLength: 0)

                Button {
                    model.lockLatestRouteAnchor()
                } label: {
                    Image(systemName: "lock.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(width: 24, height: 24)
                        .background(.white.opacity(0.14), in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [])
                .help("Lock the latest route point. Press Return to use this.")

                Menu {
                    ForEach(KhonsViewModel.WaypointMappingMode.allCases) { mode in
                        Button {
                            model.selectedWaypointMapping = mode
                        } label: {
                            if model.selectedWaypointMapping == mode {
                                Label(mode.rawValue, systemImage: "checkmark")
                            } else {
                                Text(mode.rawValue)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: waypointMappingIcon(model.selectedWaypointMapping))
                            .font(.caption.weight(.bold))
                        Text(waypointMappingShortLabel(model.selectedWaypointMapping))
                            .font(.caption2.weight(.semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.08), in: Capsule())
                }
                .menuStyle(.borderlessButton)
                .help("Choose how route waypoints are mapped")

                Menu {
                    ForEach(KhonsViewModel.RouteEndBehavior.allCases) { behavior in
                        Button {
                            model.selectedRouteEndBehavior = behavior
                        } label: {
                            if model.selectedRouteEndBehavior == behavior {
                                Label(behavior.rawValue, systemImage: "checkmark")
                            } else {
                                Text(behavior.rawValue)
                            }
                        }
                    }
                } label: {
                    Image(systemName: routeEndBehaviorIcon(model.selectedRouteEndBehavior))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(width: 18, height: 18)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.08), in: Capsule())
                }
                .menuStyle(.borderlessButton)

                if model.selectedRouteEndBehavior.requiresLoopCount {
                    Menu {
                        ForEach(KhonsViewModel.LoopCountOption.allCases) { option in
                            Button {
                                model.selectedLoopCount = option
                            } label: {
                                if model.selectedLoopCount == option {
                                    Label(option.rawValue, systemImage: "checkmark")
                                } else {
                                    Text(option.rawValue)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "repeat")
                                .font(.caption.weight(.bold))
                            Text(model.selectedLoopCount.rawValue)
                                .font(.caption2.weight(.semibold))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.08), in: Capsule())
                    }
                    .menuStyle(.borderlessButton)
                }
            }

            HStack(spacing: 8) {
                Button {
                    centerCamera(on: model.targetCoordinate)
                } label: {
                    routeRowLabel(
                        title: "Target",
                        detail: model.coordinateDescription(for: model.targetCoordinate),
                        tint: .blue,
                        isLocked: model.isRouteAnchorLocked(.target)
                    )
                }
                .buttonStyle(.plain)
            }

            ForEach(Array(model.travelCoordinates.enumerated()), id: \.offset) { index, coordinate in
                HStack(spacing: 8) {
                    Button {
                        centerCamera(on: coordinate)
                    } label: {
                        routeRowLabel(
                            title: "P\(index + 1)",
                            detail: model.coordinateDescription(for: coordinate),
                            tint: .teal,
                            isLocked: model.isRouteAnchorLocked(.waypoint(index))
                        )
                    }
                    .buttonStyle(.plain)

                    Button {
                        model.removeTravelCoordinate(at: index)
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: 24, height: 24)
                            .background(.red.opacity(0.85), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Delete this travel point")
                }
            }

        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
        )
        .frame(maxWidth: 290, alignment: .leading)
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

    private func centerCamera(on coordinate: CLLocationCoordinate2D, spanDelta: Double = 0.5, animated: Bool = false) {
        let region = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: spanDelta, longitudeDelta: spanDelta)
        )
        if animated {
            withAnimation(.easeInOut(duration: 0.85)) {
                cameraRegion = region
            }
        } else {
            cameraRegion = region
        }
    }

    private var titleCoordinateText: String {
        let coordinate = model.simulatedCoordinate ?? model.targetCoordinate
        return String(format: "Lat %.6f, Lon %.6f", coordinate.latitude, coordinate.longitude)
    }

    private func routeRowLabel(title: String, detail: String, tint: Color, isLocked: Bool) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            (isLocked ? tint.opacity(0.18) : .white.opacity(0.08)),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    private func routeEndBehaviorIcon(_ behavior: KhonsViewModel.RouteEndBehavior) -> String {
        switch behavior {
        case .stayAtDestination:
            return "arrow.right"
        case .returnToOrigin:
            return "arrow.uturn.backward"
        case .reverse:
            return "arrow.triangle.2.circlepath"
        case .loop:
            return "repeat"
        case .reverseLoop:
            return "repeat.1"
        }
    }

    private func waypointMappingIcon(_ mode: KhonsViewModel.WaypointMappingMode) -> String {
        switch mode {
        case .simple:
            return "arrow.triangle.branch"
        case .advancedWalk:
            return "figure.walk"
        case .advancedDrive:
            return "car.fill"
        case .advancedCombined:
            return "map"
        }
    }

    private func waypointMappingShortLabel(_ mode: KhonsViewModel.WaypointMappingMode) -> String {
        switch mode {
        case .simple:
            return "Simple"
        case .advancedWalk:
            return "Walk"
        case .advancedDrive:
            return "Drive"
        case .advancedCombined:
            return "Combined"
        }
    }

    private func runSearchAndCenter() async {
        if let coordinate = await model.searchLocation() {
            centerCamera(on: coordinate, spanDelta: 0.16, animated: true)
        }
    }

    private var shouldShowSearchSuggestions: Bool {
        !model.isSearching &&
        !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !model.searchSuggestions.isEmpty
    }
}

private struct MacMapView: NSViewRepresentable {
    let region: MKCoordinateRegion
    let targetCoordinate: CLLocationCoordinate2D
    let travelCoordinates: [CLLocationCoordinate2D]
    let routePreviewCoordinates: [CLLocationCoordinate2D]
    let routePreviewSegments: [KhonsViewModel.RoutePreviewSegment]
    let simulatedCoordinate: CLLocationCoordinate2D?
    let selectedWaypointMapping: KhonsViewModel.WaypointMappingMode
    let onCoordinateSelected: (CLLocationCoordinate2D) -> Void
    let onTravelCoordinateUpdated: (Int?, CLLocationCoordinate2D) -> Void
    let onRegionChanged: (MKCoordinateRegion) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onRegionChanged: onRegionChanged)
    }

    func makeNSView(context: Context) -> ClickSelectableMapView {
        let mapView = ClickSelectableMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.mapType = .standard
        mapView.isZoomEnabled = true
        mapView.isScrollEnabled = true
        mapView.isPitchEnabled = false
        mapView.isRotateEnabled = false
        mapView.showsCompass = false
        mapView.showsZoomControls = false
        mapView.showsScale = false
        mapView.onCoordinateSelected = onCoordinateSelected
        mapView.onTravelCoordinateUpdated = onTravelCoordinateUpdated
        mapView.targetCoordinate = targetCoordinate
        mapView.travelCoordinates = travelCoordinates
        mapView.routePreviewCoordinates = routePreviewCoordinates
        mapView.routePreviewSegments = routePreviewSegments
        mapView.selectedWaypointMapping = selectedWaypointMapping
        mapView.setRegion(region, animated: false)
        context.coordinator.syncAnnotations(
            on: mapView,
            target: targetCoordinate,
            travelCoordinates: travelCoordinates,
            routePreviewCoordinates: routePreviewCoordinates,
            routePreviewSegments: routePreviewSegments,
            selectedWaypointMapping: selectedWaypointMapping,
            simulated: simulatedCoordinate
        )
        return mapView
    }

    func updateNSView(_ mapView: ClickSelectableMapView, context: Context) {
        mapView.onCoordinateSelected = onCoordinateSelected
        mapView.onTravelCoordinateUpdated = onTravelCoordinateUpdated
        mapView.targetCoordinate = targetCoordinate
        mapView.travelCoordinates = travelCoordinates
        mapView.routePreviewCoordinates = routePreviewCoordinates
        mapView.routePreviewSegments = routePreviewSegments
        mapView.selectedWaypointMapping = selectedWaypointMapping
        context.coordinator.onRegionChanged = onRegionChanged
        context.coordinator.syncAnnotations(
            on: mapView,
            target: targetCoordinate,
            travelCoordinates: travelCoordinates,
            routePreviewCoordinates: routePreviewCoordinates,
            routePreviewSegments: routePreviewSegments,
            selectedWaypointMapping: selectedWaypointMapping,
            simulated: simulatedCoordinate
        )

        if !context.coordinator.isRegion(mapView.region, approximatelyEqualTo: region) {
            context.coordinator.isProgrammaticRegionChange = true
            mapView.setRegion(region, animated: false)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var onRegionChanged: (MKCoordinateRegion) -> Void
        var selectedWaypointMapping: KhonsViewModel.WaypointMappingMode = .simple

        init(onRegionChanged: @escaping (MKCoordinateRegion) -> Void) {
            self.onRegionChanged = onRegionChanged
        }

        var isProgrammaticRegionChange = false

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            if isProgrammaticRegionChange {
                isProgrammaticRegionChange = false
                return
            }
            let region = mapView.region
            DispatchQueue.main.async { [onRegionChanged] in
                onRegionChanged(region)
            }
        }

        func syncAnnotations(
            on mapView: MKMapView,
            target: CLLocationCoordinate2D,
            travelCoordinates: [CLLocationCoordinate2D],
            routePreviewCoordinates: [CLLocationCoordinate2D],
            routePreviewSegments: [KhonsViewModel.RoutePreviewSegment],
            selectedWaypointMapping: KhonsViewModel.WaypointMappingMode,
            simulated: CLLocationCoordinate2D?
        ) {
            let existing = mapView.annotations.filter { !($0 is MKUserLocation) }
            mapView.removeAnnotations(existing)
            let overlays = mapView.overlays
            mapView.removeOverlays(overlays)

            self.selectedWaypointMapping = selectedWaypointMapping
            (mapView as? ClickSelectableMapView)?.routePreviewSegments = routePreviewSegments

            let targetAnnotation = RoutePinAnnotation(kind: .target, title: "Target", coordinate: target)
            mapView.addAnnotation(targetAnnotation)

            for (index, coordinate) in travelCoordinates.enumerated() {
                let travelAnnotation = RoutePinAnnotation(
                    kind: .travel(index),
                    title: "Travel point \(index + 1)",
                    coordinate: coordinate
                )
                mapView.addAnnotation(travelAnnotation)
            }

            if !routePreviewSegments.isEmpty {
                for segment in routePreviewSegments {
                    let routeLine = RouteSegmentPolyline(coordinates: segment.coordinates, segmentIndex: segment.index)
                    mapView.addOverlay(routeLine)
                }
            } else {
                let coordinates = routePreviewCoordinates.count > 1
                    ? routePreviewCoordinates
                    : [target] + travelCoordinates
                if coordinates.count > 1 {
                    let routeLine = RouteSegmentPolyline(coordinates: coordinates, segmentIndex: 0)
                    mapView.addOverlay(routeLine)
                }
            }

            if let simulated {
                let simulatedAnnotation = RoutePinAnnotation(
                    kind: .simulated,
                    title: "Device (simulated)",
                    coordinate: simulated
                )
                mapView.addAnnotation(simulatedAnnotation)
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation {
                return nil
            }
            guard let pinAnnotation = annotation as? RoutePinAnnotation else {
                return nil
            }

            switch pinAnnotation.kind {
            case .target:
                let identifier = "target-dot"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? RouteAnchorDotAnnotationView)
                    ?? RouteAnchorDotAnnotationView(annotation: pinAnnotation, reuseIdentifier: identifier)
                view.annotation = pinAnnotation
                view.configure(
                    image: endpointImage(fillColor: .systemBlue, diameter: 16),
                    dragHandler: { [weak mapView = mapView as? ClickSelectableMapView] (point: NSPoint) in
                        guard let mapView else { return }
                        let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
                        mapView.onTravelCoordinateUpdated?(nil, coordinate)
                    }
                )
                return view
            case .simulated:
                let identifier = "simulated-marker"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: pinAnnotation, reuseIdentifier: identifier)
                view.annotation = pinAnnotation
                view.canShowCallout = false
                view.markerTintColor = NSColor.systemOrange
                view.glyphImage = nil
                return view
            case .travel:
                let identifier = "travel-marker"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? RouteAnchorDotAnnotationView)
                    ?? RouteAnchorDotAnnotationView(annotation: pinAnnotation, reuseIdentifier: identifier)
                view.annotation = pinAnnotation
                let anchorIndex: Int?
                if case let .travel(index) = pinAnnotation.kind {
                    anchorIndex = index
                } else {
                    anchorIndex = nil
                }
                view.configure(
                    image: endpointImage(fillColor: .systemTeal, diameter: 14),
                    dragHandler: { [weak mapView = mapView as? ClickSelectableMapView] (point: NSPoint) in
                        guard let mapView else { return }
                        let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
                        mapView.onTravelCoordinateUpdated?(anchorIndex, coordinate)
                    }
                )
                return view
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? RouteSegmentPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            return RouteSegmentRenderer(
                polyline: polyline,
                mapView: mapView,
                segmentIndex: polyline.segmentIndex,
                mappingMode: self.selectedWaypointMapping
            )
        }

        func isRegion(_ lhs: MKCoordinateRegion, approximatelyEqualTo rhs: MKCoordinateRegion) -> Bool {
            abs(lhs.center.latitude - rhs.center.latitude) < 0.000_001 &&
            abs(lhs.center.longitude - rhs.center.longitude) < 0.000_001 &&
            abs(lhs.span.latitudeDelta - rhs.span.latitudeDelta) < 0.000_001 &&
            abs(lhs.span.longitudeDelta - rhs.span.longitudeDelta) < 0.000_001
        }

        private func endpointImage(fillColor: NSColor, diameter: CGFloat) -> NSImage {
            let size = NSSize(width: diameter, height: diameter)
            let image = NSImage(size: size)
            image.lockFocus()
            let circleRect = NSRect(origin: .zero, size: size)
            fillColor.setFill()
            NSBezierPath(ovalIn: circleRect).fill()
            NSColor.white.withAlphaComponent(0.8).setStroke()
            let outline = NSBezierPath(ovalIn: circleRect.insetBy(dx: 1, dy: 1))
            outline.lineWidth = 1
            outline.stroke()
            image.unlockFocus()
            return image
        }
    }
}

private final class RouteSegmentPolyline: MKPolyline {
    let segmentIndex: Int

    convenience init(coordinates: [CLLocationCoordinate2D], segmentIndex: Int) {
        guard let baseAddress = coordinates.withUnsafeBufferPointer({ $0.baseAddress }) else {
            fatalError("Route segment requires at least one coordinate.")
        }
        self.init(pointer: baseAddress, count: coordinates.count, segmentIndex: segmentIndex)
    }

    init(pointer: UnsafePointer<CLLocationCoordinate2D>, count: Int, segmentIndex: Int) {
        self.segmentIndex = segmentIndex
        super.init(coordinates: pointer, count: count)
    }
}

private final class RouteSegmentRenderer: MKPolylineRenderer {
    private weak var mapView: ClickSelectableMapView?
    private let segmentIndex: Int
    private let mappingMode: KhonsViewModel.WaypointMappingMode

    init(
        polyline: RouteSegmentPolyline,
        mapView: MKMapView,
        segmentIndex: Int,
        mappingMode: KhonsViewModel.WaypointMappingMode
    ) {
        self.mapView = mapView as? ClickSelectableMapView
        self.segmentIndex = segmentIndex
        self.mappingMode = mappingMode
        super.init(polyline: polyline)
    }

    override func applyStrokeProperties(to context: CGContext, atZoomScale zoomScale: MKZoomScale) {
        let isHovered = mapView?.hoveredRouteSegmentIndex == segmentIndex
        switch mappingMode {
        case .simple:
            strokeColor = isHovered ? .systemTeal : .systemTeal.withAlphaComponent(0.55)
            lineWidth = isHovered ? 4 : 2
            lineDashPattern = [5, 4]
            alpha = isHovered ? 1.0 : 0.85
        case .advancedWalk:
            strokeColor = isHovered ? .systemGreen : .systemGreen.withAlphaComponent(0.55)
            lineWidth = isHovered ? 6 : 3.5
            lineDashPattern = nil
            alpha = isHovered ? 1.0 : 0.8
        case .advancedDrive:
            strokeColor = isHovered ? .systemOrange : .systemOrange.withAlphaComponent(0.55)
            lineWidth = isHovered ? 6 : 3.5
            lineDashPattern = nil
            alpha = isHovered ? 1.0 : 0.8
        case .advancedCombined:
            strokeColor = isHovered ? .systemPurple : .systemPurple.withAlphaComponent(0.55)
            lineWidth = isHovered ? 6 : 4
            lineDashPattern = [8, 3]
            alpha = isHovered ? 1.0 : 0.85
        }
        super.applyStrokeProperties(to: context, atZoomScale: zoomScale)
    }
}

private enum RouteAnnotationKind {
    case target
    case travel(Int)
    case simulated
}

private final class RoutePinAnnotation: NSObject, MKAnnotation {
    let kind: RouteAnnotationKind
    let titleText: String
    dynamic var coordinate: CLLocationCoordinate2D

    init(kind: RouteAnnotationKind, title: String, coordinate: CLLocationCoordinate2D) {
        self.kind = kind
        self.titleText = title
        self.coordinate = coordinate
    }

    var title: String? { titleText }
}

private final class ClickSelectableMapView: MKMapView {
    var onCoordinateSelected: ((CLLocationCoordinate2D) -> Void)?
    var onTravelCoordinateUpdated: ((Int?, CLLocationCoordinate2D) -> Void)?
    var targetCoordinate = CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090)
    var travelCoordinates: [CLLocationCoordinate2D] = []
    var routePreviewCoordinates: [CLLocationCoordinate2D] = []
    var routePreviewSegments: [KhonsViewModel.RoutePreviewSegment] = []
    var selectedWaypointMapping: KhonsViewModel.WaypointMappingMode = .simple
    var hoveredRouteSegmentIndex: Int? {
        didSet {
            guard oldValue != hoveredRouteSegmentIndex else { return }
            refreshRouteOverlayRendering()
        }
    }
    private var mouseDownLocation: NSPoint?
    private var mouseDownTimestamp: TimeInterval?
    private var placementWorkItem: DispatchWorkItem?
    private var didCommitPlacement = false
    private var hoverTrackingArea: NSTrackingArea?
    private let clickTolerance: CGFloat = 4
    private let holdDurationThreshold: TimeInterval = 0.35

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func mouseExited(with event: NSEvent) {
        hoveredRouteSegmentIndex = nil
        super.mouseExited(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHoveredRouteSegment(for: convert(event.locationInWindow, from: nil))
        super.mouseMoved(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = convert(event.locationInWindow, from: nil)
        mouseDownTimestamp = event.timestamp
        didCommitPlacement = false
        placementWorkItem?.cancel()

        let anchorLocation = mouseDownLocation
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.didCommitPlacement, let anchorLocation else {
                return
            }
            guard self.isPlacementStillValid(for: anchorLocation) else {
                return
            }
            self.didCommitPlacement = true
            let coordinate = self.convert(anchorLocation, toCoordinateFrom: self)
            self.onCoordinateSelected?(coordinate)
        }
        placementWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + holdDurationThreshold, execute: workItem)
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        placementWorkItem?.cancel()
        placementWorkItem = nil
        mouseDownLocation = nil
        mouseDownTimestamp = nil

        super.mouseUp(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mouseDownLocation else {
            super.mouseDragged(with: event)
            return
        }

        let dragLocation = convert(event.locationInWindow, from: nil)
        if hypot(dragLocation.x - mouseDownLocation.x, dragLocation.y - mouseDownLocation.y) > clickTolerance {
            placementWorkItem?.cancel()
            placementWorkItem = nil
        }

        super.mouseDragged(with: event)
    }

    func cancelPendingPlacement() {
        placementWorkItem?.cancel()
        placementWorkItem = nil
        didCommitPlacement = false
    }

    private func updateHoveredRouteSegment(for point: NSPoint) {
        guard !routePreviewSegments.isEmpty else {
            hoveredRouteSegmentIndex = nil
            return
        }

        var bestIndex: Int?
        var bestDistance = CGFloat.greatestFiniteMagnitude

        for segment in routePreviewSegments {
            let distance = distanceToSegment(routePreviewCoordinates: segment.coordinates, from: point)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = segment.index
            }
        }

        hoveredRouteSegmentIndex = bestDistance <= 10 ? bestIndex : nil
    }

    private func distanceToSegment(routePreviewCoordinates: [CLLocationCoordinate2D], from point: NSPoint) -> CGFloat {
        guard routePreviewCoordinates.count > 1 else {
            return .greatestFiniteMagnitude
        }

        var best = CGFloat.greatestFiniteMagnitude
        for index in 0..<(routePreviewCoordinates.count - 1) {
            let start = convert(routePreviewCoordinates[index], toPointTo: self)
            let end = convert(routePreviewCoordinates[index + 1], toPointTo: self)
            let distance = distanceFromPoint(point, toSegmentStart: start, end: end)
            if distance < best {
                best = distance
            }
        }
        return best
    }

    private func distanceFromPoint(_ point: NSPoint, toSegmentStart start: NSPoint, end: NSPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else {
            return hypot(point.x - start.x, point.y - start.y)
        }

        let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        let projection = NSPoint(x: start.x + t * dx, y: start.y + t * dy)
        return hypot(point.x - projection.x, point.y - projection.y)
    }

    private func refreshRouteOverlayRendering() {
        for overlay in overlays {
            if let renderer = renderer(for: overlay) as? MKPolylineRenderer {
                renderer.setNeedsDisplay()
            }
        }
    }

    private func isPlacementStillValid(for anchorLocation: NSPoint) -> Bool {
        guard let mouseDownLocation else {
            return false
        }
        return hypot(anchorLocation.x - mouseDownLocation.x, anchorLocation.y - mouseDownLocation.y) <= clickTolerance
    }
}

private final class RouteAnchorMarkerAnnotationView: MKMarkerAnnotationView {
    private var dragHandler: ((NSPoint) -> Void)?
    private var isDraggingAnchor = false

    func configure(tintColor: NSColor, dragHandler: @escaping (NSPoint) -> Void) {
        canShowCallout = false
        markerTintColor = tintColor
        glyphImage = nil
        self.dragHandler = dragHandler
    }

    override func mouseDown(with event: NSEvent) {
        isDraggingAnchor = true
        (superview as? ClickSelectableMapView)?.cancelPendingPlacement()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDraggingAnchor, let mapView = superview as? MKMapView else {
            return
        }
        let point = mapView.convert(event.locationInWindow, from: nil)
        dragHandler?(point)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDraggingAnchor, let mapView = superview as? MKMapView else {
            isDraggingAnchor = false
            return
        }
        let point = mapView.convert(event.locationInWindow, from: nil)
        dragHandler?(point)
        isDraggingAnchor = false
    }
}

private final class RouteAnchorDotAnnotationView: MKAnnotationView {
    private var dragHandler: ((NSPoint) -> Void)?
    private var isDraggingAnchor = false

    func configure(image: NSImage, dragHandler: @escaping (NSPoint) -> Void) {
        canShowCallout = false
        self.image = image
        centerOffset = NSPoint(x: 0, y: -6)
        self.dragHandler = dragHandler
    }

    override func mouseDown(with event: NSEvent) {
        isDraggingAnchor = true
        (superview as? ClickSelectableMapView)?.cancelPendingPlacement()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDraggingAnchor, let mapView = superview as? MKMapView else {
            return
        }
        let point = mapView.convert(event.locationInWindow, from: nil)
        dragHandler?(point)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDraggingAnchor, let mapView = superview as? MKMapView else {
            isDraggingAnchor = false
            return
        }
        let point = mapView.convert(event.locationInWindow, from: nil)
        dragHandler?(point)
        isDraggingAnchor = false
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
