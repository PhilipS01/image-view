import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

@main
struct LocalPhotoCollagePickerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1100, minHeight: 720)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

struct PhotoItem: Identifiable, Hashable {
    static let largeFileThresholdBytes: Int64 = 10 * 1024 * 1024

    let id = UUID()
    let url: URL
    let fileSizeBytes: Int64
    let relativeDirectory: String

    var filename: String {
        url.lastPathComponent
    }

    var isLargeFile: Bool {
        fileSizeBytes > Self.largeFileThresholdBytes
    }

    var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
    }
}

struct PhotoGroup: Identifiable {
    let id: String
    let title: String
    let photos: [PhotoItem]
    let totalSizeBytes: Int64

    var formattedTotalSize: String {
        ByteCountFormatter.string(fromByteCount: totalSizeBytes, countStyle: .file)
    }
}

@MainActor
final class PhotoCollageViewModel: ObservableObject {
    @Published var folderURL: URL?
    @Published var photos: [PhotoItem] = []
    @Published var photoGroups: [PhotoGroup] = []
    @Published var selectedPhoto: PhotoItem?
    @Published var selectedPhotoIDs: Set<PhotoItem.ID> = []
    @Published var lastSelectedPhotoID: PhotoItem.ID?
    @Published var collagePhotos: [PhotoItem] = []
    @Published var hoveredCollagePhoto: PhotoItem?
    @Published var collageCellBaseWidth: CGFloat = 170
    @Published var folderPathInput: String = ""
    @Published var folderPathErrorMessage: String?
    @Published var pathSuggestions: [String] = []
    @Published var selectedPathSuggestionIndex: Int?
    @Published var isSlideshowRunning: Bool = false
    @Published var isSlideshowPaused: Bool = false
    @Published var slideshowPhoto: PhotoItem?
    @Published var slideshowIntervalSeconds: Double = 2.0
    @Published var slideshowImagesPerSlide: Int = 1

    private var slideshowTask: Task<Void, Never>?

    private let maxPathSuggestions = 8

    private let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "webp", "tif", "tiff", "gif", "bmp", "cr2", "cr3", "raw"
    ]
    
    var currentSlideshowPhotos: [PhotoItem] {
        guard let slideshowPhoto,
              !collagePhotos.isEmpty,
              let startIndex = collagePhotos.firstIndex(where: { $0.url == slideshowPhoto.url }) else {
            return []
        }

        let count = min(max(slideshowImagesPerSlide, 1), min(6, collagePhotos.count))

        return (0..<count).map { offset in
            collagePhotos[(startIndex + offset) % collagePhotos.count]
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a photo folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true

        if panel.runModal() == .OK, let url = panel.url {
            loadFolder(url)
        }
    }

    func loadFolder(_ url: URL) {
        folderURL = url
        folderPathInput = url.path(percentEncoded: false)

        let keys: [URLResourceKey] = [.isRegularFileKey, .localizedNameKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        ) else {
            photos = []
            photoGroups = []
            selectedPhoto = nil
            selectedPhotoIDs = []
            lastSelectedPhotoID = nil
            return
        }

        var loaded: [PhotoItem] = []

        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard supportedExtensions.contains(ext) else { continue }

            let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
            let fileSizeBytes = Int64(resourceValues?.fileSize ?? 0)
            let relativeDirectory = relativeDirectoryName(for: fileURL, folderURL: url)
            loaded.append(PhotoItem(url: fileURL, fileSizeBytes: fileSizeBytes, relativeDirectory: relativeDirectory))
        }

        loaded.sort {
            if $0.relativeDirectory != $1.relativeDirectory {
                return $0.relativeDirectory.localizedStandardCompare($1.relativeDirectory) == .orderedAscending
            }
            return $0.filename.localizedStandardCompare($1.filename) == .orderedAscending
        }

        photos = loaded
        photoGroups = makePhotoGroups(from: loaded)
        selectedPhoto = loaded.first
        selectedPhotoIDs = loaded.first.map { [$0.id] } ?? []
        lastSelectedPhotoID = loaded.first?.id
        collagePhotos = []
        hoveredCollagePhoto = nil
        stopSlideshow()
    }

    func updatePathSuggestions() {
        let rawInput = folderPathInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawInput.isEmpty else {
            pathSuggestions = []
            selectedPathSuggestionIndex = nil
            return
        }

        let searchTargets = pathSuggestionSearchTargets(for: rawInput)
        var allMatches: [(path: String, score: Int)] = []

        for target in searchTargets {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: target.parentPath, isDirectory: true),
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            ) else { continue }

            let matches = contents.compactMap { url -> (path: String, score: Int)? in
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
                let name = url.lastPathComponent
                guard let fuzzyScore = fuzzyPathSuggestionScore(name: name, query: target.partialName) else { return nil }
                return (
                    displayPathForSuggestion(url.path(percentEncoded: false), originalInput: target.displayStyleInput),
                    target.baseScore + fuzzyScore
                )
            }

            allMatches.append(contentsOf: matches)
        }

        let scoredMatches = Dictionary(grouping: allMatches, by: \.path)
            .compactMap { _, matches in matches.min { $0.score < $1.score } }
            .sorted {
                if $0.score != $1.score { return $0.score < $1.score }
                return $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
            .prefix(maxPathSuggestions)

        pathSuggestions = scoredMatches.map(\.path)
        selectedPathSuggestionIndex = pathSuggestions.isEmpty ? nil : 0
    }
    
    func preloadUpcomingSlideshowImages() {
        guard !collagePhotos.isEmpty,
              let slideshowPhoto,
              let startIndex = collagePhotos.firstIndex(where: { $0.url == slideshowPhoto.url }) else {
            return
        }

        let count = min(max(slideshowImagesPerSlide, 1), min(5, collagePhotos.count))
        let preloadCount = min(count * 2, collagePhotos.count)

        let urls = (0..<preloadCount).map { offset in
            collagePhotos[(startIndex + offset) % collagePhotos.count].url
        }

        Task {
            for url in urls {
                _ = await ImageLoader.shared.fullImage(for: url)
            }
        }
    }

    private struct PathSuggestionSearchTarget {
        let parentPath: String
        let partialName: String
        let displayStyleInput: String
        let baseScore: Int
    }

    private func pathSuggestionSearchTargets(for rawInput: String) -> [PathSuggestionSearchTarget] {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)

        if !rawInput.contains("/") && !rawInput.hasPrefix("~") {
            var targets = [
                PathSuggestionSearchTarget(parentPath: homePath, partialName: rawInput.lowercased(), displayStyleInput: "~", baseScore: 0),
                PathSuggestionSearchTarget(parentPath: homePath + "/Library/Mobile Documents/com~apple~CloudDocs", partialName: rawInput.lowercased(), displayStyleInput: "~", baseScore: 30),
                PathSuggestionSearchTarget(parentPath: "/Volumes", partialName: rawInput.lowercased(), displayStyleInput: "/Volumes", baseScore: 40)
            ]

            targets = targets.filter { target in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: target.parentPath, isDirectory: &isDirectory) && isDirectory.boolValue
            }

            return targets
        }

        let expandedInput = NSString(string: rawInput).expandingTildeInPath
        let nsInput = expandedInput as NSString
        let parentPath: String
        let partialName: String

        if rawInput.hasSuffix("/") {
            parentPath = expandedInput
            partialName = ""
        } else {
            parentPath = nsInput.deletingLastPathComponent.isEmpty ? "/" : nsInput.deletingLastPathComponent
            partialName = nsInput.lastPathComponent.lowercased()
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parentPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            return []
        }

        return [PathSuggestionSearchTarget(parentPath: parentPath, partialName: partialName, displayStyleInput: rawInput, baseScore: 0)]
    }

    private func fuzzyPathSuggestionScore(name: String, query: String) -> Int? {
        guard !query.isEmpty else { return 0 }

        let candidate = name.lowercased()
        let query = query.lowercased()

        if candidate == query { return 0 }
        if candidate.hasPrefix(query) { return 10 + candidate.count - query.count }
        if candidate.contains(query) { return 100 + candidate.count - query.count }

        var score = 300
        var searchStart = candidate.startIndex
        var previousMatchIndex: String.Index?

        for character in query {
            guard let matchIndex = candidate[searchStart...].firstIndex(of: character) else {
                return nil
            }

            let distance = candidate.distance(from: searchStart, to: matchIndex)
            score += distance

            if let previousMatchIndex {
                let gap = candidate.distance(from: previousMatchIndex, to: matchIndex)
                score += max(gap - 1, 0) * 3
            }

            previousMatchIndex = matchIndex
            searchStart = candidate.index(after: matchIndex)
        }

        return score + candidate.count
    }

    func acceptPathSuggestion(_ suggestion: String) {
        folderPathInput = suggestion
        pathSuggestions = []
        selectedPathSuggestionIndex = nil
        loadFolderFromPathInput()
    }

    func cyclePathSuggestionForward() {
        guard !pathSuggestions.isEmpty else { return }
        let current = selectedPathSuggestionIndex ?? -1
        selectedPathSuggestionIndex = (current + 1) % pathSuggestions.count
    }

    func cyclePathSuggestionBackward() {
        guard !pathSuggestions.isEmpty else { return }
        let current = selectedPathSuggestionIndex ?? 0
        selectedPathSuggestionIndex = (current - 1 + pathSuggestions.count) % pathSuggestions.count
    }

    func acceptSelectedPathSuggestion() -> Bool {
        guard let index = selectedPathSuggestionIndex,
              pathSuggestions.indices.contains(index) else {
            return false
        }
        acceptPathSuggestion(pathSuggestions[index])
        return true
    }

    private func displayPathForSuggestion(_ absolutePath: String, originalInput: String) -> String {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        if originalInput.hasPrefix("~"), absolutePath.hasPrefix(homePath) {
            let suffix = String(absolutePath.dropFirst(homePath.count))
            if suffix.isEmpty {
                return "~"
            }
            if suffix.hasPrefix("/") {
                return "~" + suffix
            }
            return "~/" + suffix
        }
        return absolutePath
    }

    func loadFolderFromPathInput() {
        let rawInput = folderPathInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawInput.isEmpty else { return }

        let url = resolvedFolderURL(from: rawInput)
        let path = url.path(percentEncoded: false)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            folderPathErrorMessage = "That folder does not exist or is not a directory: " + path
            NSSound.beep()
            return
        }

        guard FileManager.default.isReadableFile(atPath: path) else {
            folderPathErrorMessage = "The app cannot read this folder: " + path + "\n\nIf you are running a sandboxed Xcode build, disable App Sandbox in Signing & Capabilities, or open the folder once with Choose Folder."
            NSSound.beep()
            return
        }

        pathSuggestions = []
        selectedPathSuggestionIndex = nil
        loadFolder(url)
    }

    private func resolvedFolderURL(from input: String) -> URL {
        if input.lowercased().hasPrefix("file://"), let url = URL(string: input) {
            return url
        }

        let normalizedInput: String
        if input.hasPrefix("~"), !input.hasPrefix("~/"), input != "~" {
            normalizedInput = "~/" + input.dropFirst()
        } else if !input.contains("/") && !input.hasPrefix("~") {
            let homeCandidate = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(input, isDirectory: true).path(percentEncoded: false)
            let volumeCandidate = "/Volumes/" + input

            var homeIsDirectory: ObjCBool = false
            var volumeIsDirectory: ObjCBool = false

            if FileManager.default.fileExists(atPath: homeCandidate, isDirectory: &homeIsDirectory), homeIsDirectory.boolValue {
                normalizedInput = "~/" + input
            } else if FileManager.default.fileExists(atPath: volumeCandidate, isDirectory: &volumeIsDirectory), volumeIsDirectory.boolValue {
                normalizedInput = volumeCandidate
            } else {
                normalizedInput = "~/" + input
            }
        } else {
            normalizedInput = input
        }

        let expanded = NSString(string: normalizedInput).expandingTildeInPath

        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }

        // A GUI app usually does not inherit your shell's current directory.
        // Treat relative paths as relative to the user's home folder.
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(expanded, isDirectory: true)
    }

    private func relativeDirectoryName(for fileURL: URL, folderURL: URL) -> String {
        let folderPath = folderURL.standardizedFileURL.path(percentEncoded: false)
        let parentPath = fileURL.deletingLastPathComponent().standardizedFileURL.path(percentEncoded: false)

        guard parentPath.hasPrefix(folderPath) else { return "." }

        let relative = parentPath.dropFirst(folderPath.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.isEmpty ? "." : String(relative)
    }

    private func makePhotoGroups(from photos: [PhotoItem]) -> [PhotoGroup] {
        let grouped = Dictionary(grouping: photos, by: \.relativeDirectory)

        return grouped.keys
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { key in
                let groupPhotos = grouped[key] ?? []
                let totalSize = groupPhotos.reduce(Int64(0)) { $0 + $1.fileSizeBytes }

                return PhotoGroup(
                    id: key,
                    title: key == "." ? "Current folder" : key,
                    photos: groupPhotos,
                    totalSizeBytes: totalSize
                )
            }
    }

    func addSelectedToCollage() {
        let selectedPhotos = photos.filter { selectedPhotoIDs.contains($0.id) }

        if selectedPhotos.isEmpty, let selectedPhoto {
            addToCollage(selectedPhoto)
            return
        }

        for photo in selectedPhotos {
            addToCollage(photo)
        }
    }

    func removeSelectedFromCollage() {
        let selectedURLs = Set(photos.filter { selectedPhotoIDs.contains($0.id) }.map(\.url))
        guard !selectedURLs.isEmpty else { return }

        collagePhotos.removeAll { selectedURLs.contains($0.url) }

        if let hovered = hoveredCollagePhoto, selectedURLs.contains(hovered.url) {
            hoveredCollagePhoto = nil
        }

        if let slideshow = slideshowPhoto, selectedURLs.contains(slideshow.url) {
            slideshowPhoto = collagePhotos.first
        }

        if collagePhotos.isEmpty {
            stopSlideshow()
        }
    }

    func clearCollage() {
        collagePhotos = []
        hoveredCollagePhoto = nil
        stopSlideshow()
    }

    func addToCollage(_ photo: PhotoItem) {
        guard !collagePhotos.contains(where: { $0.url == photo.url }) else { return }
        collagePhotos.append(photo)
    }

    func selectPhoto(_ photo: PhotoItem, modifiers: NSEvent.ModifierFlags) {
        selectedPhoto = photo

        if modifiers.contains(.shift), let lastSelectedPhotoID,
           let startIndex = photos.firstIndex(where: { $0.id == lastSelectedPhotoID }),
           let endIndex = photos.firstIndex(where: { $0.id == photo.id }) {
            let bounds = min(startIndex, endIndex)...max(startIndex, endIndex)
            selectedPhotoIDs = Set(photos[bounds].map(\.id))
            return
        }

        if modifiers.contains(.command) {
            if selectedPhotoIDs.contains(photo.id) {
                selectedPhotoIDs.remove(photo.id)
            } else {
                selectedPhotoIDs.insert(photo.id)
            }
            lastSelectedPhotoID = photo.id
            return
        }

        selectedPhotoIDs = [photo.id]
        lastSelectedPhotoID = photo.id
    }

    func removeFromCollage(_ photo: PhotoItem) {
        collagePhotos.removeAll { $0.url == photo.url }
        if hoveredCollagePhoto?.url == photo.url {
            hoveredCollagePhoto = nil
        }
        if slideshowPhoto?.url == photo.url {
            slideshowPhoto = collagePhotos.first
        }
        if collagePhotos.isEmpty {
            stopSlideshow()
        }
    }

    func toggleSlideshow() {
        isSlideshowRunning ? stopSlideshow() : startSlideshow()
    }

    func startSlideshow() {
        guard !collagePhotos.isEmpty else { return }

        slideshowTask?.cancel()
        isSlideshowRunning = true
        isSlideshowPaused = false

        if slideshowPhoto == nil || !collagePhotos.contains(where: { $0.url == slideshowPhoto?.url }) {
            slideshowPhoto = collagePhotos.first
        }

        slideshowTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let isPaused = await MainActor.run { self.isSlideshowPaused }

                if isPaused {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    continue
                }

                let seconds = await MainActor.run { self.slideshowIntervalSeconds }
                let nanoseconds = UInt64(max(seconds, 0.25) * 1_000_000_000)

                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }

                let pausedAfterSleep = await MainActor.run { self.isSlideshowPaused }
                guard !pausedAfterSleep else { continue }

                await MainActor.run {
                    self.advanceSlideshow()
                }
            }
        }
        preloadUpcomingSlideshowImages()
    }

    func stopSlideshow() {
        slideshowTask?.cancel()
        slideshowTask = nil
        isSlideshowRunning = false
        isSlideshowPaused = false
        slideshowPhoto = nil
    }

    func toggleSlideshowPause() {
        guard isSlideshowRunning else { return }
        isSlideshowPaused.toggle()
    }

    func advanceSlideshow() {
        guard !collagePhotos.isEmpty else {
            stopSlideshow()
            return
        }

        guard let current = slideshowPhoto,
              let currentIndex = collagePhotos.firstIndex(where: { $0.url == current.url }) else {
            slideshowPhoto = collagePhotos.first
            return
        }

        let step = min(max(slideshowImagesPerSlide, 1), max(collagePhotos.count, 1))
        let nextIndex = (currentIndex + step) % collagePhotos.count
        slideshowPhoto = collagePhotos[nextIndex]
        preloadUpcomingSlideshowImages()
    }

    func previousSlideshowPhoto() {
        guard !collagePhotos.isEmpty else {
            stopSlideshow()
            return
        }

        guard let current = slideshowPhoto,
              let currentIndex = collagePhotos.firstIndex(where: { $0.url == current.url }) else {
            slideshowPhoto = collagePhotos.first
            return
        }

        let step = min(max(slideshowImagesPerSlide, 1), max(collagePhotos.count, 1))
        let previousIndex = (currentIndex - step + collagePhotos.count) % collagePhotos.count
        slideshowPhoto = collagePhotos[previousIndex]
        preloadUpcomingSlideshowImages()
    }
}

struct ContentView: View {
    @StateObject private var viewModel = PhotoCollageViewModel()
    @FocusState private var focusedField: FocusedField?

    private enum FocusedField: Hashable {
        case folderPath
        case photoList
    }

    var body: some View {
        HSplitView {
            leftPanel
                .frame(minWidth: 320, idealWidth: 430, maxWidth: 560)

            collagePanel
                .frame(minWidth: 420)
        }
        .onLocalKeyDown { event in
            handleLocalKeyDown(event)
        }
        .alert("Could not open folder", isPresented: Binding(
            get: { viewModel.folderPathErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.folderPathErrorMessage = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {
                viewModel.folderPathErrorMessage = nil
            }
        } message: {
            Text(viewModel.folderPathErrorMessage ?? "Unknown error")
        }
    }

    private var leftPanel: some View {
        VStack(spacing: 0) {
            browserHeader

            HSplitView {
                photoList
                    .frame(minHeight: 220, idealHeight: 320)

                selectedPreview
                    .frame(minHeight: 260)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var browserHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            WrappingHStack(spacing: 8, rowSpacing: 6) {
                Button("Choose Folder") {
                    viewModel.chooseFolder()
                }

                Button("Add Selected") {
                    viewModel.addSelectedToCollage()
                }
                .disabled(viewModel.isSlideshowRunning || (viewModel.selectedPhoto == nil && viewModel.selectedPhotoIDs.isEmpty))

                Button("Remove Selected") {
                    viewModel.removeSelectedFromCollage()
                }
                .disabled(viewModel.isSlideshowRunning || viewModel.selectedPhotoIDs.isEmpty || viewModel.collagePhotos.isEmpty)

                Text("\(viewModel.photos.count) photos · \(viewModel.selectedPhotoIDs.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Folder path, e.g. ~/Pictures, ~/.hidden, or .hidden", text: $viewModel.folderPathInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                        .focused($focusedField, equals: .folderPath)
                        .onChange(of: viewModel.folderPathInput) { _ in
                            viewModel.updatePathSuggestions()
                        }
                        .onSubmit {
                            if !viewModel.acceptSelectedPathSuggestion() {
                                viewModel.loadFolderFromPathInput()
                            }
                            focusPhotoListAfterPathOpen()
                        }

                    if focusedField == .folderPath && !viewModel.pathSuggestions.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(viewModel.pathSuggestions.enumerated()), id: \.element) { index, suggestion in
                                Button {
                                    viewModel.acceptPathSuggestion(suggestion)
                                    focusPhotoListAfterPathOpen()
                                } label: {
                                    HStack {
                                        Image(systemName: "folder")
                                            .foregroundStyle(.secondary)
                                        Text(suggestion)
                                            .font(.caption.monospaced())
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(index == viewModel.selectedPathSuggestionIndex ? Color.accentColor.opacity(0.22) : Color.clear)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.22))
                        )
                    }
                }

                Button("Open Path") {
                    viewModel.loadFolderFromPathInput()
                    focusPhotoListAfterPathOpen()
                }
            }

            Text("Enter a path manually for hidden folders such as ~/.config or drag/use Choose Folder for normal browsing.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(10)
    }

    private var photoList: some View {
        List(selection: $viewModel.selectedPhotoIDs) {
            ForEach(viewModel.photoGroups) { group in
                Section {
                    ForEach(group.photos) { photo in
                        HStack(spacing: 10) {
                            if photo.isLargeFile && !viewModel.collagePhotos.contains(where: { $0.url == photo.url }) {
                                LargeFilePlaceholderView(fileSize: photo.formattedFileSize)
                                    .frame(width: 44, height: 44)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            } else {
                                ThumbnailView(url: photo.url, targetSize: CGSize(width: 44, height: 44))
                                    .frame(width: 44, height: 44)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(photo.filename)
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                HStack(spacing: 6) {
                                    if photo.relativeDirectory != "." {
                                        Text(photo.relativeDirectory)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }

                                    Text(photo.formattedFileSize)
                                        .monospacedDigit()
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .tag(photo.id)
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button("Add to Collage") {
                                viewModel.addToCollage(photo)
                            }
                        }
                        .simultaneousGesture(
                            TapGesture(count: 1).onEnded {
                                viewModel.selectPhoto(photo, modifiers: NSEvent.modifierFlags)
                            }
                        )
                    }
                } header: {
                    HStack(spacing: 8) {
                        Text(group.title)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()

                        Text("\(group.photos.count) photos")
                            .foregroundStyle(.secondary)

                        Text(group.formattedTotalSize)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .focused($focusedField, equals: .photoList)
    }

    private var selectedPreview: some View {
        VStack(spacing: 10) {
            if let selectedPhoto = viewModel.selectedPhoto {
                if selectedPhoto.isLargeFile && !viewModel.collagePhotos.contains(where: { $0.url == selectedPhoto.url }) {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 44))
                            .foregroundStyle(.secondary)

                        Text("Large file not loaded yet")
                            .font(.headline)

                        Text("\(selectedPhoto.filename) is \(selectedPhoto.formattedFileSize). It will load when you add it to the collage.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding([.horizontal, .top], 12)
                } else {
                    FullImageView(url: selectedPhoto.url, scaling: .fit)
                        .id(selectedPhoto.url)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding([.horizontal, .top], 12)
                }

                HStack {
                    Text(selectedPhoto.filename)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Button("Add") {
                        viewModel.addToCollage(selectedPhoto)
                    }
                    .keyboardShortcut(.return, modifiers: [])
                }
                .padding([.horizontal, .bottom], 12)
            } else {
                ContentUnavailableView(
                    "No Photo Selected",
                    systemImage: "photo",
                    description: Text("Choose a folder and select a photo.")
                )
            }
        }
    }

    private var collagePanel: some View {
        ZStack(alignment: .center) {
            VStack(spacing: 0) {
                collageHeader
                collageGrid
            }
            .background(Color(nsColor: .controlBackgroundColor))

            if let slideshowPhoto = viewModel.slideshowPhoto {
                SlideshowPanelOverlay(photos: viewModel.currentSlideshowPhotos)
                    .transition(.opacity)
                    .zIndex(20)
            } else if let hovered = viewModel.hoveredCollagePhoto {
                FullPanelImageOverlay(url: hovered.url, title: hovered.filename)
                    .id(hovered.url)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: viewModel.hoveredCollagePhoto)
    }

    private var collageHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Collage Grid")
                        .font(.headline)

                    Text("Hover to enlarge. Start slideshow to loop through the collage.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("\(viewModel.collagePhotos.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            WrappingHStack(spacing: 10, rowSpacing: 8) {
                Button(viewModel.isSlideshowRunning ? "Stop Slideshow" : "Start Slideshow") {
                    viewModel.toggleSlideshow()
                }
                .disabled(viewModel.collagePhotos.isEmpty)

                Button("Clear") {
                    viewModel.clearCollage()
                }
                .disabled(viewModel.isSlideshowRunning || viewModel.collagePhotos.isEmpty)

                Button(viewModel.isSlideshowPaused ? "Resume" : "Pause") {
                    viewModel.toggleSlideshowPause()
                }
                .disabled(!viewModel.isSlideshowRunning || viewModel.collagePhotos.isEmpty)

                Button("Exit") {
                    viewModel.stopSlideshow()
                }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(!viewModel.isSlideshowRunning)

                Button("◀") {
                    viewModel.previousSlideshowPhoto()
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(!viewModel.isSlideshowRunning || viewModel.collagePhotos.isEmpty)

                Button("▶") {
                    viewModel.advanceSlideshow()
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(!viewModel.isSlideshowRunning || viewModel.collagePhotos.isEmpty)

                HStack(spacing: 6) {
                    Text("Delay")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Stepper("\(viewModel.slideshowIntervalSeconds, specifier: "%.1f")s", value: $viewModel.slideshowIntervalSeconds, in: 0.5...10, step: 0.5)
                        .font(.caption.monospacedDigit())
                        .frame(width: 92)
                }
                
                Picker("Per slide", selection: $viewModel.slideshowImagesPerSlide) {
                    ForEach([1,2,4,6], id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 92)
                .disabled(viewModel.isSlideshowRunning)

                HStack(spacing: 6) {
                    Text("Grid size")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Slider(value: $viewModel.collageCellBaseWidth, in: 100...320, step: 10)
                        .frame(width: 140)

                    Text("\(Int(viewModel.collageCellBaseWidth)) px")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                }
            }
        }
        .padding(12)
    }
    
    
    private var collageGrid: some View {
        GeometryReader { geometry in
            let columns = gridColumns(for: geometry.size.width)
            let cellWidth = gridCellWidth(containerWidth: geometry.size.width, columnCount: columns.count)
            let cellHeight = cellWidth * 0.78

            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(viewModel.collagePhotos) { photo in
                        CollageCell(photo: photo, cellWidth: cellWidth, cellHeight: cellHeight) {
                            viewModel.removeFromCollage(photo)
                        }
                        .onHover { isHovering in
                            if isHovering {
                                viewModel.hoveredCollagePhoto = photo
                            } else if viewModel.hoveredCollagePhoto?.url == photo.url {
                                viewModel.hoveredCollagePhoto = nil
                            }
                        }
                    }
                }
                .padding(12)
            }
            .overlay {
                if viewModel.collagePhotos.isEmpty {
                    ContentUnavailableView(
                        "No Collage Photos Yet",
                        systemImage: "square.grid.3x3",
                        description: Text("Select one or more photos on the left and press Space, Return, or double-click to add them. Cmd-click toggles individual photos; Shift-click selects a range.")
                    )
                }
            }
        }
    }

    private func handleLocalKeyDown(_ event: NSEvent) -> NSEvent? {
        if focusedField == .folderPath {
            switch event.keyCode {
            case 48: // Tab
                if event.modifierFlags.contains(.shift) {
                    viewModel.cyclePathSuggestionBackward()
                } else {
                    viewModel.cyclePathSuggestionForward()
                }
                return nil
            case 125: // Down Arrow
                viewModel.cyclePathSuggestionForward()
                return nil
            case 126: // Up Arrow
                viewModel.cyclePathSuggestionBackward()
                return nil
            case 36, 76: // Return, keypad Enter
                if viewModel.acceptSelectedPathSuggestion() {
                    focusPhotoListAfterPathOpen()
                    return nil
                }
                return event
            default:
                return event
            }
        }

        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else {
            return event
        }

        if focusedField == .photoList,
           event.charactersIgnoringModifiers?.lowercased() == "x" {
            viewModel.removeSelectedFromCollage()
            return nil
        }

        switch event.keyCode {
        case 49: // Space
            if viewModel.isSlideshowRunning {
                viewModel.toggleSlideshowPause()
            } else {
                viewModel.addSelectedToCollage()
            }
            return nil
        case 53: // Escape
            if viewModel.isSlideshowRunning {
                viewModel.stopSlideshow()
                focusPhotoListAfterPathOpen()
                return nil
            }
            return event
        case 123: // Left arrow
            if viewModel.isSlideshowRunning {
                viewModel.previousSlideshowPhoto()
                return nil
            }
            return event
        case 124: // Right arrow
            if viewModel.isSlideshowRunning {
                viewModel.advanceSlideshow()
                return nil
            }
            return event
        default:
            return event
        }
    }

    private func focusPhotoListAfterPathOpen() {
        focusedField = nil
        DispatchQueue.main.async {
            focusedField = .photoList
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    private func gridCellWidth(containerWidth: CGFloat, columnCount: Int) -> CGFloat {
        let outerPadding: CGFloat = 24
        let spacing: CGFloat = CGFloat(max(columnCount - 1, 0)) * 12
        return max((containerWidth - outerPadding - spacing) / CGFloat(columnCount), 120)
    }

    private func gridColumns(for width: CGFloat) -> [GridItem] {
        let minimumCellWidth = viewModel.collageCellBaseWidth
        let count = max(Int(width / minimumCellWidth), 1)
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }
}

struct WrappingHStack: Layout {
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = computeRows(maxWidth: maxWidth, subviews: subviews)

        let totalHeight = rows.enumerated().reduce(CGFloat(0)) { result, item in
            let rowHeight = item.element.height
            let spacing = item.offset == 0 ? CGFloat(0) : rowSpacing
            return result + spacing + rowHeight
        }

        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: min(width, maxWidth), height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let rows = computeRows(maxWidth: bounds.width, subviews: subviews)

        var y = bounds.minY

        for row in rows {
            var x = bounds.minX

            for index in row.indices {
                let subview = subviews[index]
                let size = subview.sizeThatFits(.unspecified)

                subview.place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(size)
                )

                x += size.width + spacing
            }

            y += row.height + rowSpacing
        }
    }

    private func computeRows(
        maxWidth: CGFloat,
        subviews: Subviews
    ) -> [(indices: [Subviews.Index], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Subviews.Index], width: CGFloat, height: CGFloat)] = []

        var currentIndices: [Subviews.Index] = []
        var currentWidth: CGFloat = 0
        var currentHeight: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let proposedWidth = currentIndices.isEmpty
                ? size.width
                : currentWidth + spacing + size.width

            if proposedWidth > maxWidth, !currentIndices.isEmpty {
                rows.append((currentIndices, currentWidth, currentHeight))
                currentIndices = [index]
                currentWidth = size.width
                currentHeight = size.height
            } else {
                currentIndices.append(index)
                currentWidth = proposedWidth
                currentHeight = max(currentHeight, size.height)
            }
        }

        if !currentIndices.isEmpty {
            rows.append((currentIndices, currentWidth, currentHeight))
        }

        return rows
    }
}

struct SlideshowPanelOverlay: View {
    let photos: [PhotoItem]

    private var title: String {
        if photos.count == 1 {
            return photos.first?.filename ?? ""
        }
        return "\(photos.count) images"
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                Color.black

                if photos.count == 1, let photo = photos.first {
                    SlideshowImageView(url: photo.url)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .padding(20)
                } else {
                    let layout = slideLayout(
                        count: photos.count,
                        availableSize: proxy.size,
                        padding: 20,
                        spacing: 14
                    )

                    VStack(spacing: 14) {
                        ForEach(0..<layout.rows, id: \.self) { row in
                            HStack(spacing: 14) {
                                ForEach(0..<layout.columns, id: \.self) { column in
                                    let index = row * layout.columns + column

                                    if index < photos.count {
                                        let photo = photos[index]

                                        SlideshowImageTile(photo: photo)
                                            .frame(width: layout.cellWidth, height: layout.cellHeight)
                                    } else {
                                        Color.clear
                                            .frame(width: layout.cellWidth, height: layout.cellHeight)
                                    }
                                }
                            }
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }

                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(16)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .allowsHitTesting(false)
    }

    private func slideLayout(
        count: Int,
        availableSize: CGSize,
        padding: CGFloat,
        spacing: CGFloat
    ) -> (rows: Int, columns: Int, cellWidth: CGFloat, cellHeight: CGFloat) {
        let columns: Int
        let rows: Int

        switch count {
        case 1:
            columns = 1
            rows = 1
        case 2:
            columns = 2
            rows = 1
        case 3, 4:
            columns = 2
            rows = 2
        default:
            columns = 3
            rows = 2
        }

        let usableWidth = max(availableSize.width - padding * 2 - CGFloat(columns - 1) * spacing, 1)
        let usableHeight = max(availableSize.height - padding * 2 - CGFloat(rows - 1) * spacing, 1)

        return (
            rows,
            columns,
            usableWidth / CGFloat(columns),
            usableHeight / CGFloat(rows)
        )
    }
}

struct SlideshowImageTile: View {
    let photo: PhotoItem

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            SlideshowImageView(url: photo.url)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            Text(photo.filename)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .padding(8)
        }
    }
}

struct SlideshowImageView: View {
    let url: URL

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.black

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            }
        }
        .task(id: url) {
            image = nil
            let requestedURL = url
            let loadedImage = await ImageLoader.shared.fullImage(for: requestedURL)

            guard !Task.isCancelled, requestedURL == url else { return }
            image = loadedImage
        }
    }
}

struct LargeFilePlaceholderView: View {
    let fileSize: String

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.secondary.opacity(0.12))
            VStack(spacing: 2) {
                Image(systemName: "photo")
                    .font(.caption)
                Text(fileSize)
                    .font(.system(size: 7, weight: .medium, design: .monospaced))
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
        }
    }
}

struct CollageCell: View {
    let photo: PhotoItem
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ThumbnailView(url: photo.url, targetSize: CGSize(width: cellWidth * 2, height: cellHeight * 2))
                .frame(width: cellWidth, height: cellHeight)
                .clipped()
                .background(Color.black.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .bottomLeading) {
                    Text(photo.filename)
                        .font(.caption2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(6)
                        .background(.thinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .padding(6)
                }

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .padding(6)
        }
    }
}

struct ThumbnailView: View {
    let url: URL
    let targetSize: CGSize

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.12))
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .onAppear {
            load()
        }
        .onChange(of: url) { _ in
            image = nil
            load()
        }
    }

    private func load() {
        Task {
            image = await ImageLoader.shared.thumbnail(for: url, targetSize: targetSize)
        }
    }
}

struct FullImageView: View {
    enum Scaling {
        case fit
        case fill
    }

    let url: URL
    let scaling: Scaling

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: scaling == .fit ? .fit : .fill)
            } else {
                ZStack {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.10))
                    ProgressView()
                }
            }
        }
        .task(id: url) {
            image = nil
            let requestedURL = url
            let loadedImage = await ImageLoader.shared.fullImage(for: requestedURL)

            guard !Task.isCancelled, requestedURL == url else { return }
            image = loadedImage
        }
    }
}

struct FullPanelImageOverlay: View {
    let url: URL
    let title: String

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                Color.black.opacity(0.78)

                FullImageView(url: url, scaling: .fit)
                    .id(url)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .padding(20)

                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(16)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .allowsHitTesting(false)
    }
}

actor ImageLoader {
    static let shared = ImageLoader()

    private var thumbnailCache: [String: NSImage] = [:]
    private var fullImageCache: [String: NSImage] = [:]

    func thumbnail(for url: URL, targetSize: CGSize) async -> NSImage? {
        let key = "\(url.path)#\(Int(targetSize.width))x\(Int(targetSize.height))"
        if let cached = thumbnailCache[key] {
            return cached
        }

        let image = autoreleasepool { () -> NSImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let maxPixelSize = max(targetSize.width, targetSize.height) * NSScreen.mainBackingScaleFactor
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelSize)
            ]

            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: cgImage, size: .zero)
        }

        if let image {
            thumbnailCache[key] = image
        }

        return image
    }

    func fullImage(for url: URL) async -> NSImage? {
        let key = url.path
        if let cached = fullImageCache[key] {
            return cached
        }

        let image = autoreleasepool { () -> NSImage? in
            NSImage(contentsOf: url)
        }

        if let image {
            // Keep this intentionally small in a first-pass app.
            // A production version should use NSCache with memory pressure handling.
            if fullImageCache.count > 8 {
                fullImageCache.removeAll()
            }
            fullImageCache[key] = image
        }

        return image
    }
}

struct LocalKeyDownMonitor: ViewModifier {
    let handler: (NSEvent) -> NSEvent?
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: handler)
            }
            .onDisappear {
                if let monitor {
                    NSEvent.removeMonitor(monitor)
                }
                monitor = nil
            }
    }
}

extension View {
    func onLocalKeyDown(_ handler: @escaping (NSEvent) -> NSEvent?) -> some View {
        modifier(LocalKeyDownMonitor(handler: handler))
    }
}

private extension NSScreen {
    static var mainBackingScaleFactor: CGFloat {
        NSScreen.main?.backingScaleFactor ?? 2.0
    }
}
