import Foundation

enum TopicDisplayFormatter {
    private static let wordNames: [String: String] = [
        "ai": "AI",
        "api": "API",
        "ar": "AR",
        "chatgpt": "ChatGPT",
        "cpu": "CPU",
        "css": "CSS",
        "gpt": "GPT",
        "gpu": "GPU",
        "github": "GitHub",
        "html": "HTML",
        "ios": "iOS",
        "ipad": "iPad",
        "ipados": "iPadOS",
        "iphone": "iPhone",
        "json": "JSON",
        "llm": "LLM",
        "macos": "macOS",
        "ml": "ML",
        "openai": "OpenAI",
        "sdk": "SDK",
        "sql": "SQL",
        "sqlite": "SQLite",
        "swiftui": "SwiftUI",
        "ui": "UI",
        "ux": "UX",
        "visionos": "visionOS",
        "vr": "VR",
        "watchos": "watchOS",
        "xr": "XR",
        "xcode": "Xcode",
        "lgbt": "LGBT",
        "lgbtq": "LGBTQ",
        "lgbtqia": "LGBTQIA",
        "lgbtqia+": "LGBTQIA+",
        "3d": "3D",
        "2d": "2D",
        "cli": "CLI",
        "glp-1": "GLP-1",
        "nvidia": "NVIDIA",
        "opengl": "OpenGL",
        "tensorflow": "TensorFlow",
        "pytorch": "PyTorch",
        "cbt": "CBT",
        "spacex": "SpaceX",
        "vision os": "Vision OS",
        "ipo": "IPO",
        "cs": "CS",
        "iss": "ISS",
        "esa": "ESA",
        "ibm": "IBM",
        "diy": "DIY",
        "cd": "CD",
        "dvd": "DVD",
        "nasa": "NASA",
        "faa": "FAA",
        "cdc": "CDC",
        
    ]

    static func displayName(for topic: String) -> String {
        let normalizedTopic = topic
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()

        guard !normalizedTopic.isEmpty else { return "" }

        return normalizedTopic
            .split(separator: " ")
            .map { displayWord(String($0)) }
            .joined(separator: " ")
    }

    private static func displayWord(_ word: String) -> String {
        word
            .split(separator: "-", omittingEmptySubsequences: false)
            .map { displayHyphenatedPart(String($0)) }
            .joined(separator: "-")
    }

    private static func displayHyphenatedPart(_ part: String) -> String {
        if let wordName = wordNames[part] {
            return wordName
        }

        guard let first = part.first else { return part }
        return first.uppercased() + part.dropFirst().lowercased()
    }
}
