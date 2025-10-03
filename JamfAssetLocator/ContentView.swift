//
//  ContentView.swift
//  JamfAssetLocator
//
//  Created by Gabriel Marcelino on 8/14/25.
//

import SwiftUI

struct ContentView: View {
    @State private var office: String = ""          // Building ("" = none)
    @State private var otherOffice: String = ""
    @State private var department: String = ""
    @State private var otherDepartment: String = ""
    @State private var room: String = ""
    @State private var contact: String = ""         // Real Name
    @State private var email: String = ""
    @State private var assetTag: String = ""        // NEW: Asset Tag
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

    // Pending IDs to resolve after lists load (modern)
    @State private var pendingBuildingId: String?
    @State private var pendingDepartmentId: String?

    private let config = ManagedConfig()

    private let otherMarker = "— Other —"

    private var oauthAvailable: Bool {
        (config.jamfClientID?.nilIfEmpty != nil) && (config.jamfClientSecret?.nilIfEmpty != nil)
    }

    // Searchable picker sheets
    @State private var showBuildingPicker = false
    @State private var showDepartmentPicker = false

    // Validation flow
    @State private var attemptedSubmit = false

    // MARK: - Missing field flags (computed after a submit attempt)

    private var buildingMissing: Bool {
        guard attemptedSubmit, config.uiRequireBuilding else { return false }
        if office == otherMarker {
            return otherOffice.nilIfEmpty == nil
        } else {
            return office.nilIfEmpty == nil
        }
    }

    private var buildingPickerMissingSelection: Bool {
        guard attemptedSubmit, config.uiRequireBuilding else { return false }
        // Missing selection (no value chosen at all)
        return office.nilIfEmpty == nil
    }

    private var departmentMissing: Bool {
        guard attemptedSubmit, config.uiRequireDepartment else { return false }
        if department == otherMarker {
            return otherDepartment.nilIfEmpty == nil
        } else {
            return department.nilIfEmpty == nil
        }
    }

    private var departmentPickerMissingSelection: Bool {
        guard attemptedSubmit, config.uiRequireDepartment else { return false }
        return department.nilIfEmpty == nil
    }

    private var emailMissing: Bool {
        attemptedSubmit && config.uiRequireEmail && email.nilIfEmpty == nil
    }

    private var contactMissing: Bool {
        attemptedSubmit && config.uiRequireContact && contact.nilIfEmpty == nil
    }

    private var assetTagMissing: Bool {
        attemptedSubmit && config.uiRequireAssetTag && assetTag.nilIfEmpty == nil
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
            Task {
                // Load lists and current location in parallel for faster prefill
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await refreshLists() }
                    group.addTask { await loadExistingLocation() }
                }
            }
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
        .sheet(isPresented: $showBuildingPicker) {
            SearchablePicker(
                title: config.uiBuildingLabel,
                selection: $office,
                options: effectiveBuildings,
                includeOther: config.uiAllowOtherBuilding,
                otherMarker: otherMarker
            )
        }
        .sheet(isPresented: $showDepartmentPicker) {
            SearchablePicker(
                title: config.uiDepartmentLabel,
                selection: $department,
                options: effectiveDepartments.sorted(),
                includeOther: config.uiAllowOtherDepartment,
                otherMarker: otherMarker
            )
        }
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
                Task {
                    // Refresh both the lists and the current device snapshot
                    await withTaskGroup(of: Void.self) { group in
                        group.addTask { await refreshLists() }
                        group.addTask { await loadExistingLocation() }
                    }
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(isLoadingBuildings || isLoadingDepartments)
        }
    }

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
                    // Building
                    if config.uiShowBuilding {
                        SectionHeader(
                            title: config.uiBuildingLabel + (config.uiRequireBuilding ? " *" : ""),
                            systemImage: "building.2",
                            isError: buildingMissing
                        )
                        if !effectiveBuildings.isEmpty {
                            PickerLauncherButton(
                                label: office.nilIfEmpty ?? "Select \(config.uiBuildingLabel)",
                                systemImage: "building.2",
                                isError: buildingPickerMissingSelection,
                                action: { showBuildingPicker = true }
                            )
                            if config.uiAllowOtherBuilding && office == otherMarker {
                                ModernTextField(
                                    placeholder: "Type another \(config.uiBuildingLabel.lowercased())",
                                    text: $otherOffice,
                                    contentType: .none,
                                    capitalization: .words
                                )
                                .errorHighlight(buildingMissing)
                            }
                        } else {
                            ModernTextField(
                                placeholder: config.uiBuildingLabel,
                                text: $office,
                                contentType: .none,
                                capitalization: .words
                            )
                            .errorHighlight(buildingMissing)
                        }
                    }

                    // Department
                    if config.uiShowDepartment {
                        SectionHeader(
                            title: config.uiDepartmentLabel + (config.uiRequireDepartment ? " *" : ""),
                            systemImage: "person.3",
                            isError: departmentMissing
                        )
                        if !effectiveDepartments.isEmpty {
                            PickerLauncherButton(
                                label: department.nilIfEmpty ?? "Select \(config.uiDepartmentLabel)",
                                systemImage: "person.3",
                                isError: departmentPickerMissingSelection,
                                action: { showDepartmentPicker = true }
                            )
                            if config.uiAllowOtherDepartment && department == otherMarker {
                                ModernTextField(
                                    placeholder: "Type another \(config.uiDepartmentLabel.lowercased())",
                                    text: $otherDepartment,
                                    contentType: .none,
                                    capitalization: .words
                                )
                                .errorHighlight(departmentMissing)
                            }
                        } else {
                            ModernTextField(
                                placeholder: config.uiDepartmentLabel,
                                text: $department,
                                contentType: .none,
                                capitalization: .words
                            )
                            .errorHighlight(departmentMissing)
                        }
                    }

                    // Room
                    if config.uiShowRoom {
                        SectionHeader(title: config.uiRoomLabel, systemImage: "number")
                        ModernTextField(
                            placeholder: config.uiRoomLabel,
                            text: $room,
                            contentType: .none,
                            capitalization: .words
                        )
                    }

                    // Contact
                    if config.uiShowContact {
                        SectionHeader(
                            title: config.uiContactLabel + (config.uiRequireContact ? " *" : ""),
                            systemImage: "person.crop.circle",
                            isError: contactMissing
                        )
                        ModernTextField(
                            placeholder: "Full Name",
                            text: $contact,
                            contentType: .name,
                            capitalization: .words
                        )
                        .errorHighlight(contactMissing)
                    }

                    // Email
                    if config.uiShowEmail {
                        SectionHeader(
                            title: config.uiEmailLabel + (config.uiRequireEmail ? " *" : ""),
                            systemImage: "envelope",
                            isError: emailMissing
                        )
                        ModernTextField(
                            placeholder: "name@example.com",
                            text: $email,
                            contentType: .emailAddress,
                            capitalization: .never,
                            keyboard: .emailAddress,
                            autocorrection: false
                        )
                        .errorHighlight(emailMissing)
                    }

                    // Asset Tag
                    if config.uiShowAssetTag {
                        SectionHeader(
                            title: config.uiAssetTagLabel + (config.uiRequireAssetTag ? " *" : ""),
                            systemImage: "tag",
                            isError: assetTagMissing
                        )
                        ModernTextField(
                            placeholder: config.uiAssetTagLabel,
                            text: $assetTag,
                            contentType: .none,
                            capitalization: .never
                        )
                        .errorHighlight(assetTagMissing)
                    }
                }
                .padding(24)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: Color.black.opacity(0.08), radius: 20, x: 0, y: 8)
                .frame(maxWidth: 700)
                .overlay(alignment: .topTrailing) {
                    if isLoadingBuildings || isLoadingDepartments {
                        ProgressView().padding(16)
                    }
                }

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
        }
    }

    // MARK: - Effective lists

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
                    resolvePendingBuildingIfNeeded()
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
                    resolvePendingDepartmentIfNeeded()
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

    // MARK: - Prefill

    private func loadExistingLocation() async {
        guard let deviceID = config.jamfDeviceID else { await show("Missing JAMF_DEVICE_ID"); return }
        guard var api = JamfAPI(config: config) else { await show("Invalid Jamf config"); return }

        do {
            if oauthAvailable {
                let snap = try await api.fetchCurrentLocationModern(id: deviceID)
                await MainActor.run {
                    // Prefill text fields
                    if let rn = snap.realName, !rn.isEmpty { self.contact = rn }
                    if let em = snap.email, !em.isEmpty { self.email = em }
                    if let rm = snap.room, !rm.isEmpty { self.room = rm }
                    if let at = snap.assetTag, !at.isEmpty { self.assetTag = at }
                    // Hold IDs; names will be resolved once lists are ready
                    self.pendingBuildingId = snap.buildingId
                    self.pendingDepartmentId = snap.departmentId
                    // Try immediate resolution if lists already loaded
                    resolvePendingBuildingIfNeeded()
                    resolvePendingDepartmentIfNeeded()
                }
            } else {
                let snap = try await api.fetchCurrentLocationClassic(id: deviceID)
                await MainActor.run {
                    if let rn = snap.realName, !rn.isEmpty { self.contact = rn }
                    if let em = snap.email, !em.isEmpty { self.email = em }
                    if let rm = snap.room, !rm.isEmpty { self.room = rm }
                    if let at = snap.assetTag, !at.isEmpty { self.assetTag = at }
                    if let b = snap.buildingName, !b.isEmpty { self.office = b }
                    if let d = snap.departmentName, !d.isEmpty { self.department = d }
                }
            }
        } catch let err as JamfAPIError {
            await show("Prefill failed: \(err.description)")
        } catch {
            await show("Prefill failed: \(error.localizedDescription)")
        }
    }

    private func resolvePendingBuildingIfNeeded() {
        guard oauthAvailable, let id = pendingBuildingId, !id.isEmpty else { return }
        if let name = modernBuildings.first(where: { $0.id == id })?.name {
            self.office = name
            self.pendingBuildingId = nil
        }
    }

    private func resolvePendingDepartmentIfNeeded() {
        guard oauthAvailable, let id = pendingDepartmentId, !id.isEmpty else { return }
        if let name = modernDepartments.first(where: { $0.id == id })?.name {
            self.department = name
            self.pendingDepartmentId = nil
        }
    }

    // MARK: - Submit

    private func submit() async {
        await MainActor.run { attemptedSubmit = true }
        await show("Validating...")
        guard let deviceID = config.jamfDeviceID else { await show("Missing JAMF_DEVICE_ID"); return }
        guard var api = JamfAPI(config: config) else { await show("Invalid Jamf config"); return }

        let buildingValue: String? = {
            if office == otherMarker { return otherOffice.nilIfEmpty }
            return office.nilIfEmpty
        }()

        let departmentValue: String? = {
            if department == otherMarker { return otherDepartment.nilIfEmpty }
            return department.nilIfEmpty
        }()

        // Validation for required fields
        if config.uiRequireBuilding {
            if (office == otherMarker && otherOffice.nilIfEmpty == nil) ||
               (office.nilIfEmpty == nil && !(config.uiAllowOtherBuilding && office == otherMarker)) {
                await show("\(config.uiBuildingLabel) is required.")
                return
            }
        }

        if config.uiRequireDepartment {
            if (department == otherMarker && otherDepartment.nilIfEmpty == nil) ||
                (department.nilIfEmpty == nil && !(config.uiAllowOtherDepartment && department == otherMarker)) {
                await show("\(config.uiDepartmentLabel) is required.")
                return
            }
        }

        if config.uiRequireEmail {
            if email.nilIfEmpty == nil {
                await show("\(config.uiEmailLabel) is required.")
                return
            }
        }

        if config.uiRequireContact {
            if contact.nilIfEmpty == nil {
                await show("\(config.uiContactLabel) is required.")
                return
            }
        }

        if config.uiRequireAssetTag {
            if assetTag.nilIfEmpty == nil {
                await show("\(config.uiAssetTagLabel) is required.")
                return
            }
        }

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

                // NEW: include EA stamp via modern PATCH if configured
                var eaArray: [JamfAPI.MobileDevicePatch.UpdatedExtensionAttribute]? = nil
                if let eaName = config.jamfEAName?.nilIfEmpty, config.jamfEAOnSubmit {
                    let stamp = eaTimestampString()
                    eaArray = [
                        .init(
                            name: eaName,
                            type: config.jamfEAType,
                            value: [stamp],
                            extensionAttributeCollectionAllowed: config.jamfEACollectionAllowed
                        )
                    ]
                }

                let patch = JamfAPI.MobileDevicePatch(
                    name: nil,
                    enforceName: nil,
                    assetTag: assetTag.nilIfEmpty,
                    siteId: nil,
                    timeZone: nil,
                    location: loc,
                    updatedExtensionAttributes: eaArray
                )

                var api2 = api
                try await api2.patchMobileDeviceModern(id: deviceID, payload: patch)
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

        do {
            var api2 = api
            try await api2.updateLocation(deviceID: deviceID,
                                          username: derivedUsername,
                                          realName: contact.nilIfEmpty,
                                          email: email.nilIfEmpty,
                                          building: buildingValue,
                                          department: departmentValue,
                                          room: room.nilIfEmpty,
                                          assetTag: assetTag.nilIfEmpty)
            await show("✓ Updated in Jamf (classic)", success: true)
        } catch let err as JamfAPIError {
            await show("Update failed (classic): \(err.description)")
        } catch {
            await show("Update failed (classic): \(error.localizedDescription)")
        }
    }

    // MARK: - EA timestamp formatting

    private func eaTimestampString() -> String {
        if let fmt = config.jamfEADateFormat?.nilIfEmpty {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(secondsFromGMT: 0) // UTC for predictability
            df.dateFormat = fmt
            return df.string(from: Date())
        } else {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            iso.timeZone = TimeZone(secondsFromGMT: 0)
            return iso.string(from: Date())
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

    // MARK: - UI Components

    private struct SectionHeader: View {
        let title: String
        let systemImage: String
        var isError: Bool = false
        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(isError ? .red : .secondary)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(isError ? .red : .secondary)
                Spacer()
            }
            .accessibilityAddTraits(.isHeader)
        }
    }

    private struct PickerLauncherButton: View {
        let label: String
        let systemImage: String
        var isError: Bool = false
        var action: () -> Void

        var body: some View {
            Button(action: action) {
                HStack {
                    Image(systemName: systemImage)
                        .foregroundStyle(isError ? .red : .secondary)
                    Text(label)
                        .foregroundStyle(isError ? .red : (label.isEmpty ? .secondary : .primary))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .foregroundStyle(isError ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
                }
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(isError ? Color.red : Color.clear, lineWidth: 1.5)
                )
                .shadow(color: isError ? Color.red.opacity(0.15) : Color.clear, radius: 6)
            }
            .buttonStyle(.plain)
        }
    }

    private struct SearchablePicker: View {
        let title: String
        @Binding var selection: String
        let options: [String]
        let includeOther: Bool
        let otherMarker: String

        @Environment(\.dismiss) private var dismiss
        @State private var query: String = ""

        private var filtered: [String] {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return options }
            return options.filter { $0.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }

        var body: some View {
            NavigationView {
                List {
                    Button {
                        selection = ""
                        dismiss()
                    } label: {
                        HStack {
                            Text("— None —").fontWeight(selection.isEmpty ? .semibold : .regular)
                            if selection.isEmpty { Spacer(); Image(systemName: "checkmark") }
                        }
                    }

                    Section {
                        ForEach(filtered, id: \.self) { name in
                            Button {
                                selection = name
                                dismiss()
                            } label: {
                                HStack {
                                    Text(name).fontWeight(selection == name ? .semibold : .regular)
                                    if selection == name { Spacer(); Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }

                    if includeOther {
                        Section {
                            Button {
                                selection = otherMarker
                                dismiss()
                            } label: {
                                HStack {
                                    Text(otherMarker)
                                    if selection == otherMarker { Spacer(); Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }
                }
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search \(title)")
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
    }
}

private extension View {
    func errorHighlight(_ isError: Bool, cornerRadius: CGFloat = 12) -> some View {
        self
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(isError ? Color.red : Color.clear, lineWidth: 1.5)
            )
            .shadow(color: isError ? Color.red.opacity(0.15) : Color.clear, radius: 6)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Status overlay modifier

private struct StatusOverlayView: View {
    let text: String
    @Binding var isPresented: Bool

    var body: some View {
        if isPresented && !text.isEmpty {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                        Text(text)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(3)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: Capsule(style: .continuous))
                    .shadow(color: Color.black.opacity(0.15), radius: 16, x: 0, y: 8)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isStaticText)
                    .accessibilityLabel(text)
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.spring(response: 0.4, dampingFraction: 0.9), value: isPresented)
        }
    }
}

private extension View {
    func statusOverlay(text: String, isPresented: Binding<Bool>) -> some View {
        ZStack {
            self
            StatusOverlayView(text: text, isPresented: isPresented)
        }
    }
}

// MARK: - Helper to show status messages

extension ContentView {
    @MainActor
    fileprivate func setStatus(_ message: String, visible: Bool) {
        self.status = message
        withAnimation {
            self.showStatus = visible
        }
    }

    fileprivate func show(_ message: String, success: Bool = false, duration: TimeInterval = 2.0) async {
        await MainActor.run {
            setStatus(message, visible: true)
        }
        // Keep it visible briefly, then hide
        try? await Task.sleep(nanoseconds: UInt64((success ? max(1.2, duration) : duration) * 1_000_000_000))
        await MainActor.run {
            setStatus("", visible: false)
        }
    }
}

