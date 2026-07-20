import Foundation
import SwiftUI

@Observable
final class AppModel {
    let importState = ImportState()
    var browserImportReceiver: BrowserImportReceiver?

    init() {
        // Expand the shared URL cache to reduce redundant image fetches
        // Defaults are small; bump to ~64MB memory / ~512MB disk for thumbnails/originals
        let mem = 64 * 1024 * 1024
        let disk = 512 * 1024 * 1024
        URLCache.shared = URLCache(memoryCapacity: mem, diskCapacity: disk)

        SharedImagePipeline.configureKingfisherCaching()
    }
}
