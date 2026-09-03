import SwiftUI
import OnlyXLoginCore

/// Everything the creator sees while NOT looking at OnlyFans — the phases ui.js renders, in the
/// mac app's words and colours (brand #00AEEF, canvas #0b0b0f).
struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            Brand.canvas.ignoresSafeArea()
            switch model.phase {
            case .signin(let username, let expiresAt, let notice):
                SignInScreen(username: username, expiresAt: expiresAt, notice: notice)
            default:
                FullScreen(phase: model.phase)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $model.helpShowing) { HelpSheet() }
    }
}

enum Brand {
    static let blue = Color(red: 0, green: 0xAE / 255, blue: 0xEF / 255)
    static let canvas = Color(red: 0x0b / 255, green: 0x0b / 255, blue: 0x0f / 255)
    static let panel = Color(red: 0x17 / 255, green: 0x17 / 255, blue: 0x1c / 255)
    static let line = Color(red: 0x26 / 255, green: 0x26 / 255, blue: 0x2e / 255)
    static let text = Color(red: 0xf4 / 255, green: 0xf4 / 255, blue: 0xf5 / 255)
    static let muted = Color(red: 0xa1 / 255, green: 0xa1 / 255, blue: 0xaa / 255)
    static let ok = Color(red: 0x22 / 255, green: 0xc5 / 255, blue: 0x5e / 255)
    static let bad = Color(red: 0xf8 / 255, green: 0x71 / 255, blue: 0x71 / 255)
    static let warn = Color(red: 0xfb / 255, green: 0xbf / 255, blue: 0x24 / 255)
}

/// The OnlyX mark: a dark disc with a blue ring.
struct Mark: View {
    var size: CGFloat = 22
    var body: some View {
        Circle().fill(Color(red: 0x09 / 255, green: 0x09 / 255, blue: 0x0b / 255))
            .overlay(Circle().strokeBorder(Brand.blue, lineWidth: size * 0.11))
            .frame(width: size, height: size)
    }
}

struct BrandRow: View {
    var body: some View {
        HStack(spacing: 9) {
            Mark()
            Text("OnlyX Login").font(.system(size: 17, weight: .bold)).foregroundColor(Brand.text)
        }
    }
}

// MARK: full-screen states

struct FullScreen: View {
    @EnvironmentObject var model: AppModel
    let phase: Phase
    @State private var pasteFailed = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                BrandRow().padding(.bottom, 20)
                icon.frame(width: 64, height: 64).padding(.bottom, 12)
                Text(title).font(.system(size: 21, weight: .bold)).foregroundColor(Brand.text)
                    .multilineTextAlignment(.center)
                Text(text).font(.system(size: 15)).foregroundColor(Brand.muted)
                    .multilineTextAlignment(.center)
                if let detail { Text(detail).font(.system(size: 15)).foregroundColor(Brand.muted).multilineTextAlignment(.center) }
                actions.padding(.top, 16)
                fine.padding(.top, 14)
            }
            .padding(24)
            Spacer(minLength: 0)
        }
    }

    private var who: String {
        switch phase {
        case .success(let u), .captured(let u): return u.map { "@\($0)" } ?? "your account"
        case .verifying(let u, _): return u.map { "@\($0)" } ?? "your account"
        default: return "your account"
        }
    }

    @ViewBuilder private var icon: some View {
        switch phase {
        case .idle: Mark(size: 64)
        case .opening, .captured, .verifying: Spinner()
        case .success: Circle().fill(Brand.ok.opacity(0.14)).overlay(Text("✓").font(.system(size: 30)).foregroundColor(Brand.ok))
        case .error: Circle().fill(Brand.bad.opacity(0.14)).overlay(Text("!").font(.system(size: 30)).foregroundColor(Brand.bad))
        case .signin: EmptyView()
        }
    }

    private var title: String {
        switch phase {
        case .idle: return "Waiting for your link"
        case .opening: return "Opening your link…"
        case .captured: return "Signed in"
        case .verifying: return "Connecting your account…"
        case .success: return "Connected"
        case .error(let m, _): return m.title
        case .signin: return ""
        }
    }

    private var text: String {
        switch phase {
        case .idle:
            return "This app connects your OnlyFans account to OnlyX. Open the chat where your manager sent your connect link and tap it — or copy the link and paste it here."
        case .opening: return "Setting up a private connection for your account."
        case .captured: return "Sending your sign-in to OnlyX…"
        case .verifying: return "OnlyX is taking over the session for \(who). This usually takes under a minute."
        case .success: return "\(who) is now connected to OnlyX. You can close this app."
        case .error(let m, _): return m.detail
        case .signin: return ""
        }
    }

    private var detail: String? {
        switch phase {
        case .idle: return "No link? Ask your manager for one. OnlyX Login only needs to stay installed, not open."
        case .verifying: return "Please keep the app open."
        default: return nil
        }
    }

    @ViewBuilder private var actions: some View {
        switch phase {
        case .idle:
            VStack(spacing: 8) {
                Button("Paste your link") {
                    pasteFailed = !model.pasteLink()
                }.buttonStyle(Primary())
                if pasteFailed {
                    Text("Nothing on the clipboard looks like a connect link. Copy the whole link from your chat and try again.")
                        .font(.system(size: 13)).foregroundColor(Brand.warn).multilineTextAlignment(.center)
                }
            }
        case .success:
            Button("Done") { model.reset() }.buttonStyle(Primary())
        case .error:
            HStack(spacing: 10) {
                Button("Help") { model.helpShowing = true }.buttonStyle(Secondary())
                Button("Done") { model.reset() }.buttonStyle(Primary())
            }
        default: EmptyView()
        }
    }

    @ViewBuilder private var fine: some View {
        if case .idle = phase {
            Button("Help") { model.helpShowing = true }.font(.system(size: 12)).foregroundColor(Brand.blue)
        }
    }
}

struct Spinner: View {
    @State private var spin = false
    var body: some View {
        Circle().strokeBorder(Brand.line, lineWidth: 3)
            .overlay(Circle().trim(from: 0, to: 0.25).stroke(Brand.blue, lineWidth: 3))
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spin)
            .onAppear { spin = true }
    }
}

struct Primary: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, 18).padding(.vertical, 11)
            .background(Brand.blue).foregroundColor(Color(red: 0x04 / 255, green: 0x13 / 255, blue: 0x1a / 255))
            .cornerRadius(10).opacity(configuration.isPressed ? 0.85 : 1)
    }
}
struct Secondary: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, 18).padding(.vertical, 11)
            .background(Brand.panel).foregroundColor(Brand.text)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Brand.line))
            .cornerRadius(10).opacity(configuration.isPressed ? 0.85 : 1)
    }
}

// MARK: the sign-in screen: a strip above the browser

struct SignInScreen: View {
    @EnvironmentObject var model: AppModel
    let username: String?
    let expiresAt: String?
    let notice: UserMessage?
    @State private var now = Date()
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Mark()
                    (Text("Sign in to OnlyFans as ").foregroundColor(Brand.muted)
                     + Text(username.map { "@\($0)" } ?? "your account").foregroundColor(Brand.text).bold())
                        .font(.system(size: 14)).lineLimit(1)
                    Spacer()
                    Text(timeLeft).font(.system(size: 13).monospacedDigit())
                        .foregroundColor(late ? Brand.warn : Brand.muted)
                    Button("Help") { model.helpShowing = true }.font(.system(size: 13)).foregroundColor(Brand.blue)
                }
                if let notice {
                    Text("\(notice.title). \(notice.detail)")
                        .font(.system(size: 12)).foregroundColor(Brand.warn)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Brand.warn.opacity(0.12)).cornerRadius(8)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Brand.panel)
            Divider().background(Brand.line)
            if let controller = model.signIn {
                SignInWebView(controller: controller).ignoresSafeArea(edges: .bottom)
            } else {
                Spacer()
            }
        }
        .onReceive(clock) { now = $0 }
    }

    private var secondsLeft: Int {
        guard let expiresAt, let end = ISO8601DateFormatter().date(from: expiresAt)
                ?? ISO8601DateFormatter.withMillis.date(from: expiresAt) else { return 0 }
        return max(0, Int(end.timeIntervalSince(now)))
    }
    private var late: Bool { secondsLeft < 5 * 60 }
    private var timeLeft: String {
        let m = secondsLeft / 60, s = secondsLeft % 60
        return String(format: "%d:%02d left", m, s)
    }
}

extension ISO8601DateFormatter {
    static let withMillis: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
}

// MARK: help, in the app, with no connection required

struct HelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    static let entries: [(String, String)] = [
        ("Nothing happened when I tapped my link",
         "Some chat apps do not open app links directly. Press and hold the link, choose Copy, open OnlyX Login and tap “Paste your link”."),
        ("How do I install the app?",
         "Your manager sends an invitation link. It installs Apple's TestFlight app first (free), then OnlyX Login inside it. Open OnlyX Login once; after that your connect links open it by themselves."),
        ("My link says it has expired",
         "Links work once, and for 15 minutes. Ask your manager to send a new one — it takes them a second."),
        ("I signed in to the wrong account",
         "Sign out inside the sign-in screen and sign in again with the account your manager is expecting. You do not need a new link."),
        ("OnlyFans is asking for a selfie or a video check",
         "That is normal. Allow the camera when your iPhone asks, hold the phone up to your face, and follow OnlyFans' instructions. Nothing is recorded by OnlyX. If you refused the camera earlier: Settings › OnlyX Login › Camera, switch it on, then open your link again."),
        ("It says it cannot reach OnlyX",
         "Check your internet connection and open the link again. If it keeps happening, tell your manager."),
    ]

    var body: some View {
        NavigationView {
            List {
                ForEach(Self.entries, id: \.0) { q, a in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(q).font(.system(size: 15, weight: .semibold)).foregroundColor(Brand.text)
                        Text(a).font(.system(size: 14)).foregroundColor(Brand.muted)
                    }.padding(.vertical, 4).listRowBackground(Brand.panel)
                }
                Text("Still stuck? Tell your manager, or write to \(Config.supportEmail)")
                    .font(.system(size: 12)).foregroundColor(Brand.muted).listRowBackground(Brand.canvas)
            }
            .listStyle(.insetGrouped)
            .background(Brand.canvas)
            .navigationTitle("Help")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Back") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}
