import AppKit
import SwiftUI

struct SettingsSidebar: View {
    @Binding var selection: SettingsCategory?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(SettingsCategory.allCases) { category in
                        SettingsSidebarRow(
                            category: category,
                            isSelected: selection == category,
                            action: { selection = category }
                        )
                    }
                }
                .padding(12)
            }

            SettingsSidebarAppInfo()
                .padding(.horizontal, 12)
                .padding(.bottom, 14)
        }
    }
}

private struct SettingsSidebarRow: View {
    let category: SettingsCategory
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: category.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(nsColor: .controlBackgroundColor),
                                        Color(nsColor: .separatorColor).opacity(0.7)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    }

                Text(category.title)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color(nsColor: .secondarySystemFill) : .clear)
            )
        }
        .buttonStyle(.plain)
        .pointingHandOnHover()
    }
}

private struct SettingsSidebarAppInfo: View {
    private static let websiteURL = URL(string: "https://alxy.ca")!
    private static let projectURL = URL(string: "https://github.com/alexeyalbert/xray")!
    private static let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Xray"
    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    private static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 56, height: 56)

            Text(Self.appName)
                .font(.headline)

            Text("Version \(Self.version) (\(Self.build))")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Made by Alexey Albert")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Link("Website", destination: Self.websiteURL)
                    .pointingHandOnHover()

                Link("GitHub", destination: Self.projectURL)
                    .pointingHandOnHover()
            }
            .font(.caption)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.75))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
    }
}
