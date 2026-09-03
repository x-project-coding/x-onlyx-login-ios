import SwiftUI
import OnlyXLoginCore

/// OnlyX Login for iPhone — the app a creator opens from a link to sign in to OnlyFans for her
/// OnlyX-managed account, on the phone she actually has. Same three-call contract as the mac app
/// (open → sign-in → session → status), same capture rules, same words; the differences are the
/// ones iOS forces and they are written down in README "What iOS cannot do".
@main
struct OnlyXLoginApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                // The link. iOS hands a custom-scheme URL to the running app (or launches it) here;
                // nothing else in the app reads a URL.
                .onOpenURL { url in model.handle(url: url) }
        }
    }
}
