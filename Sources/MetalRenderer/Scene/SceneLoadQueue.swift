/// The renderer's scene loads (`Renderer.startLoadingScene`): one prepared in the background at a time, each with a
/// number, and only the latest one asked for is put in. A load superseded by another, or by settings that ask for the
/// scene already drawn (a switch away and back while it loads), is dropped when it finishes, whatever its settings:
/// matching settings alone let a cancelled load of A be put in for a later request for A. Pure: the renderer starts,
/// cancels and installs; this says which.
package struct SceneLoadQueue {
    /// The load under way: its settings and its number.
    package private(set) var current: (settings: SceneSettings, number: Int)?
    private var last = 0

    package init() {}

    /// The settings being prepared, if any.
    package var loading: SceneSettings? { current?.settings }

    /// A load of `settings` starts; its number. The one before it, if any, is superseded.
    package mutating func start(_ settings: SceneSettings) -> Int {
        last += 1
        current = (settings, last)
        return last
    }

    /// The settings now ask for `asked` while `drawn` is the scene drawn: a load under way for other settings, when
    /// `asked` is the scene drawn, is no longer wanted and is dropped. Whether one was.
    package mutating func settle(asked: SceneSettings, drawn: SceneSettings) -> Bool {
        guard let current, current.settings != asked, asked == drawn else { return false }
        self.current = nil
        return true
    }

    /// Load `number` is prepared: whether its scene is put in (it is the one under way, not dropped or superseded).
    package mutating func finished(_ number: Int) -> Bool {
        guard current?.number == number else { return false }
        current = nil
        return true
    }

    /// Every load dropped (a benchmark makes its scene right away).
    package mutating func clear() { current = nil }
}
