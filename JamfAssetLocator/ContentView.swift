//
//  ContentView.swift
//  JamfAssetLocator
//
//  Created by Gabriel Marcelino on 8/14/25.
//

import SwiftUI

struct ContentView: View {
    @State private var office: String = ""          // Building ("" means no selection)
    @State private var otherOffice: String = ""     // Free-form when “Other…” is chosen
    @State private var department: String = ""
    @State private var otherDepartment: String = ""
    @State private var room: String = ""
    @State private var contact: String = ""         // Real Name
    @State private var email: String = ""
    @State private var status: String = ""
    @State private var showStatus: Bool = false

    // Classic-only string lists (fallback)
    @State private var buildings: [String] = []
    @State private var departmentsList: [String] = []
    @State private var isLoadingBuildings: Bool = false
    @State private var isLoadingDepartments: Bool = false

    // Modern lists with IDs (preferred when OAuth is configured)
    @State private var modernBuildings: [JamfAPI.Building] = []
    @State private var modernDepartments: [JamfAPI.Department] = []
    @State private var nameToBuildingID: [String: String] = [:]
    @State private var nameToDepartmentID: [String: String] = [:]

    private let config = ManagedConfig()

    // Special marker for “Other…” option in pickers
    private let otherMarker = "— Other —"

    // Detect OAuth availability from config (JamfAPI.hasOAuth is private)
    private var oauthAvailable: Bool {
        (config.jamfClientID?.nilIfEmpty != nil) && (config.jamfClientSecret?.nilIfEmpty != nil)
    }

    var body: some View {
        Group {
            if #available(iOS 16.0, *) {
                NavigationStack {
                    ZStack {
                        content
                        floatingSubmitButton
                    }
                    .navigationTitle("Asset Locator")
                    .navigationBarTitleDisplayMode(.large)
                    .toolbar { toolbarContent }
                }
            } else {
                NavigationView {
                    ZStack {
                        content
                        floatingSubmitButton
                    }
                    .navigationBarTitle("Asset Locator", displayMode: .large)
                    .toolbar { toolbarContent }
                }
                .navigationViewStyle(.stack)
            }
        }
        .onAppear {
            if contact.isEmpty, let user = config.jamfUsername { contact = user }
            Task { await refreshLists() }
        }
        .statusOverlay(text: status, isPresented: $showStatus)
        .background(
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(uiColor: .secondarySystemBackground),
                    Color(uiColor: .systemBackground)
                ]),
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Button {
                Task { await diagnose() }
            } label: {
                Label("Diagnose", systemImage: "stethoscope")
            }
            .buttonStyle(.bordered)
        }

        ToolbarItem(placement: .navigationBarLeading) {
            Button {
                Task { await refreshLists() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(isLoadingBuildings || isLoadingDepartments)
        }
    }

    // Floating liquid-glass submit button (bottom-right)
    private var floatingSubmitButton: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    Task { await submit() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "paperplane.fill")
                            .symbolRenderingMode(.hierarchical)
                        Text("Submit")
                            .font(.headline)
                            .minimumScaleFactor(0.8)
                            .lineLimit(1)
                            .opacity(0.95)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule(style: .continuous))
                    .shadow(color: Color.black.opacity(0.15), radius: 16, x: 0, y: 8)
                }
                .buttonStyle(.plain)
                .disabled(isLoadingBuildings || isLoadingDepartments)
                .padding(.trailing, 24)
                .padding(.bottom, 24)
                .accessibilityLabel("Submit")
                .accessibilityHint("Send updates to Jamf")
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 20) {
                    if config.uiShowBuilding {
                        SectionHeader(title: config.uiBuildingLabel, systemImage: "building.2")
                        if !effectiveBuildings.isEmpty {
                            MenuPicker(title: "", selection: $office, options: effectiveBuildings, includeOther: config.uiAllowOtherBuilding, otherMarker: otherMarker)
                            if config.uiAllowOtherBuilding && office == otherMarker {
                                ModernTextField(placeholder: "Type another \(config.uiBuildingLabel.lowercased())", text: $otherOffice, contentType: .none, capitalization: .words)
                            }
                        } else {
                            ModernTextField(placeholder: config.uiBuildingLabel, text: $office, contentType: .none, capitalization: .words)
                        }
                    }

                    if config.uiShowDepartment {
                        SectionHeader(title: config.uiDepartmentLabel, systemImage: "person.3")
                        if !effectiveDepartments.isEmpty {
                            MenuPicker(title: "", selection: $department, options: effectiveDepartments.sorted(), includeOther: config.uiAllowOtherDepartment, otherMarker: otherMarker)
                            if config.uiAllowOtherDepartment && department == otherMarker {
                                ModernTextField(placeholder: "Type another \(config.uiDepartmentLabel.lowercased())", text: $otherDepartment, contentType: .none, capitalization: .words)
                            }
                        } else {
                            ModernTextField(placeholder: config.uiDepartmentLabel, text: $department, contentType: .none, capitalization: .words)
                        }
                    }

                    if config.uiShowRoom {
                        SectionHeader(title: config.uiRoomLabel, systemImage: "number")
                        ModernTextField(placeholder: config.uiRoomLabel, text: $room, contentType: .none, capitalization: .words)
                    }

                    if config.uiShowContact {
                        SectionHeader(title: config.uiContactLabel, systemImage: "person.crop.circle")
                        ModernTextField(placeholder: "Full Name", text: $contact, contentType: .name, capitalization: .words)
                    }

                    if config.uiShowEmail {
                        SectionHeader(title: config.uiEmailLabel, systemImage: "envelope")
                        ModernTextField(placeholder: "name@example.com", text: $email, contentType: .emailAddress, capitalization: .never, keyboard: .emailAddress, autocorrection: false)
                    }
                }
                .padding(24)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: Color.black.opacity(0.08), radius: 20, x: 0, y: 8)
                .frame(maxWidth: 700)
                .overlay(alignment: .topTrailing) {
                    if isLoadingBuildings || isLoadingDepartments {
                        ProgressView()
                            .padding(16)
                    }
                }

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
        }
    }

    // Effective names for UI pickers
    private var effectiveBuildings: [String] {
        if oauthAvailable {
            let names = modernBuildings.map { $0.name }
            return Array(Set(names)).sorted()
        } else {
            var source: [String] = []
            if !buildings.isEmpty {
                source = buildings
            } else if config.uiUseManagedOfficesAsBuildings, !config.officeOptions.isEmpty {
                source = config.officeOptions
            }
            return Array(Set(source)).sorted()
        }
    }

    private var effectiveDepartments: [String] {
        if oauthAvailable {
            let names = modernDepartments.map { $0.name }
            return Array(Set(names)).sorted()
        } else {
            return Array(Set(departmentsList)).sorted()
        }
    }

    // MARK: - Loading lists

    private func refreshLists() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await loadBuildings() }
            group.addTask { await loadDepartments() }
        }
    }

    private func loadBuildings() async {
        guard var api = JamfAPI(config: config) else {
            await show("Invalid Jamf config")
            return
        }
        await MainActor.run { isLoadingBuildings = true }
        defer { Task { await MainActor.run { isLoadingBuildings = false } } }

        do {
            if oauthAvailable {
                let list = try await api.getBuildingsModern()
                let names = list.map { $0.name }
                let dict = Dictionary(uniqueKeysWithValues: list.map { ($0.name, $0.id) })
                await MainActor.run {
                    self.modernBuildings = list
                    self.nameToBuildingID = dict
                    self.buildings = names
                }
            } else {
                let names = try await api.getBuildings()
                await MainActor.run {
                    self.buildings = names
                    self.modernBuildings = []
                    self.nameToBuildingID = [:]
                }
            }
        } catch let err as JamfAPIError {
            await show("Could not load Buildings from Jamf: \(err.description)")
        } catch {
            await show("Could not load Buildings from Jamf: \(error.localizedDescription)")
        }
    }

    private func loadDepartments() async {
        guard var api = JamfAPI(config: config) else {
            await show("Invalid Jamf config")
            return
        }
        await MainActor.run { isLoadingDepartments = true }
        defer { Task { await MainActor.run { isLoadingDepartments = false } } }

        do {
            if oauthAvailable {
                let list = try await api.getDepartmentsModern()
                let names = list.map { $0.name }
                let dict = Dictionary(uniqueKeysWithValues: list.map { ($0.name, $0.id) })
                await MainActor.run {
                    self.modernDepartments = list
                    self.nameToDepartmentID = dict
                    self.departmentsList = names
                }
            } else {
                let names = try await api.getDepartments()
                await MainActor.run {
                    self.departmentsList = names
                    self.modernDepartments = []
                    self.nameToDepartmentID = [:]
                }
            }
        } catch let err as JamfAPIError {
            await show("Could not load Departments from Jamf: \(err.description)")
        } catch {
            await show("Could not load Departments from Jamf: \(error.localizedDescription)")
        }
    }

    // MARK: - Submit

    private func submit() async {
        await show("Validating...")
        guard let deviceID = config.jamfDeviceID else { await show("Missing JAMF_DEVICE_ID"); return }
        guard var api = JamfAPI(config: config) else { await show("Invalid Jamf config"); return }

        let buildingValue: String? = {
            if office == otherMarker {
                return otherOffice.nilIfEmpty
            } else {
                return office.nilIfEmpty
            }
        }()

        let departmentValue: String? = {
            if department == otherMarker {
                return otherDepartment.nilIfEmpty
            } else {
                return department.nilIfEmpty
            }
        }()

        if let buildingName = buildingValue, office != otherMarker {
            let validation = await api.validateBuilding(buildingName)
            if case .failure(let error) = validation {
                await show("Cannot submit: \(error.description)")
                return
            }
        }

        if let deptName = departmentValue, department != otherMarker {
            let validation = await api.validateDepartment(deptName)
            if case .failure(let error) = validation {
                await show("Cannot submit: \(error.description)")
                return
            }
        }

        await MainActor.run {
            if office == otherMarker, let value = otherOffice.nilIfEmpty {
                buildings.append(value)
                buildings = Array(Set(buildings)).sorted()
                office = value
                otherOffice = ""
            }
            if department == otherMarker, let value = otherDepartment.nilIfEmpty {
                departmentsList.append(value)
                departmentsList = Array(Set(departmentsList)).sorted()
                department = value
                otherDepartment = ""
            }
        }

        let derivedUsername: String? = {
            guard let e = email.nilIfEmpty else { return nil }
            if let at = e.firstIndex(of: "@"), at > e.startIndex {
                return String(e[..<at])
            }
            return nil
        }()

        await show("Submitting...")

        if oauthAvailable {
            do {
                let buildingId: String? = {
                    guard let name = buildingValue, !name.isEmpty, office != otherMarker else { return nil }
                    return nameToBuildingID[name]
                }()
                let departmentId: String? = {
                    guard let name = departmentValue, !name.isEmpty, department != otherMarker else { return nil }
                    return nameToDepartmentID[name]
                }()

                let loc = JamfAPI.MobileDevicePatch.Location(
                    username: derivedUsername,
                    realName: contact.nilIfEmpty,
                    emailAddress: email.nilIfEmpty,
                    position: nil,
                    phoneNumber: nil,
                    departmentId: departmentId,
                    buildingId: buildingId,
                    room: room.nilIfEmpty
                )
                let patch = JamfAPI.MobileDevicePatch(
                    name: nil,
                    enforceName: nil,
                    assetTag: nil,
                    siteId: nil,
                    timeZone: nil,
                    location: loc
                )

                try await api.patchMobileDeviceModern(id: deviceID, payload: patch)
                await show("✓ Updated in Jamf (modern)", success: true)
                return
            } catch let err as JamfAPIError {
                await show("Update failed (modern): \(err.description)")
                return
            } catch {
                await show("Update failed (modern): \(error.localizedDescription)")
                return
            }
        }

        // Fallback: Classic
        do {
            try await api.updateLocation(deviceID: deviceID,
                                         username: derivedUsername,
                                         realName: contact.nilIfEmpty,
                                         email: email.nilIfEmpty,
                                         building: buildingValue,
                                         department: departmentValue,
                                         room: room.nilIfEmpty)
            await show("✓ Updated in Jamf (classic)", success: true)
        } catch let err as JamfAPIError {
            await show("Update failed (classic): \(err.description)")
        } catch {
            await show("Update failed (classic): \(error.localizedDescription)")
        }
    }

    // MARK: - Diagnose

    private func diagnose() async {
        await show("Diagnosing...")
        guard let deviceID = config.jamfDeviceID else { await show("Missing JAMF_DEVICE_ID"); return }
        guard var api = JamfAPI(config: config) else { await show("Invalid Jamf config"); return }

        do {
            if oauthAvailable {
                let preview = try await api.diagnoseModernAccess(deviceID: deviceID)
                let trimmed = preview.count > 800 ? String(preview.prefix(800)) + "…" : preview
                await show("Diagnose success (modern):\n\(trimmed)", success: true)
            } else {
                let preview = try await api.diagnoseClassicAccess(deviceID: deviceID)
                let trimmed = preview.count > 800 ? String(preview.prefix(800)) + "…" : preview
                await show("Diagnose success (classic):\n\(trimmed)", success: true)
            }
        } catch let err as JamfAPIError {
            await show("Diagnose failed: \(err.description)")
        } catch {
            await show("Diagnose failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func show(_ text: String, success: Bool = false) async {
        await MainActor.run {
            status = text
            withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                showStatus = true
            }
            #if os(iOS)
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(success ? .success : .warning)
            #endif
        }
        if !text.lowercased().hasPrefix("diagnose success") {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                withAnimation(.easeInOut) { showStatus = false }
            }
        }
    }
}

// MARK: - UI Components

private struct SectionHeader: View {
    let title: String
    let systemImage: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .accessibilityAddTraits(.isHeader)
    }
}

private struct MenuPicker: View {
    let title: String
    @Binding var selection: String
    let options: [String]
    let includeOther: Bool
    let otherMarker: String

    var body: some View {
        Picker(title, selection: $selection) {
            Text("— None —").tag("")
            ForEach(options, id: \.self) { Text($0).tag($0) }
            if includeOther {
                Text(otherMarker).tag(otherMarker)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct ModernTextField: View {
    let placeholder: String
    @Binding var text: String
    var contentType: UITextContentType?
    var capitalization: TextInputAutocapitalization = .never
    var keyboard: UIKeyboardType = .default
    var autocorrection: Bool = true

    init(placeholder: String,
         text: Binding<String>,
         contentType: UITextContentType?,
         capitalization: TextInputAutocapitalization = .never,
         keyboard: UIKeyboardType = .default,
         autocorrection: Bool = true) {
        self.placeholder = placeholder
        self._text = text
        self.contentType = contentType
        self.capitalization = capitalization
        self.keyboard = keyboard
        self.autocorrection = autocorrection
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .textInputAutocapitalization(capitalization)
            .keyboardType(keyboard)
            .autocorrectionDisabled(!autocorrection)
            .textContentType(contentType.map { .init($0) } ?? nil)
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Status Overlay (Liquid glass toast)

private struct StatusOverlayModifier: ViewModifier {
    let text: String
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if isPresented && !text.isEmpty {
                    Text(text)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule(style: .continuous))
                        .shadow(color: Color.black.opacity(0.1), radius: 10, x: 0, y: 6)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
    }
}

private extension View {
    func statusOverlay(text: String, isPresented: Binding<Bool>) -> some View {
        self.modifier(StatusOverlayModifier(text: text, isPresented: isPresented))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
