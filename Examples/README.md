# Wiring DevLens into an app

Ten lines in `AppDelegate` (or your `@main` App), all inside `#if DEBUG`:

```swift
import APITrace

final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        #if DEBUG
        APITrace.shared.start(label: "cold-start", autoAttachWebViews: true)
        #endif
        return true
    }
}

// In the flow you care about:
APITrace.shared.mark("LoginTapped")
APITrace.shared.mark("TokenReceived")
APITrace.shared.mark("HomeAppeared")
APITrace.shared.mark("ShimmerStopped")
```

## A minimal SwiftUI debug screen

Present this from a shake gesture, a hidden button, or a long press on the version label. It starts and stops a trace with a free-text label, shows live counts, the text report, and shares the exported files.

```swift
#if DEBUG
import SwiftUI
import APITrace

struct TraceDebugView: View {
    @State private var label = "run-1"
    @State private var isRecording = APITrace.shared.isRecording
    @State private var report = ""
    @State private var counts = (requests: 0, marks: 0)
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationView {
            List {
                Section("Trace") {
                    TextField("Label", text: $label)
                    Button(isRecording ? "Stop" : "Start") {
                        if isRecording { APITrace.shared.stop() } else { APITrace.shared.start(label: label) }
                        isRecording = APITrace.shared.isRecording
                    }
                    Text("Requests: \(counts.requests)   Marks: \(counts.marks)").font(.footnote.monospaced())
                }
                Section("Actions") {
                    Button("Show report") { report = APITrace.shared.report() }
                    Button("Share files") { share() }
                }
                if !report.isEmpty {
                    Section("Report") {
                        ScrollView(.horizontal) { Text(report).font(.system(size: 10, design: .monospaced)) }
                    }
                }
            }
            .navigationTitle("APITrace")
        }
        .onReceive(timer) { _ in
            let snap = APITrace.shared.snapshot()
            counts = (snap.filter { $0.isRequest }.count, snap.filter { !$0.isRequest }.count)
        }
    }

    private func share() {
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController }).first else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        APITrace.shared.share(from: top)
    }
}
#endif
```

What it looks like: a plain grouped list. Top section has the label field, a Start/Stop button and a monospaced counter line that ticks once a second. Second section has "Show report" and "Share files". When a report is shown, a third section holds the monospaced table that scrolls horizontally. Tapping "Share files" opens the system share sheet with four files: `<label>-<timestamp>.json` (Perfetto), `.csv`, `.records.json` (raw records for `trace-compare`) and `.txt` (the report).

## Shake to open

```swift
#if DEBUG
extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        guard motion == .motionShake, let root = rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        top.present(UIHostingController(rootView: TraceDebugView()), animated: true)
    }
}
#endif
```

## Getting the files off the device

- **Share sheet**: AirDrop to a Mac, or save to Files.
- **Finder**: enable *Application supports iTunes file sharing* (`UIFileSharingEnabled`) in the debug Info.plist, then the `APITrace` folder shows under the device in Finder.
- **Simulator**: the folder is `<app container>/Documents/APITrace`; the path is printed to the console on every export.

## Comparing two runs

```
swift run trace-compare run-1-20260301-101500.records.json run-2-20260301-103000.records.json
```
