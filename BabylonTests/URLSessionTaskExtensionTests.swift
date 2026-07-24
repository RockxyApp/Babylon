import Foundation
import Testing
@testable import Babylon

struct URLSessionTaskExtensionTests {
    @Test("currentRequestSafe returns the request for a regular data task")
    func dataTaskReturnsRequest() throws {
        let url = try #require(URL(string: "https://example.com/api"))
        let request = URLRequest(url: url)
        let task = URLSession.shared.dataTask(with: request)

        let safe = task.currentRequestSafe
        #expect(safe != nil)
        #expect(safe?.url == url)
    }

    @Test("currentRequestSafe does not crash when called on a download task")
    func downloadTaskDoesNotCrash() throws {
        let url = try #require(URL(string: "https://example.com/file"))
        let task = URLSession.shared.downloadTask(with: url)

        // The primary assertion is that this call completes without crashing.
        let safe = task.currentRequestSafe
        #expect(safe != nil)
    }

    @Test("currentRequestSafe on upload task returns the request")
    func uploadTaskReturnsRequest() throws {
        let url = try #require(URL(string: "https://example.com/upload"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let data = try #require("upload body".data(using: .utf8))
        let task = URLSession.shared.uploadTask(with: request, from: data)

        let safe = task.currentRequestSafe
        #expect(safe != nil)
        #expect(safe?.url?.absoluteString == "https://example.com/upload")
    }

    @Test("currentRequestSafe on WebSocket task returns the request")
    func webSocketTaskReturnsRequest() throws {
        let url = try #require(URL(string: "wss://example.com/ws"))
        let task = URLSession.shared.webSocketTask(with: url)

        let safe = task.currentRequestSafe
        #expect(safe != nil)
        // URLSession normalises wss:// to https:// in the currentRequest.
        let urlString = try #require(safe?.url?.absoluteString)
        #expect(urlString == "wss://example.com/ws" || urlString == "https://example.com/ws")
    }
}
