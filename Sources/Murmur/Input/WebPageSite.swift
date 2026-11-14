import ApplicationServices
import MurmurCore

/// Which placed website a browser tab is, looked up once at key-down (TRY-93). Only asked when the person has placed
/// a website on a tone (`ToneSettings.siteMatcher`), and only for a browser.
///
/// The window title the key-down already read is tried first and costs nothing: " - Google Docs" names the site.
/// Only a title that names no known site leads to reading the page's address: the window's `AXDocument`, else the
/// `AXURL` of the web area around the focused field (the first one up the tree with a web address, so the blank
/// frame Google Docs types into is passed over). Each read has a short timeout, and the whole look stops at `budget`.
///
/// Privacy: only the host is looked at, and only a host that belongs to a placed site is kept, as that site's key.
/// The address, the title and the page are never stored or logged; the log says the site key at most.
@MainActor
enum WebPageSite {
    struct Lookup: Equatable {
        enum Source: String { case title, document, webArea, none }
        /// The placed site's key, or nil.
        let key: String?
        let source: Source
        let microseconds: Int
        /// The steps up the tree read for a web area (0 when none were needed).
        let steps: Int
    }

    /// The longest one read may take, in seconds: short, because this runs while the microphone opens.
    static let readTimeout: Float = 0.02
    /// No further read starts after this.
    static let budget: Duration = .milliseconds(12)
    /// Web content sits well within this many levels of the focused field; past it the look gives up.
    static let deepestWalk = 40

    static func lookup(_ matcher: WebsiteMatcher, title: String?, window: AXUIElement?, focused: AXUIElement?) -> Lookup {
        let clock = ContinuousClock()
        let start = clock.now
        func done(_ key: String?, _ source: Lookup.Source, steps: Int = 0) -> Lookup {
            let elapsed = clock.now - start
            let microseconds = Int(elapsed.components.seconds) * 1_000_000 + Int(elapsed.components.attoseconds / 1_000_000_000_000)
            return Lookup(key: key, source: source, microseconds: microseconds, steps: steps)
        }
        switch matcher.match(title: title) {
        case .placed(let key): return done(key, .title)
        case .notPlaced: return done(nil, .title)
        case .unknown: break
        }
        let deadline = start + budget
        if let window, let host = host(in: window, attribute: "AXDocument") {
            return done(matcher.match(host: host), .document)
        }
        guard let focused else { return done(nil, .none) }
        let found = webAreaHost(from: focused, until: deadline)
        return done(found.host.flatMap(matcher.match(host:)), found.host == nil ? .none : .webArea, steps: found.steps)
    }

    /// Walks up from the focused field to the first web area whose address is a web page. Stops at the window.
    private static func webAreaHost(from focused: AXUIElement, until deadline: ContinuousClock.Instant) -> (host: String?, steps: Int) {
        var element: AXUIElement? = focused
        var steps = 0
        while let current = element, steps < deepestWalk, ContinuousClock.now < deadline {
            let role = string(kAXRoleAttribute, of: current)
            if role == "AXWebArea", let host = host(in: current, attribute: "AXURL") { return (host, steps) }
            if role == kAXWindowRole as String { break }
            element = parent(of: current)
            steps += 1
        }
        return (nil, steps)
    }

    /// The host of the address in `attribute` (a URL or a string), or nil when it is not a web page.
    private static func host(in element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        guard bounded(element, { AXUIElementCopyAttributeValue(element, attribute as CFString, &value) }) == .success else {
            return nil
        }
        if let url = value as? URL { return WebsiteAddress.host(of: url.absoluteString) }
        return (value as? String).flatMap(WebsiteAddress.host(of:))
    }

    private static func string(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard bounded(element, { AXUIElementCopyAttributeValue(element, attribute as CFString, &value) }) == .success else {
            return nil
        }
        return value as? String
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard bounded(element, { AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) }) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// One read under `readTimeout`, with the element put back on the default after it.
    private static func bounded(_ element: AXUIElement, _ read: () -> AXError) -> AXError {
        AXUIElementSetMessagingTimeout(element, readTimeout)
        defer { AXUIElementSetMessagingTimeout(element, 0) }
        return read()
    }
}
