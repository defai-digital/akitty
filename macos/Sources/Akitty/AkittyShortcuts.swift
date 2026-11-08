import AppIntents
import AkittyKit

struct AkittyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: NewTerminalIntent(), phrases: ["Open a new terminal in \(.applicationName)", "New \(.applicationName) terminal"], shortTitle: "New Terminal", systemImageName: "terminal")
        AppShortcut(intent: ShowQuickTerminalIntent(), phrases: ["Show the quick terminal in \(.applicationName)"], shortTitle: "Show Quick Terminal", systemImageName: "rectangle.topthird.inset.filled")
        AppShortcut(intent: ShowAgentOverviewIntent(), phrases: ["Show agent overview in \(.applicationName)", "Show agents in \(.applicationName)"], shortTitle: "Agent Overview", systemImageName: "rectangle.3.group")
        AppShortcut(intent: ListTerminalsIntent(), phrases: ["List terminals in \(.applicationName)"], shortTitle: "List Terminals", systemImageName: "list.bullet.rectangle")
        AppShortcut(intent: FocusTerminalIntent(), phrases: ["Focus a terminal in \(.applicationName)"], shortTitle: "Focus Terminal", systemImageName: "macwindow")
        AppShortcut(intent: RequestCommandIntent(), phrases: ["Request a command in \(.applicationName)"], shortTitle: "Request Command", systemImageName: "checkmark.shield")
    }
}
