import NetlogsCore

extension MonitorSettings {
    /// The settings a session uses until the Settings window (Phase 7) exists.
    static var uiDefault: MonitorSettings {
        // `throughputEnabled` is the model default too — see the note there;
        // the two must not diverge.
        MonitorSettings(throughputEnabled: true, throughputInterval: 15)
    }
}
