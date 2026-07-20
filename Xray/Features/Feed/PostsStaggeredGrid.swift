//
//  PostsStaggeredGrid.swift
//  Xray
//

import SwiftUI

struct PostsStaggeredGrid: View, Equatable {
    var posts: [Post]
    var numColumns: Int
    var columnWidth: CGFloat
    var importState: ImportState
    var enableInfiniteScroll: Bool = true
    var searchDebugContext: SearchDebugContext? = nil
    var onTopicSelected: (String, TopicSearchScope) -> Void = { _, _ in }
    var onMediaSelected: (SelectedMediaItem) -> Void = { _ in }
    var onFindSimilarImages: (Media) -> Void = { _ in }
    var onPostTemporarilyHidden: (Int) -> Void = { _ in }
    var onPostDeleted: (Int) -> Void = { _ in }
    var onFrameChanged: (Int, CGRect) -> Void = { _, _ in }
    @State private var lastLoadRequestPostCount: Int = -1
    @State private var postsByColumn: [[Post]] = []
    @State private var partitionedPostIDs: [Int] = []
    @State private var partitionedColumnCount: Int = 0

    static func == (lhs: PostsStaggeredGrid, rhs: PostsStaggeredGrid) -> Bool {
        lhs.numColumns == rhs.numColumns
            && lhs.columnWidth == rhs.columnWidth
            && lhs.enableInfiniteScroll == rhs.enableInfiniteScroll
            && lhs.searchDebugContext == rhs.searchDebugContext
            && lhs.posts.count == rhs.posts.count
            && lhs.posts.first?.id == rhs.posts.first?.id
            && lhs.posts.last?.id == rhs.posts.last?.id
    }

    private var partitionKey: String {
        "\(searchDebugContext?.identity ?? "feed")|\(numColumns)|\(posts.count)|\(posts.first?.id ?? 0)|\(posts.last?.id ?? 0)"
    }

    private func synchronizePostColumns() {
        let columnCount = max(1, numColumns)
        let canAppendIncrementally = partitionedColumnCount == columnCount
            && posts.count >= partitionedPostIDs.count
            && posts.prefix(partitionedPostIDs.count).enumerated().allSatisfy { index, post in
                post.id == partitionedPostIDs[index]
            }

        if canAppendIncrementally {
            let startIndex = partitionedPostIDs.count
            if startIndex < posts.count {
                var additions = [[Post]](repeating: [], count: columnCount)
                for index in startIndex..<posts.count {
                    additions[index % columnCount].append(posts[index])
                }
                for columnIndex in additions.indices where !additions[columnIndex].isEmpty {
                    postsByColumn[columnIndex].append(contentsOf: additions[columnIndex])
                }
            }
        } else {
            var columns = [[Post]](repeating: [], count: columnCount)
            for index in posts.indices {
                columns[index % columnCount].append(posts[index])
            }
            postsByColumn = columns
        }

        partitionedPostIDs = posts.map(\.id)
        partitionedColumnCount = columnCount
    }

    init(
        posts: [Post],
        numColumns: Int,
        columnWidth: CGFloat,
        importState: ImportState,
        enableInfiniteScroll: Bool = true,
        searchDebugContext: SearchDebugContext? = nil,
        onTopicSelected: @escaping (String, TopicSearchScope) -> Void = { _, _ in },
        onMediaSelected: @escaping (SelectedMediaItem) -> Void = { _ in },
        onFindSimilarImages: @escaping (Media) -> Void = { _ in },
        onPostTemporarilyHidden: @escaping (Int) -> Void = { _ in },
        onPostDeleted: @escaping (Int) -> Void = { _ in },
        onFrameChanged: @escaping (Int, CGRect) -> Void = { _, _ in }
    ) {
        self.posts = posts
        self.numColumns = max(1, numColumns)
        self.columnWidth = columnWidth
        self.importState = importState
        self.enableInfiniteScroll = enableInfiniteScroll
        self.searchDebugContext = searchDebugContext
        self.onTopicSelected = onTopicSelected
        self.onMediaSelected = onMediaSelected
        self.onFindSimilarImages = onFindSimilarImages
        self.onPostTemporarilyHidden = onPostTemporarilyHidden
        self.onPostDeleted = onPostDeleted
        self.onFrameChanged = onFrameChanged
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(0..<postsByColumn.count, id: \.self) { columnIndex in
                FeedPostColumn(
                    posts: postsByColumn[columnIndex],
                    columnWidth: columnWidth,
                    searchDebugContext: searchDebugContext,
                    onTopicSelected: onTopicSelected,
                    onMediaSelected: onMediaSelected,
                    onFindSimilarImages: onFindSimilarImages,
                    onPostTemporarilyHidden: onPostTemporarilyHidden,
                    onPostDeleted: onPostDeleted,
                    onColumnEndAppeared: requestMorePostsIfNeeded,
                    onFrameChanged: onFrameChanged
                )
            }
        }
        .padding(.horizontal)
        .frame(maxWidth: .infinity, alignment: .center)
        .onChange(of: partitionKey, initial: true) { _, _ in
            synchronizePostColumns()
        }
    }
    
    private func requestMorePostsIfNeeded() {
        guard enableInfiniteScroll,
              !importState.isLoading,
              !importState.allPostsLoaded,
              lastLoadRequestPostCount != posts.count else {
            return
        }
        
        lastLoadRequestPostCount = posts.count
        importState.loadMorePosts?()
    }
}

