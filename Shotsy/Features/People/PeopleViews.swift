import Photos
import SwiftUI

struct PeopleView: View {
    @Environment(PeopleStore.self) private var people
    @Environment(SettingsStore.self) private var settings
    @Environment(PhotoLibrary.self) private var library
    @Environment(PurchaseStore.self) private var purchases
    @State private var assigning: FaceBatch?
    @State private var selectingFaces = false
    @State private var selectedFaces = Set<UUID>()

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: Space.s)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                if !settings.peopleEnabled {
                    MascotMessage(mood: .hi, title: "Group photos by person",
                                  message: "Shotsy can find faces in your photos on this iPhone so you can tag who's in them. It's for organizing, not identifying anyone. Names you add stay on this device.") {
                        Button("Turn on People") {
                            settings.peopleEnabled = true
                            people.startIfEnabled()
                        }
                        .buttonStyle(.primary)
                    }
                    .card()
                } else {
                    status
                    if !people.people.isEmpty {
                        SectionHeader(title: "People")
                        LazyVGrid(columns: columns, spacing: Space.m) {
                            ForEach(people.people) { person in
                                NavigationLink(value: LibraryRoute.person(person.id)) {
                                    VStack(spacing: Space.xxs) {
                                        FaceCropView(assetID: person.coverFace?.assetID ?? "", box: person.coverFace?.box)
                                            .frame(width: 84, height: 84)
                                        Text(person.displayName).font(.appSubheadline.weight(.semibold)).foregroundStyle(Color.appText)
                                            .lineLimit(1)
                                        Text("\(person.photoCount) photos").font(.appCaption).foregroundStyle(Color.appSecondaryText)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if !people.unassignedFaces.isEmpty {
                        HStack {
                            SectionHeader(title: "Faces to tag", detail: "\(people.unassignedFaces.count)")
                            Spacer()
                            Button(selectingFaces ? LocalizedStringKey("Cancel") : LocalizedStringKey("Select")) {
                                selectingFaces.toggle()
                                selectedFaces.removeAll()
                            }
                            .font(.appSubheadline.weight(.semibold))
                            .frame(minHeight: Space.minTap)
                        }
                        Text(selectingFaces
                             ? LocalizedStringKey("Select every face of the same person, then tag them together.")
                             : LocalizedStringKey("Tap a face to say who it is, or tap Select to tag many at once. Leave any you're not sure about."))
                            .font(.appFootnote).foregroundStyle(Color.appSecondaryText)
                        LazyVGrid(columns: columns, spacing: Space.m) {
                            ForEach(people.unassignedFaces.prefix(300)) { face in
                                Button {
                                    if selectingFaces {
                                        if selectedFaces.contains(face.id) { selectedFaces.remove(face.id) } else { selectedFaces.insert(face.id) }
                                    } else {
                                        assigning = FaceBatch(faces: [face])
                                    }
                                } label: {
                                    FaceCropView(assetID: face.assetID, box: face.box).frame(width: 76, height: 76)
                                        .overlay(alignment: .bottomTrailing) {
                                            if selectingFaces {
                                                Image(systemName: selectedFaces.contains(face.id) ? "checkmark.circle.fill" : "circle")
                                                    .font(.title3)
                                                    .foregroundStyle(Color.appAccent, .white)
                                                    .background(Circle().fill(.white).padding(2))
                                                    .padding(2)
                                            }
                                        }
                                }
                                .accessibilityLabel("Untagged face")
                                .accessibilityAddTraits(selectingFaces && selectedFaces.contains(face.id) ? .isSelected : [])
                            }
                        }
                    }
                    if people.people.isEmpty && people.unassignedFaces.isEmpty, people.phase == .complete {
                        MascotMessage(animated: .idle, title: "No faces found", message: "I didn't find faces in the photos available on this iPhone.")
                    }
                }
            }
            .padding(.horizontal, Space.page)
            .padding(.bottom, Space.xxl)
        }
        .softAppBar()
        .pageBackground()
        .navigationTitle("People")
        .safeAreaInset(edge: .bottom) {
            if selectingFaces, !selectedFaces.isEmpty {
                Button("Tag \(selectedFaces.count) faces") {
                    assigning = FaceBatch(faces: people.unassignedFaces.filter { selectedFaces.contains($0.id) })
                }
                .buttonStyle(.primary)
                .padding(.horizontal, Space.page)
                .padding(.vertical, Space.s)
                .background(.bar)
            }
        }
        .onAppear { people.startIfEnabled() }
        .sheet(item: $assigning, onDismiss: {
            // Tagged faces leave the list; drop them from the selection.
            selectedFaces.formIntersection(Set(people.unassignedFaces.map(\.id)))
            if selectedFaces.isEmpty { selectingFaces = false }
        }) { batch in AssignFaceSheet(faces: batch.faces) }
    }

    @ViewBuilder private var status: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            switch people.phase {
            case .detecting(let done, let total):
                Text("Finding faces… \(done) of \(total) photos").font(.appSubheadline.weight(.semibold))
                ProgressView(value: Double(done), total: Double(max(total, 1))).tint(Color.appAccentFill)
                Button("Pause") { people.pause() }.frame(minHeight: Space.minTap)
            case .paused:
                Text("Face finding paused").font(.appSubheadline.weight(.semibold))
                Button("Resume") { people.startIfEnabled() }.frame(minHeight: Space.minTap)
            default:
                EmptyView()
            }
            if people.automaticGroupingAvailable {
                if !purchases.isPro {
                    Text("Automatic grouping preview covers up to \(Policy.current.freePeoplePreviewPhotos) photos. Shotsy Pro groups your whole library.")
                        .font(.appFootnote).foregroundStyle(Color.appSecondaryText)
                }
            } else {
                Text("Automatic grouping isn't available in this version. Shotsy finds faces; you tag who they are, and your tags stay on this iPhone.")
                    .font(.appFootnote).foregroundStyle(Color.appSecondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// Faces tagged together in one "Who is this?" sheet.
struct FaceBatch: Identifiable {
    let id = UUID()
    let faces: [FaceSnapshot]
}

/// Pick an existing person or create a new one for one or more faces.
struct AssignFaceSheet: View {
    let faces: [FaceSnapshot]
    @Environment(PeopleStore.self) private var people
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if faces.count == 1, let face = faces.first {
                        HStack {
                            Spacer()
                            FaceCropView(assetID: face.assetID, box: face.box).frame(width: 120, height: 120)
                            Spacer()
                        }
                        .listRowBackground(Color.clear)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: Space.xs) {
                                ForEach(faces.prefix(30)) { face in
                                    FaceCropView(assetID: face.assetID, box: face.box).frame(width: 64, height: 64)
                                }
                            }
                        }
                        .listRowBackground(Color.clear)
                    }
                }
                Section("New person") {
                    HStack {
                        TextField("Name (optional)", text: $newName)
                        Button("Add") {
                            people.tag(faces.map(\.id), asNamed: newName)
                            dismiss()
                        }
                    }
                }
                if !people.people.isEmpty {
                    Section("Existing") {
                        ForEach(people.people) { p in
                            Button {
                                people.assign(faces.map(\.id), to: p.id)
                                dismiss()
                            } label: {
                                HStack {
                                    FaceCropView(assetID: p.coverFace?.assetID ?? "", box: p.coverFace?.box).frame(width: 36, height: 36)
                                    Text(p.displayName).foregroundStyle(Color.appText)
                                }
                            }
                        }
                    }
                }
            }
            .softAppBar()
            .navigationTitle("Who is this?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

struct PersonDetailView: View {
    let personID: UUID
    @Environment(PeopleStore.self) private var people
    @Environment(\.dismiss) private var dismiss
    @State private var renaming = false
    @State private var name = ""
    @State private var selecting = false
    @State private var selectedFaces = Set<UUID>()
    @State private var merging = false
    @State private var addingPhoto = false
    @State private var preview: PreviewRequest?
    @State private var confirmDelete = false

    private let columns = [GridItem(.adaptive(minimum: 84), spacing: Space.s)]

    var body: some View {
        let person = people.people.first { $0.id == personID }
        let faces = people.faces(of: personID)
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                if let person {
                    HStack(spacing: Space.m) {
                        FaceCropView(assetID: person.coverFace?.assetID ?? "", box: person.coverFace?.box).frame(width: 72, height: 72)
                        VStack(alignment: .leading) {
                            Text(person.displayName).font(.display(22, relativeTo: .title2)).foregroundStyle(Color.appText)
                            Text("\(person.photoCount) photos").font(.appFootnote).foregroundStyle(Color.appSecondaryText)
                        }
                    }
                }
                SectionHeader(title: "Faces", detail: selecting ? "\(selectedFaces.count) selected" : nil)
                LazyVGrid(columns: columns, spacing: Space.s) {
                    ForEach(faces) { face in
                        Button {
                            if selecting {
                                if selectedFaces.contains(face.id) { selectedFaces.remove(face.id) } else { selectedFaces.insert(face.id) }
                            } else {
                                preview = PreviewRequest(ids: people.assetIDs(of: personID), start: face.assetID)
                            }
                        } label: {
                            FaceCropView(assetID: face.assetID, box: face.box)
                                .frame(width: 72, height: 72)
                                .overlay(alignment: .topTrailing) {
                                    if selecting {
                                        Image(systemName: selectedFaces.contains(face.id) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(Color.appAccent)
                                            .background(Circle().fill(Color.appSurface))
                                    }
                                }
                        }
                        .contextMenu {
                            Button("Not this person", systemImage: "person.fill.xmark") { people.notThisPerson(face.id) }
                            Button("Use as cover", systemImage: "person.crop.circle") { people.chooseCover(personID, face: face.id) }
                        }
                        .accessibilityLabel("Face")
                        .accessibilityAction(named: "Not this person") { people.notThisPerson(face.id) }
                        .accessibilityAction(named: "Use as cover") { people.chooseCover(personID, face: face.id) }
                    }
                }
                Text("Touch and hold a face for “Not this person” or to use it as the cover.")
                    .font(.appFootnote).foregroundStyle(Color.appSecondaryText)
            }
            .padding(.horizontal, Space.page)
            .padding(.bottom, Space.xxl)
        }
        .softAppBar()
        .pageBackground()
        .navigationTitle(person?.displayName ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Name person", systemImage: "pencil") { name = person?.name ?? ""; renaming = true }
                    Button("Merge groups…", systemImage: "arrow.triangle.merge") { merging = true }
                    Button("Add missing photo…", systemImage: "plus.viewfinder") { addingPhoto = true }
                    Button(selecting ? "Done selecting" : "Select faces to split", systemImage: "scissors") {
                        selecting.toggle(); selectedFaces.removeAll()
                    }
                    Button("Remove person", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } label: { Label("Actions", systemImage: "ellipsis.circle") }
            }
            if selecting {
                ToolbarItem(placement: .bottomBar) {
                    Button("Split \(selectedFaces.count) into new person") {
                        people.split(Array(selectedFaces), from: personID, newName: nil)
                        selecting = false
                        selectedFaces.removeAll()
                    }
                    .disabled(selectedFaces.isEmpty || selectedFaces.count == faces.count)
                }
            }
        }
        .alert("Name person", isPresented: $renaming) {
            TextField("Name", text: $name)
            Button("Save") { people.name(personID, name) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Names stay on this iPhone.")
        }
        .confirmationDialog("Remove this person?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Remove person", role: .destructive) { people.deletePerson(personID); dismiss() }
        } message: {
            Text("Only Shotsy's tags are removed. Your photos stay in your library.")
        }
        .sheet(isPresented: $merging) { MergePersonSheet(personID: personID) }
        .sheet(isPresented: $addingPhoto) {
            AssetPickerSheet(title: String(localized: "Add missing photo"), filter: .photos) { ids in
                for id in ids { people.addPhoto(id, to: personID) }
            }
        }
        .fullScreenCover(item: $preview) { AssetPreviewView(request: $0) }
    }
}

private struct MergePersonSheet: View {
    let personID: UUID
    @Environment(PeopleStore.self) private var people
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(people.people.filter { $0.id != personID }) { other in
                Button {
                    people.merge(other.id, into: personID)
                    dismiss()
                } label: {
                    HStack {
                        FaceCropView(assetID: other.coverFace?.assetID ?? "", box: other.coverFace?.box).frame(width: 40, height: 40)
                        Text(other.displayName).foregroundStyle(Color.appText)
                        Spacer()
                        Text("\(other.photoCount)").foregroundStyle(Color.appSecondaryText)
                    }
                }
            }
            .softAppBar()
            .navigationTitle("Merge into this person")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

/// Multi-select picker over the library (used for "Add missing photo" and "Add photos" to an album).
struct AssetPickerSheet: View {
    let title: String
    var filter: MediaFilter = .all
    let onPick: ([String]) -> Void

    @Environment(PhotoLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var ids: [String] = []
    @State private var selection = Set<String>()

    var body: some View {
        NavigationStack {
            AssetIDGrid(ids: ids, selection: $selection, selectionMode: true) { _ in }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add \(selection.count)") { onPick(Array(selection)); dismiss() }
                            .disabled(selection.isEmpty)
                    }
                }
                .task {
                    let result = library.fetch(filter)
                    ids = await BackgroundFetch.run {
                        let limit = min(result.count, 3000)
                        return limit > 0 ? result.objects(at: IndexSet(integersIn: 0..<limit)).map(\.localIdentifier) : []
                    }
                }
        }
    }
}
