//  SearchDebugContext.swift
//  Xray
//

import Foundation

struct SearchDebugContext: Equatable {
    let query: String?
    let mode: SearchMode?
    let similarImageMedia: Media?

    init(query: String, mode: SearchMode) {
        self.query = query
        self.mode = mode
        self.similarImageMedia = nil
    }

    init(similarImageMedia: Media) {
        self.query = nil
        self.mode = nil
        self.similarImageMedia = similarImageMedia
    }

    var identity: String {
        if let similarImageMedia {
            return "similar-image|\(similarImageMedia.original.absoluteString)"
        }
        return "query|\(mode?.rawValue ?? "")|\(query ?? "")"
    }

    static func == (lhs: SearchDebugContext, rhs: SearchDebugContext) -> Bool {
        lhs.identity == rhs.identity
    }
}
