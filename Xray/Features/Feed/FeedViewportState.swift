//
//  FeedViewportState.swift
//  Xray
//

import Observation

@Observable
final class FeedViewportState {
    var loadedPostIDs: Set<Int> = []
    var visiblePostIDs: Set<Int> = []
    var onScreenPostIDs: Set<Int> = []
    // False until the first viewport pass; avoids treating an empty set as "load all".
    var hasEstablishedLoadWindow: Bool = false

    func isPostLoaded(_ postID: Int) -> Bool {
        !hasEstablishedLoadWindow
            || loadedPostIDs.contains(postID)
    }

    func isPostVisible(_ postID: Int) -> Bool {
        visiblePostIDs.contains(postID)
    }
}

