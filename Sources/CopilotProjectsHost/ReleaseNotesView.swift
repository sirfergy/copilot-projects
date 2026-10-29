import SwiftUI
import CopilotProjectsCore
import CopilotProjectsUI

struct ReleaseNotesView: View {
    let onDismiss: () -> Void
    @State private var snapshot: ReleaseNotesSnapshot?
    @State private var error: String?

    private var installedVersion: String {
        let bundle = RunningExecutable.applicationBundle ?? .main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return version == build ? version : "\(version) (\(build))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("What's New").font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let snapshot {
                        Text("Version \(snapshot.displayVersion)")
                            .foregroundStyle(StudioStyle.secondaryText)
                        MarkdownText(text: snapshot.markdown)
                        if let url = snapshot.releasesURL,
                           !snapshot.markdown.contains(url.absoluteString) {
                            Link("Full release notes history", destination: url)
                        }
                    } else if let error {
                        Text("Couldn't Load Release Notes").font(.headline)
                        Text("Version \(installedVersion)")
                            .foregroundStyle(StudioStyle.secondaryText)
                        Text("Please report this app version so its bundled release notes can be corrected.")
                        Text(error).foregroundStyle(StudioStyle.secondaryText)
                    } else {
                        Text("Release notes aren't included in this development build.")
                            .foregroundStyle(StudioStyle.secondaryText)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        }
        .frame(width: 560, height: 420)
        .background(StudioStyle.chrome)
        .onAppear {
            do {
                snapshot = try ReleaseNotesSnapshot.load(bundle: RunningExecutable.applicationBundle ?? .main)
            } catch {
                self.error = error.localizedDescription
                NSLog("Could not load release notes: %@", error.localizedDescription)
            }
        }
    }
}
