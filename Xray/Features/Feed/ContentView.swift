//
//  ContentView.swift
//  Xray
//

import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#endif

struct ContentView: View {
    private static let searchOperatorPanelWidth: CGFloat = SearchToolbarField.controlWidth
    private static let searchResultsBookmarkOrderDefaultsKey = "Search.ResultsUseBookmarkOrder"
    
    @Bindable var importState: ImportState
    @Binding var isShowingSettings: Bool
    let onRebuildDatabaseSchema: () -> Void
    let onResetDatabase: () -> Void
    let onGenerateRemainingEnrichments: () -> Void
    let onRefreshEnrichmentAvailability: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    
    @State private var searchText: String = ""
    @State private var debouncedSearchText: String = ""
    @State private var isSearching: Bool = false
    @State private var searchResults: [Post] = []
    @State private var debounceTask: Task<Void, Never>? = nil
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var searchResourceReleaseTask: Task<Void, Never>? = nil
    @State private var activeSearchID: UUID? = nil
    @State private var searchDiagnostics: SQLiteManager.SearchDiagnostics? = nil
    @State private var searchStartedAt: Date? = nil
    @State private var searchError: String? = nil
    @State private var similarImageSearchMedia: Media? = nil
    @State private var searchModelsAwaitingUserScroll = false
    @State private var unloadSearchModelsWhenScrollSettles = false
    @State private var showImportStatusPopover: Bool = false
    @State private var isSearchPanelActive: Bool = false
    @State private var suppressSearchPanelForNextTextChange: Bool = false
    @State private var searchPanelMinX: CGFloat? = nil
    @State private var searchSelection: TextSelection? = nil
    @FocusState private var isSearchFieldFocused: Bool
    @State private var searchDotCount: Int = 0
    @State private var selectedMedia: SelectedMediaItem? = nil
    @State private var temporarilyHiddenPostIDs: Set<Int> = []
    @State private var feedScrollViewID = UUID()
    @State private var feedViewport = FeedViewportState()
    @State private var accumulatedPostFrames: [Int: CGRect] = [:]
    @State private var frameFlushScheduled = false
    @State private var frameFlushGeneration = 0
    @AppStorage(SQLiteManager.minimumEmbeddingSimilarityDefaultsKey)
    private var minimumEmbeddingSimilarity = SQLiteManager.defaultMinimumEmbeddingSimilarity
    @AppStorage(SQLiteManager.minimumImageEmbeddingSimilarityDefaultsKey)
    private var minimumImageEmbeddingSimilarity = SQLiteManager.defaultMinimumImageEmbeddingSimilarity
    @AppStorage(Self.searchResultsBookmarkOrderDefaultsKey)
    private var searchResultsUseBookmarkOrder = false
    @AppStorage(DebugSettings.showToolbarInfoButtonKey)
    private var showToolbarInfoButton = false
    @FocusState private var isMediaOverlayFocused: Bool
    private let gridSpacing: CGFloat = 12
    private let gridHorizontalPadding: CGFloat = 32
    private let minimumPostColumnWidth: CGFloat = 220
    private let maximumPostColumnWidth: CGFloat = 400
    private let maximumPostColumnCount: Int = 7
    private let postLoadCullMargin: CGFloat = 1_600
    private let postVisibilityCullMargin: CGFloat = 420
    private let postOnScreenCullMargin: CGFloat = 240

    private var isShowingSearchResults: Bool {
        !debouncedSearchText.isEmpty || similarImageSearchMedia != nil
    }

    private var isEnrichmentRunning: Bool {
        importState.isTopicAnnotating
            || importState.isTextEmbeddingGenerating
            || importState.isImageEmbeddingGenerating
    }
    
    var body: some View {
        NavigationStack{
            VStack() {
                let showingPosts: [Post]? = postsForCurrentContext()
                if let posts = showingPosts {
                    GeometryReader { geometry in
                        let gridMetrics = adaptiveGridMetrics(for: geometry.size.width)
                        ScrollView {

                            PostsStaggeredGrid(
                                posts: posts,
                                numColumns: gridMetrics.columnCount,
                                columnWidth: gridMetrics.columnWidth,
                                importState: importState,
                                enableInfiniteScroll: !isShowingSearchResults,
                                searchDebugContext: activeSearchDebugContext,
                                onTopicSelected: { topic, scope in
                                    selectTopicForSearch(topic, scope: scope)
                                },
                                onMediaSelected: { mediaItem in
                                    selectedMedia = mediaItem
                                },
                                onFindSimilarImages: { media in
                                    runSimilarImageSearch(for: media)
                                },
                                onPostTemporarilyHidden: { postID in
                                    temporarilyHidePost(postID)
                                },
                                onPostDeleted: { postID in
                                    importState.posts?.removeAll { $0.id == postID }
                                    searchResults.removeAll { $0.id == postID }
                                },
                                onFrameChanged: { postID, frame in
                                    guard !temporarilyHiddenPostIDs.contains(postID) else { return }
                                    accumulatedPostFrames[postID] = frame
                                    scheduleFrameFlush(viewportHeight: geometry.size.height)
                                }
                            )
                            .equatable()
                            .padding(.vertical, 4)
                            
                            if !isShowingSearchResults {
                                if importState.allPostsLoaded {
                                    Text("All posts loaded.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else if importState.isLoading {
                                    ProgressView("Loading more...")
                                }
                            } else if posts.isEmpty && !isSearching {
                                Text("No results")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .coordinateSpace(name: "FeedScroll")
                        .onScrollPhaseChange { _, newPhase in
                            handleSearchResultsScrollPhase(newPhase)
                        }
                        .scrollDisabled(isEnrichmentRunning)
                        .id(feedScrollViewID)
                        .environment(feedViewport)
                    }
                } else if let error = importState.loadError {
                    Text("Error loading posts: \(error)")
                        .foregroundStyle(.red)
                } else if importState.isLoading {
                    ProgressView("Loading...")
                }
            }
            .overlay(alignment: .bottom) {
                SearchStatusCapsule(isVisible: isSearching, dotCount: searchDotCount)
                    .padding(.bottom, 18)
            }
            .overlay {
                if let selectedMedia {
                    let selectedMediaValue = selectedMedia.media
                    let selectedSaveContext = selectedMedia.saveContext
                    ExpandedMediaOverlay(
                        media: selectedMediaValue,
                        saveContext: selectedSaveContext,
                        backdropOpacity: colorScheme == .dark ? 0.42 : 0.34
                    ) {
                        self.selectedMedia = nil
                    }
                    .focusable()
                    .focusEffectDisabled()
                    .focused($isMediaOverlayFocused)
                    .onAppear {
                        isMediaOverlayFocused = true
                    }
                    .onDisappear {
                        isMediaOverlayFocused = false
                    }
                    .onKeyPress(.escape) {
                        self.selectedMedia = nil
                        return .handled
                    }
                    .onExitCommand {
                        self.selectedMedia = nil
                    }
                    .zIndex(10)
                }
            }
#if os(macOS)
            .overlay(alignment: .top) {
                searchOperatorPanel
            }
#endif
            .overlay {
                ZStack(alignment: .bottom) {
                    Color.black
                        .opacity(isEnrichmentRunning ? 0.14 : 0)
                        .ignoresSafeArea()
                        .allowsHitTesting(isEnrichmentRunning)
                        .accessibilityHidden(true)

                    EnrichmentProgressIndicator(importState: importState)
                        .padding(.bottom, 18)
                }
                .animation(.easeInOut(duration: 0.3), value: isEnrichmentRunning)
            }
#if !os(macOS)
            .searchable(text: $searchText, placement: .toolbarPrincipal, prompt: "Search, emb:, --emb:, --term, !NULL, id:, topic:, p_topic:, s_topic:, user:, &&, ||")
#endif
            .task(id: isSearching) {
                guard isSearching else {
                    searchDotCount = 0
                    return
                }
                
                searchDotCount = 1
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    if Task.isCancelled { return }
                    searchDotCount = (searchDotCount + 1) % 4
                }
            }
            .sheet(isPresented: $isShowingSettings) {
                SettingsView(
                    importState: importState,
                    onRebuildDatabaseSchema: onRebuildDatabaseSchema,
                    onResetDatabase: onResetDatabase
                )
                    .frame(width: SettingsView.modalSize.width, height: SettingsView.modalSize.height)
            }
            .onChange(of: isShowingSettings) { _, isShowing in
                if !isShowing {
                    onRefreshEnrichmentAvailability()
                }
            }
            .onChange(of: searchText) { _, newValue in
                if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    similarImageSearchMedia = nil
                }
#if os(macOS)
                if suppressSearchPanelForNextTextChange {
                    suppressSearchPanelForNextTextChange = false
                } else {
                    openSearchPanelIfCurrentTokenLooksLikeOperator(in: newValue)
                }
#endif
                // Debounce: schedule a search 300ms after the last keystroke, cancel previous
                debounceTask?.cancel()
                let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if value.isEmpty, similarImageSearchMedia == nil {
                    endSearch(clearSearchText: false)
                    return
                }
                debounceTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    if Task.isCancelled { return }
                    debouncedSearchText = value
                    debounceTask = nil
                }
            }
            .onChange(of: debouncedSearchText) { _, value in
                guard !value.isEmpty else { return }
                runSearch(for: value)
            }
            .onChange(of: minimumEmbeddingSimilarity) { _, _ in
                guard !debouncedSearchText.isEmpty, importState.searchMode != .keyword else { return }
                runSearch(for: debouncedSearchText)
            }
            .onChange(of: minimumImageEmbeddingSimilarity) { _, _ in
                guard !debouncedSearchText.isEmpty, importState.searchMode != .keyword else { return }
                runSearch(for: debouncedSearchText)
            }
            .onChange(of: searchResultsUseBookmarkOrder) { _, _ in
                guard !debouncedSearchText.isEmpty else { return }
                runSearch(for: debouncedSearchText)
            }
            .onDisappear {
                endSearch(clearSearchText: false, resetScroll: false)
            }
            .toolbar {
#if os(macOS)
                if importState.hasPendingEnrichmentWork || importState.isEnrichmentQueueRunning {
                    ToolbarItem(placement: .navigation) {
                        Button(action: onGenerateRemainingEnrichments) {
                            Image(systemName: "sparkles.rectangle.stack")
                                .foregroundStyle(importState.isEnrichmentQueueRunning ? Color.accentColor : Color.secondary)
                        }
                        .disabled(
                            importState.isDatabaseImporting
                                || importState.isEnrichmentQueueRunning
                                || (importState.browserImportActiveSessionID != nil && !importState.browserImportCompleted)
                        )
                        .help(importState.isEnrichmentQueueRunning ? "Generating Remaining Topics & Embeddings" : "Generate Remaining Topics & Embeddings")
                    }
                }

                ToolbarItem(placement: .principal) {
                    SearchToolbarField(
                        searchText: $searchText,
                        selection: $searchSelection,
                        focused: $isSearchFieldFocused,
                        imageSearchMedia: similarImageSearchMedia,
                        isPanelActive: isSearchPanelActive,
                        onClearImageSearch: clearSimilarImageSearch,
                        onEscape: { closeSearchPanel() },
                        onSubmit: { closeSearchPanel(keepSearchFocus: true) }
                    )
                }

                if #available(macOS 26.0, *) {
                    ToolbarSpacer(.fixed, placement: .principal)
                } else {
                    ToolbarItem(placement: .principal) {
                        Color.clear
                            .frame(width: 8, height: 1)
                            .accessibilityHidden(true)
                    }
                }

                ToolbarItem(placement: .principal) {
                    Button {
                        toggleSearchPanel()
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundStyle(isSearchPanelActive ? Color.accentColor : Color.secondary)
                    }
                    .help("Search Operators & Embedding Threshold")
                }

                ToolbarItem(placement: .principal) {
                    Button {
                        searchResultsUseBookmarkOrder.toggle()
                    } label: {
                        Image(systemName: searchResultsUseBookmarkOrder ? "bookmark.fill" : "sparkle.magnifyingglass")
                            .foregroundStyle(searchResultsUseBookmarkOrder ? Color.accentColor : Color.secondary)
                    }
                    .help(searchResultsUseBookmarkOrder ? "Search Results: Bookmark Order" : "Search Results: Hybrid Rank")
                }
#endif
                ToolbarItemGroup(placement: .primaryAction) {
                    if showToolbarInfoButton {
                        Button {
                            showImportStatusPopover.toggle()
                        } label: {
                            Image(systemName: "info.circle")
                        }
                        .popover(isPresented: $showImportStatusPopover) {
                            infoPopoverContent
                        }
                        .help(debouncedSearchText.isEmpty ? "Import & Database Status" : "Current Search Details")
                    }
                }
            }
            //            .toolbar {
            //                ToolbarItem(placement: .principal) {
            //                    SearchBar()
            //                        .frame(width: 400)
            //                }
            //            }
        }
    }

    private var infoPopoverContent: some View {
        SearchAndImportStatusView(
            importState: importState,
            query: debouncedSearchText,
            mode: importState.searchMode,
            resultCount: searchResults.count,
            isSearching: isSearching,
            startedAt: searchStartedAt,
            diagnostics: searchDiagnostics,
            error: searchError,
            usesBookmarkOrder: searchResultsUseBookmarkOrder
        )
        .frame(width: debouncedSearchText.isEmpty ? 360 : 500)
        .frame(maxHeight: 680)
    }

#if os(macOS)
    @ViewBuilder
    private var searchOperatorPanel: some View {
        if isSearchPanelActive {
            GeometryReader { proxy in
                ZStack(alignment: .top) {
                    // Transparent click-catcher: the search field lives in the title
                    // bar (above this content), so clicking anywhere in the content
                    // outside the panel dismisses it.
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { closeSearchPanel() }

                    SearchOperatorDropdown(
                        searchText: $searchText,
                        selection: $searchSelection,
                        searchMode: importState.searchMode,
                        onInsert: {
                            focusSearchField()
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .offset(x: searchPanelHorizontalOffset(in: proxy.size.width), y: 6)
                    .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
                }
            }
            .zIndex(8)
            .onAppear {
                updateSearchPanelAnchor()
            }
        }
    }

    private func openSearchPanel() {
        presentSearchPanel(focusSearchField: true)
    }

    private func presentSearchPanel(focusSearchField shouldFocusSearchField: Bool) {
        updateSearchPanelAnchor()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
            isSearchPanelActive = true
        }
        if shouldFocusSearchField {
            focusSearchField()
        }
    }

    private func openSearchPanelIfCurrentTokenLooksLikeOperator(in query: String) {
        guard !isSearchPanelActive, currentSearchToken(in: query).looksLikeSearchOperator else {
            return
        }
        presentSearchPanel(focusSearchField: false)
    }

    private func currentSearchToken(in query: String) -> String {
        guard let last = query.split(separator: " ", omittingEmptySubsequences: false).last else {
            return ""
        }
        return String(last)
    }

    /// Focuses the toolbar search field and shows the caret. `@FocusState` is
    /// unreliable for toolbar-hosted fields, so we also make the underlying
    /// NSTextField the window's first responder via AppKit.
    private func focusSearchField() {
        isSearchFieldFocused = true
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow
                ?? NSApp.mainWindow
                ?? NSApp.windows.first(where: { $0.isVisible }) else { return }
            let roots = [window.contentView?.superview, window.contentView].compactMap { $0 }
            for root in roots {
                if let field = Self.searchTextField(in: root) {
                    window.makeFirstResponder(field)
                    updateSearchPanelAnchor()
                    return
                }
            }
        }
    }

    private func searchPanelHorizontalOffset(in contentWidth: CGFloat) -> CGFloat {
        let centeredMinX = ((contentWidth - Self.searchOperatorPanelWidth) / 2).rounded(.towardZero)
        guard let searchPanelMinX else { return centeredMinX }
        let maxMinX = max(0, contentWidth - Self.searchOperatorPanelWidth)
        return min(max(searchPanelMinX, 0), maxMinX)
    }

    private func updateSearchPanelAnchor() {
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow
                ?? NSApp.mainWindow
                ?? NSApp.windows.first(where: { $0.isVisible }),
                  let contentView = window.contentView else { return }

            let roots = [contentView.superview, contentView].compactMap { $0 }
            for root in roots {
                guard let field = Self.searchTextField(in: root) else { continue }
                let contentFrameInWindow = contentView.convert(contentView.bounds, to: nil)
                let anchorView = Self.searchToolbarContainer(for: field) ?? field
                let anchorFrameInWindow = anchorView.convert(anchorView.bounds, to: nil)
                searchPanelMinX = anchorFrameInWindow.minX - contentFrameInWindow.minX
                return
            }
        }
    }

    private static func searchTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable, field.placeholderString == "Search" {
            return field
        }
        for subview in view.subviews {
            if let found = searchTextField(in: subview) {
                return found
            }
        }
        return nil
    }

    private static func searchToolbarContainer(for field: NSTextField) -> NSView? {
        var candidate: NSView? = field
        var bestMatch: NSView?
        let tolerance: CGFloat = 0.5

        while let view = candidate {
            if abs(view.bounds.width - SearchToolbarField.controlWidth) <= tolerance {
                bestMatch = view
            }
            candidate = view.superview
        }

        return bestMatch
    }

    private func toggleSearchPanel() {
        if isSearchPanelActive {
            closeSearchPanel()
        } else {
            openSearchPanel()
        }
    }

    private func closeSearchPanel(keepSearchFocus: Bool = false) {
        withAnimation(.spring(response: 0.26, dampingFraction: 0.88)) {
            isSearchPanelActive = false
        }
        if keepSearchFocus {
            focusSearchField()
        } else {
            isSearchFieldFocused = false
        }
    }
#endif

    private var activeSearchDebugContext: SearchDebugContext? {
        if let similarImageSearchMedia {
            return SearchDebugContext(similarImageMedia: similarImageSearchMedia)
        }
        let trimmed = debouncedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return SearchDebugContext(query: trimmed, mode: importState.searchMode)
    }

    private func selectTopicForSearch(_ topic: String, scope: TopicSearchScope) {
        let query = topicSearchQuery(for: topic, scope: scope)
#if os(macOS)
        if isSearchPanelActive {
            closeSearchPanel()
        }
        guard searchText != query else {
            suppressSearchPanelForNextTextChange = false
            return
        }
        suppressSearchPanelForNextTextChange = true
#endif
        searchText = query
    }

    private func runSearch(for value: String) {
        guard !value.isEmpty else {
            endSearch(clearSearchText: false)
            return
        }
        searchTask?.cancel()
        resetFeedScrollPosition()
        searchModelsAwaitingUserScroll = false
        unloadSearchModelsWhenScrollSettles = false
        let searchID = UUID()
        activeSearchID = searchID
        let pendingResourceRelease = searchResourceReleaseTask
        searchResourceReleaseTask = nil
        searchTask = Task {
            await pendingResourceRelease?.value
            if Task.isCancelled { return }
            // Persist last query for context menu comparison
            UserDefaults.standard.set(value, forKey: "LastSearchQuery")
            await MainActor.run {
                isSearching = true
                searchResults = []
                searchDiagnostics = nil
                searchStartedAt = Date()
                searchError = nil
            }
            do {
                print("[Search] start: query='\(value)' mode=\(importState.searchMode.rawValue)")
                let execution = try await sqliteManager.searchPostsWithDiagnostics(query: value, mode: importState.searchMode, limit: Int.max) { partialResults in
                    if Task.isCancelled { return }
                    await MainActor.run {
                        guard self.activeSearchID == searchID else { return }
                        self.searchResults = orderedSearchResults(partialResults)
                    }
                }
                let results = execution.posts
                print("[Search] \(importState.searchMode.rawValue) results=\(results.count)")
                if Task.isCancelled { return }
                let didApplyResults = await MainActor.run {
                    guard self.activeSearchID == searchID else { return false }
                    self.searchResults = orderedSearchResults(results)
                    self.searchDiagnostics = execution.diagnostics
                    self.isSearching = false
                    self.activeSearchID = nil
                    self.searchModelsAwaitingUserScroll = !results.isEmpty
                    self.searchTask = nil
                    return true
                }
                guard didApplyResults else { return }
                if results.isEmpty {
                    await EmbeddingsManager.unloadAll()
                }
                print("[Search] done: merged count=\(results.count)")
            } catch {
                if Task.isCancelled { return }
                let didApplyError = await MainActor.run {
                    guard self.activeSearchID == searchID else { return false }
                    self.searchResults = []
                    self.isSearching = false
                    self.activeSearchID = nil
                    self.searchError = error.localizedDescription
                    self.searchTask = nil
                    return true
                }
                guard didApplyError else { return }
                await EmbeddingsManager.unloadAll()
                print("[Search] error: \(error)")
            }
        }
    }

    private func runSimilarImageSearch(for media: Media) {
        debounceTask?.cancel()
        searchTask?.cancel()
        resetFeedScrollPosition()
        searchModelsAwaitingUserScroll = false
        unloadSearchModelsWhenScrollSettles = false
#if os(macOS)
        if isSearchPanelActive {
            closeSearchPanel()
        }
#endif

        let searchID = UUID()
        activeSearchID = searchID
        similarImageSearchMedia = media
        searchText = ""
        debouncedSearchText = ""
        let pendingResourceRelease = searchResourceReleaseTask
        searchResourceReleaseTask = nil
        searchTask = Task {
            await pendingResourceRelease?.value
            if Task.isCancelled { return }
            await MainActor.run {
                isSearching = true
                searchResults = []
                searchDiagnostics = nil
                searchStartedAt = Date()
                searchError = nil
            }
            // Give SwiftUI a render opportunity before image decoding/model work starts.
            await Task.yield()
            do {
                let results = try await sqliteManager.searchPostsBySimilarImage(media: media)
                if Task.isCancelled { return }
                let didApplyResults = await MainActor.run {
                    guard activeSearchID == searchID else { return false }
                    searchResults = results
                    isSearching = false
                    activeSearchID = nil
                    searchModelsAwaitingUserScroll = !results.isEmpty
                    searchTask = nil
                    return true
                }
                guard didApplyResults else { return }
                if results.isEmpty {
                    await EmbeddingsManager.unloadAll()
                }
            } catch {
                if Task.isCancelled { return }
                let didApplyError = await MainActor.run {
                    guard activeSearchID == searchID else { return false }
                    searchResults = []
                    isSearching = false
                    activeSearchID = nil
                    searchError = error.localizedDescription
                    searchTask = nil
                    return true
                }
                guard didApplyError else { return }
                await EmbeddingsManager.unloadAll()
            }
        }
    }

    private func clearSimilarImageSearch() {
        endSearch(clearSearchText: true)
    }

    private func endSearch(clearSearchText: Bool, resetScroll: Bool = true) {
        let thumbnailURLs = searchResults.flatMap(\.thumbnailCacheURLs)

        debounceTask?.cancel()
        debounceTask = nil
        searchTask?.cancel()
        searchTask = nil
        activeSearchID = nil

        if clearSearchText, !searchText.isEmpty {
            searchText = ""
        }
        debouncedSearchText = ""
        similarImageSearchMedia = nil
        searchResults = []
        searchDiagnostics = nil
        searchStartedAt = nil
        searchError = nil
        isSearching = false
        searchModelsAwaitingUserScroll = false
        unloadSearchModelsWhenScrollSettles = false

        if resetScroll {
            resetFeedScrollPosition()
        }
        SharedImagePipeline.pruneThumbnailsFromMemory(for: thumbnailURLs)

        searchResourceReleaseTask?.cancel()
        searchResourceReleaseTask = Task {
            await releaseSearchResources()
        }
    }

    private func releaseSearchResources() async {
        async let unloadModels: Void = EmbeddingsManager.unloadAll()
        async let releaseIndex: Void = sqliteManager.releaseTextEmbeddingIndex()
        _ = await (unloadModels, releaseIndex)
    }

    private func resetFeedScrollPosition() {
        // Recreating the SwiftUI scroll container gives each feed/search context
        // a fresh, top-aligned scroll position without manipulating NSScrollView.
        frameFlushGeneration += 1
        frameFlushScheduled = false
        accumulatedPostFrames.removeAll(keepingCapacity: true)
        feedViewport = FeedViewportState()
        feedScrollViewID = UUID()
    }

    private func handleSearchResultsScrollPhase(_ phase: ScrollPhase) {
        if phase == .interacting,
           isShowingSearchResults,
           !isSearching,
           searchModelsAwaitingUserScroll {
            searchModelsAwaitingUserScroll = false
            unloadSearchModelsWhenScrollSettles = true
            return
        }

        guard phase == .idle, unloadSearchModelsWhenScrollSettles else { return }
        unloadSearchModelsWhenScrollSettles = false
        Task {
            await EmbeddingsManager.unloadAll()
        }
    }

    private func orderedSearchResults(_ posts: [Post]) -> [Post] {
        guard searchResultsUseBookmarkOrder else { return posts }
        return posts.sorted(by: bookmarkOrderPrecedes)
    }

    private func bookmarkOrderPrecedes(_ lhs: Post, _ rhs: Post) -> Bool {
        let lhsGeneration = lhs.bookmark_import_generation ?? 0
        let rhsGeneration = rhs.bookmark_import_generation ?? 0
        if lhsGeneration != rhsGeneration {
            return lhsGeneration > rhsGeneration
        }

        let lhsOrder = lhs.bookmark_order ?? Int.max
        let rhsOrder = rhs.bookmark_order ?? Int.max
        if lhsOrder != rhsOrder {
            return lhsOrder < rhsOrder
        }

        if lhs.created_at != rhs.created_at {
            return lhs.created_at > rhs.created_at
        }

        return lhs.id > rhs.id
    }
}

#if os(macOS)
@MainActor
#endif

private extension ContentView {
    func adaptiveGridMetrics(for availableWidth: CGFloat) -> (columnCount: Int, columnWidth: CGFloat) {
        let contentWidth = max(0, availableWidth - gridHorizontalPadding)
        let uncappedColumnCount = max(1, Int((contentWidth + gridSpacing) / (minimumPostColumnWidth + gridSpacing)))
        let columnCount = min(maximumPostColumnCount, uncappedColumnCount)
        let totalSpacing = CGFloat(max(0, columnCount - 1)) * gridSpacing
        let fillWidth = max(1, (contentWidth - totalSpacing) / CGFloat(columnCount))
        return (columnCount, min(maximumPostColumnWidth, fillWidth))
    }

    func postsForCurrentContext() -> [Post]? {
        if similarImageSearchMedia != nil {
            return searchResults.filter { !temporarilyHiddenPostIDs.contains($0.id) }
        }
        if debouncedSearchText.isEmpty {
            return importState.posts?.filter { !temporarilyHiddenPostIDs.contains($0.id) }
        }

        return searchResults.filter { !temporarilyHiddenPostIDs.contains($0.id) }
    }

    func temporarilyHidePost(_ postID: Int) {
        temporarilyHiddenPostIDs.insert(postID)
        accumulatedPostFrames.removeValue(forKey: postID)
        feedViewport.loadedPostIDs.remove(postID)
        feedViewport.visiblePostIDs.remove(postID)
        feedViewport.onScreenPostIDs.remove(postID)
    }

    func scheduleFrameFlush(viewportHeight: CGFloat) {
        guard !frameFlushScheduled else { return }
        frameFlushScheduled = true
        let generation = frameFlushGeneration
        Task { @MainActor in
            guard generation == frameFlushGeneration else { return }
            frameFlushScheduled = false
            let frames = accumulatedPostFrames
            handlePostFramePreferenceChange(
                frames: frames,
                viewportHeight: viewportHeight
            )
        }
    }

    func handlePostFramePreferenceChange(
        frames: [Int: CGRect],
        viewportHeight: CGFloat
    ) {
        let nextLoadedPostIDs = bufferedPostIDs(
            from: frames,
            viewportHeight: viewportHeight,
            margin: postLoadCullMargin
        )
        let nextVisiblePostIDs = bufferedVisiblePostIDs(
            from: frames,
            viewportHeight: viewportHeight
        )
        let nextOnScreenPostIDs = bufferedPostIDs(
            from: frames,
            viewportHeight: viewportHeight,
            margin: postOnScreenCullMargin
        )

        if nextLoadedPostIDs == feedViewport.loadedPostIDs
            && nextVisiblePostIDs == feedViewport.visiblePostIDs
            && nextOnScreenPostIDs == feedViewport.onScreenPostIDs {
            return
        }

        updateViewportWindows(
            from: frames,
            viewportHeight: viewportHeight
        )
    }

    func updateViewportWindows(
        from frames: [Int: CGRect],
        viewportHeight: CGFloat
    ) {
        let nextLoadedPostIDs = bufferedPostIDs(
            from: frames,
            viewportHeight: viewportHeight,
            margin: postLoadCullMargin
        )
        let nextVisiblePostIDs = bufferedVisiblePostIDs(
            from: frames,
            viewportHeight: viewportHeight
        )
        let nextOnScreenPostIDs = bufferedPostIDs(
            from: frames,
            viewportHeight: viewportHeight,
            margin: postOnScreenCullMargin
        )

        feedViewport.hasEstablishedLoadWindow = true
        if nextLoadedPostIDs != feedViewport.loadedPostIDs {
            feedViewport.loadedPostIDs = nextLoadedPostIDs
        }
        if nextVisiblePostIDs != feedViewport.visiblePostIDs {
            feedViewport.visiblePostIDs = nextVisiblePostIDs
        }
        if nextOnScreenPostIDs != feedViewport.onScreenPostIDs {
            feedViewport.onScreenPostIDs = nextOnScreenPostIDs
        }
    }

    func bufferedVisiblePostIDs(from frames: [Int: CGRect], viewportHeight: CGFloat) -> Set<Int> {
        bufferedPostIDs(
            from: frames,
            viewportHeight: viewportHeight,
            margin: postVisibilityCullMargin
        )
    }

    func bufferedPostIDs(from frames: [Int: CGRect], viewportHeight: CGFloat, margin: CGFloat) -> Set<Int> {
        let minimumY = -margin
        let maximumY = viewportHeight + margin

        return Set(
            frames.compactMap { postID, frame in
                guard frame.maxY > minimumY, frame.minY < maximumY else {
                    return nil
                }
                return postID
            }
        )
    }

    
    func topicSearchQuery(for topic: String, scope: TopicSearchScope) -> String {
        let operatorToken = scope == .primary ? "p_topic" : "s_topic"
        return "\(operatorToken):\(dorkValue(for: topic))"
    }

    func dorkValue(for value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains(where: \.isWhitespace) else { return trimmed }
        return "`\(trimmed)`"
    }
}

