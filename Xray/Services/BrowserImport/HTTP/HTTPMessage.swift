import Foundation

struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

struct HTTPResponse: Sendable {
    let statusCode: Int
    let statusText: String
    let headers: [String: String]
    let body: Data
}
