import Foundation
import WebKit

public enum VirtualClock {
    /// Contents of Resources/clock.js.
    public static let source: String = {
        guard let url = Bundle.module.url(forResource: "clock", withExtension: "js"),
              let s = try? String(contentsOf: url, encoding: .utf8) else {
            fatalError("SafariumCore: clock.js resource missing")
        }
        return s
    }()

    /// Script that runs before any page script, in every frame.
    public static func userScript(video: VideoMode = .none) -> WKUserScript {
        let mode: String
        switch video { case .none: mode = "none"; case .element: mode = "element"; case .extract: mode = "extract" }
        return WKUserScript(source: "window.__sfVideoMode = '\(mode)';\n" + source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }
}
