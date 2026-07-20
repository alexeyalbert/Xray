import Foundation

extension String {
    nonisolated private static let namedHTMLTextEntities: [String: String] = [
        "amp": "&",
        "lt": "<",
        "gt": ">",
        "quot": "\"",
        "apos": "'",
        "nbsp": " ",
        "ndash": "-",
        "mdash": "-",
        "hellip": "...",
        "lsquo": "'",
        "rsquo": "'",
        "ldquo": "\"",
        "rdquo": "\"",
        "bull": "*",
        "copy": "(c)",
        "reg": "(r)",
        "trade": "(tm)"
    ]

    nonisolated var containsHTMLTextEntity: Bool {
        guard contains("&") else { return false }

        var index = startIndex
        while index < endIndex {
            guard self[index] == "&",
                  let semicolon = self[index...].firstIndex(of: ";")
            else {
                index = self.index(after: index)
                continue
            }

            let entityStart = self.index(after: index)
            let entity = self[entityStart..<semicolon]
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                if UInt32(entity.dropFirst(2), radix: 16).flatMap(UnicodeScalar.init) != nil {
                    return true
                }
            } else if entity.hasPrefix("#") {
                if UInt32(entity.dropFirst(), radix: 10).flatMap(UnicodeScalar.init) != nil {
                    return true
                }
            } else if Self.namedHTMLTextEntities[String(entity)] != nil {
                return true
            }

            index = self.index(after: semicolon)
        }

        return false
    }

    nonisolated var decodedHTMLText: String {
        guard contains("&") else { return self }

        var output = ""
        output.reserveCapacity(count)

        var index = startIndex
        while index < endIndex {
            guard self[index] == "&",
                  let semicolon = self[index...].firstIndex(of: ";")
            else {
                output.append(self[index])
                index = self.index(after: index)
                continue
            }

            let entityStart = self.index(after: index)
            let entity = self[entityStart..<semicolon]
            let decoded: String?
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                decoded = UInt32(entity.dropFirst(2), radix: 16)
                    .flatMap(UnicodeScalar.init)
                    .map(String.init)
            } else if entity.hasPrefix("#") {
                decoded = UInt32(entity.dropFirst(), radix: 10)
                    .flatMap(UnicodeScalar.init)
                    .map(String.init)
            } else {
                decoded = Self.namedHTMLTextEntities[String(entity)]
            }

            if let decoded {
                output.append(decoded)
            } else {
                output.append(contentsOf: self[index...semicolon])
            }
            index = self.index(after: semicolon)
        }

        return output
    }
}
