import Foundation
import Testing
@testable import MurmurCore

@Suite("Usage metrics: endpoint setting and transport request")
struct MetricsEndpointTests {
    @Test("empty, unsubstituted, non-https and credentialed values are all 'not configured'")
    func notConfigured() {
        for raw in [nil, "", "   ", "__USAGE_METRICS_ENDPOINT__", "http://example.com/m", "ftp://example.com", "example.com/m",
                    "https://", "https://user:pw@example.com/m", "https://user@example.com/m", "not a url"] as [String?] {
            #expect(MetricsEndpoint.parse(raw) == nil, "\(raw ?? "nil")")
        }
    }

    @Test("a plain https address is accepted, trimmed")
    func configured() {
        #expect(MetricsEndpoint.parse(" https://metrics.example.com/v1/batches \n")?.absoluteString == "https://metrics.example.com/v1/batches")
    }

    @Test("a bundle without the key is not configured")
    func bundleWithoutKey() {
        #expect(MetricsEndpoint.configured(in: Bundle(for: BundleToken.self)) == nil)
    }

    private final class BundleToken {}

    @Test("the repository's Info.plist ships the key empty-by-default (a placeholder the build fills from an unset variable)")
    func shippedPlistIsInert() throws {
        let plist = try repositoryFile("Resources/Info.plist")
        let data = try #require(plist.data(using: .utf8))
        let object = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let value = try #require(object[MetricsEndpoint.infoPlistKey] as? String)
        #expect(MetricsEndpoint.parse(value) == nil)               // the template placeholder is never a usable address
        let script = try repositoryFile("scripts/build-app.sh")
        #expect(script.contains("HUSHY_USAGE_METRICS_ENDPOINT:-}"))   // and the build substitutes an empty default
    }

    private func repositoryFile(_ path: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/", !FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
            url.deleteLastPathComponent()
        }
        return try String(contentsOf: url.appendingPathComponent(path), encoding: .utf8)
    }

    @Test("the request carries the exact body and a content type, and nothing that identifies anyone")
    func requestShape() throws {
        let body = Data("{\"a\":1}".utf8)
        let url = try #require(URL(string: "https://metrics.example.com/v1/batches"))
        let request = URLSessionMetricsTransport.request(to: url, body: body)
        #expect(request.httpMethod == "POST")
        #expect(request.httpBody == body)
        #expect(request.allHTTPHeaderFields == ["Content-Type": "application/json"])
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.timeoutInterval == URLSessionMetricsTransport.requestTimeout)
        #expect(request.timeoutInterval <= 15)
    }

    @Test("the session keeps no cookies, credentials or cache and times out quickly")
    func sessionConfiguration() {
        let configuration = URLSessionMetricsTransport.configuration()
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.urlCache == nil)
        #expect(configuration.timeoutIntervalForRequest <= 15)
    }

    @Test("status codes map to accept, drop or retry")
    func statusMapping() {
        for status in [200, 201, 204] { #expect(URLSessionMetricsTransport.outcome(forStatus: status) == .accepted) }
        for status in [408, 425, 429, 500, 503] { #expect(URLSessionMetricsTransport.outcome(forStatus: status) == .retryLater) }
        for status in [301, 307, 400, 401, 403, 404, 413, 422] { #expect(URLSessionMetricsTransport.outcome(forStatus: status) == .rejected) }
    }
}
