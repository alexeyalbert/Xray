//
//  VideoPlaybackViews.swift
//  Xray
//

import AppKit
import AVKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

private struct PlayerLayerView: View {
    let player: AVPlayer?

    var body: some View {
        PlayerLayerRepresentable(player: player)
    }
}

#if os(macOS)
private struct PlayerLayerRepresentable: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> PlayerLayerNSView {
        PlayerLayerNSView()
    }

    func updateNSView(_ nsView: PlayerLayerNSView, context: Context) {
        nsView.playerLayer.player = player
    }
}

private final class PlayerLayerNSView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        layer = playerLayer
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        layer = playerLayer
    }
}
#else
private struct PlayerLayerRepresentable: UIViewRepresentable {
    let player: AVPlayer?

    func makeUIView(context: Context) -> PlayerLayerUIView {
        PlayerLayerUIView()
    }

    func updateUIView(_ uiView: PlayerLayerUIView, context: Context) {
        uiView.playerLayer.player = player
    }
}

private final class PlayerLayerUIView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        playerLayer.videoGravity = .resizeAspect
    }
}
#endif

func videoDisplaySize(for url: URL) async throws -> CGSize? {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    guard let track = tracks.first else { return nil }
    let naturalSize = try await track.load(.naturalSize)
    let transform = try await track.load(.preferredTransform)
    let transformed = naturalSize.applying(transform)
    let displaySize = CGSize(width: abs(transformed.width), height: abs(transformed.height))
    return displaySize == .zero ? nil : displaySize
}

struct LoopingInlineVideoView: View {
    let url: URL
    let aspectRatio: CGFloat
    @State private var player: AVPlayer?
    @State private var setupTask: Task<Void, Never>?
    @State private var endObserver: NSObjectProtocol?

    var body: some View {
        ZStack {
            ShimmerPlaceholderView(cornerRadius: 0, includeBackgroundFill: true)
                .opacity(player == nil ? 1 : 0)

            PlayerLayerView(player: player)
                .opacity(player == nil ? 0 : 1)
        }
            .aspectRatio(aspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .onAppear {
                setupTask?.cancel()
                setupTask = Task {
                    guard !Task.isCancelled else { return }

                    let item = AVPlayerItem(url: url)
                    let player = AVPlayer(playerItem: item)
                    player.isMuted = true
                    player.actionAtItemEnd = .none
                    player.preventsDisplaySleepDuringVideoPlayback = false

                    let observer = NotificationCenter.default.addObserver(
                        forName: .AVPlayerItemDidPlayToEndTime,
                        object: item,
                        queue: .main
                    ) { _ in
                        player.seek(to: .zero)
                        player.play()
                    }

                    await MainActor.run {
                        self.endObserver = observer
                        self.player = player
                        player.play()
                    }
                }
            }
            .onDisappear {
                setupTask?.cancel()
                setupTask = nil
                player?.pause()
                if let endObserver {
                    NotificationCenter.default.removeObserver(endObserver)
                    self.endObserver = nil
                }
                player?.replaceCurrentItem(with: nil)
                player = nil
            }
    }
}

struct FullscreenVideoView: View {
    let url: URL
    let loops: Bool
    let onPlayerChange: (AVPlayer?) -> Void
    @State private var player: AVPlayer?
    @State private var endObserver: NSObjectProtocol?

    var body: some View {
        Group {
            if loops {
                PlayerLayerView(player: player)
            } else {
                VideoPlayer(player: player)
            }
        }
            .onAppear {
                if loops {
                    let item = AVPlayerItem(url: url)
                    let player = AVPlayer(playerItem: item)
                    player.actionAtItemEnd = .none

                    let observer = NotificationCenter.default.addObserver(
                        forName: .AVPlayerItemDidPlayToEndTime,
                        object: item,
                        queue: .main
                    ) { _ in
                        player.seek(to: .zero)
                        player.play()
                    }

                    self.endObserver = observer
                    self.player = player
                    onPlayerChange(player)
                    player.play()
                } else {
                    let player = AVPlayer(url: url)
                    self.player = player
                    onPlayerChange(player)
                    player.play()
                }
            }
            .onDisappear {
                player?.pause()
                onPlayerChange(nil)
                if let endObserver {
                    NotificationCenter.default.removeObserver(endObserver)
                    self.endObserver = nil
                }
                player?.replaceCurrentItem(with: nil)
                player = nil
            }
    }
}

