import Foundation
import Testing
@testable import Xray

@Suite("Media viewer navigation")
struct MediaViewerNavigationTests {
    @Test("Moves through a media gallery and stops at its boundaries")
    func movesWithinGalleryBounds() throws {
        var media: [Media] = []
        for index in 1...3 {
            let thumbnailURL = try #require(URL(string: "https://example.com/thumbnail-\(index).jpg"))
            let originalURL = try #require(URL(string: "https://example.com/original-\(index).jpg"))
            media.append(Media(
                type: "photo",
                thumbnail: thumbnailURL,
                original: originalURL
            ))
        }
        let items = media.enumerated().map { index, media in
            MediaViewerItem(
                media: media,
                saveContext: MediaSaveContext(
                    username: "example",
                    tweetID: "42",
                    scope: "image",
                    index: index + 1
                )
            )
        }
        let initialSelection = SelectedMediaItem(items: items, selectedIndex: 1)

        let previousSelection = try #require(initialSelection.moving(by: -1))
        let nextSelection = try #require(initialSelection.moving(by: 1))

        #expect(previousSelection.media.id == media[0].id)
        #expect(previousSelection.saveContext?.index == 1)
        #expect(nextSelection.media.id == media[2].id)
        #expect(nextSelection.saveContext?.index == 3)
        #expect(previousSelection.moving(by: -1) == nil)
        #expect(nextSelection.moving(by: 1) == nil)
    }
}
