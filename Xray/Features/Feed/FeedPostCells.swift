//
//  FeedPostCells.swift
//  Xray
//

import Foundation
import SwiftUI

private struct LazyUnloadPostView: View, Equatable {
    let post: Post
    let isLoaded: Bool
    let isVisible: Bool
    let shouldAnimateMediaAppearance: Bool
    let searchDebugContext: SearchDebugContext?
    let onTopicSelected: (String, TopicSearchScope) -> Void
    let onMediaSelected: (SelectedMediaItem) -> Void
    let onFindSimilarImages: (Media) -> Void
    let onPostTemporarilyHidden: (Int) -> Void
    let onPostDeleted: (Int) -> Void
    let onFrameChanged: (Int, CGRect) -> Void

    @State private var measuredHeight: CGFloat?

    static func == (lhs: LazyUnloadPostView, rhs: LazyUnloadPostView) -> Bool {
        lhs.post.id == rhs.post.id
            && lhs.isLoaded == rhs.isLoaded
            && lhs.isVisible == rhs.isVisible
            && lhs.shouldAnimateMediaAppearance == rhs.shouldAnimateMediaAppearance
            && lhs.searchDebugContext == rhs.searchDebugContext
    }

    var body: some View {
        Group {
            if isLoaded || measuredHeight == nil {
                LoadedPostContent(
                    post: post,
                    isVisible: isVisible,
                    shouldAnimateMediaAppearance: shouldAnimateMediaAppearance,
                    searchDebugContext: searchDebugContext,
                    onTopicSelected: onTopicSelected,
                    onMediaSelected: onMediaSelected,
                    onFindSimilarImages: onFindSimilarImages,
                    onPostTemporarilyHidden: onPostTemporarilyHidden,
                    onPostDeleted: onPostDeleted
                )
                .equatable()
            } else {
                UnloadedPostPlaceholder(height: measuredHeight ?? 0)
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { newHeight in
            guard newHeight > 0 else { return }
            if measuredHeight == nil || abs((measuredHeight ?? 0) - newHeight) > 0.5 {
                measuredHeight = newHeight
            }
        }
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named("FeedScroll"))
        } action: { newFrame in
            onFrameChanged(post.id, newFrame)
        }
        .onChange(of: isVisible) { wasVisible, isVisible in
            if wasVisible, !isVisible {
                SharedImagePipeline.pruneThumbnailsFromMemory(for: post.thumbnailCacheURLs)
            }
        }
    }
}

struct FeedPostColumn: View {
    let posts: [Post]
    let columnWidth: CGFloat
    let searchDebugContext: SearchDebugContext?
    let onTopicSelected: (String, TopicSearchScope) -> Void
    let onMediaSelected: (SelectedMediaItem) -> Void
    let onFindSimilarImages: (Media) -> Void
    let onPostTemporarilyHidden: (Int) -> Void
    let onPostDeleted: (Int) -> Void
    let onColumnEndAppeared: () -> Void
    let onFrameChanged: (Int, CGRect) -> Void

    @Environment(FeedViewportState.self) private var feedViewport

    private var loadMoreTriggerPostID: Int? {
        guard !posts.isEmpty else { return nil }
        return posts[max(0, posts.count - 7)].id
    }

    var body: some View {
        LazyVStack(spacing: 12) {
            ForEach(posts, id: \.id) { post in
                let isLoaded = feedViewport.isPostLoaded(post.id)
                LazyUnloadPostView(
                    post: post,
                    isLoaded: isLoaded,
                    isVisible: feedViewport.isPostVisible(post.id),
                    shouldAnimateMediaAppearance: feedViewport.onScreenPostIDs.contains(post.id),
                    searchDebugContext: searchDebugContext,
                    onTopicSelected: onTopicSelected,
                    onMediaSelected: onMediaSelected,
                    onFindSimilarImages: onFindSimilarImages,
                    onPostTemporarilyHidden: onPostTemporarilyHidden,
                    onPostDeleted: onPostDeleted,
                    onFrameChanged: onFrameChanged
                )
                .equatable()
                .onAppear {
                    if post.id == loadMoreTriggerPostID {
                        onColumnEndAppeared()
                    }
                }
            }

            Color.clear
                .frame(height: 1)
                .onAppear(perform: onColumnEndAppeared)
        }
        .frame(width: columnWidth, alignment: .top)
    }
}

// Equatable wrapper around the loaded PostView. Its only inputs are the render-affecting
// post fields/flags, so when the enclosing LazyUnloadPostView re-evaluates for reasons that
// don't affect the post (notably measuredHeight updates during scroll), SwiftUI can skip
// rebuilding the expensive PostView entirely.
private struct LoadedPostContent: View, Equatable {
    let post: Post
    let isVisible: Bool
    let shouldAnimateMediaAppearance: Bool
    let searchDebugContext: SearchDebugContext?
    let onTopicSelected: (String, TopicSearchScope) -> Void
    let onMediaSelected: (SelectedMediaItem) -> Void
    let onFindSimilarImages: (Media) -> Void
    let onPostTemporarilyHidden: (Int) -> Void
    let onPostDeleted: (Int) -> Void

    static func == (lhs: LoadedPostContent, rhs: LoadedPostContent) -> Bool {
        lhs.post.id == rhs.post.id
            && lhs.isVisible == rhs.isVisible
            && lhs.shouldAnimateMediaAppearance == rhs.shouldAnimateMediaAppearance
            && lhs.searchDebugContext == rhs.searchDebugContext
    }

    var body: some View {
        PostView(
            Post: post,
            isVisible: isVisible,
            shouldAnimateMediaAppearance: shouldAnimateMediaAppearance,
            searchDebugContext: searchDebugContext,
            onTopicSelected: onTopicSelected,
            onMediaSelected: onMediaSelected,
            onFindSimilarImages: onFindSimilarImages,
            onPostTemporarilyHidden: onPostTemporarilyHidden,
            onPostDeleted: onPostDeleted
        )
    }
}

private struct UnloadedPostPlaceholder: View {
    let height: CGFloat

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: max(height, 1))
            .contentShape(Rectangle())
    }
}

