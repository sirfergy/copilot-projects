import AppKit
import XCTest
import CopilotProjectsCore
import CopilotProjectsProtocol
@testable import CopilotProjectsHost

@MainActor
final class SSHHostCatalogTests: XCTestCase {
    private func withTempDirectory(_ body: (URL) throws -> Void) throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    func testMakeManualHostValidatesAndNormalizesInputs() {
        let full = SSHHostCatalog.makeManualHost(
            sshTarget: "  root@Woodhaven.TheFergies.com  ",
            displayName: "  Surface WSL  ",
            defaultCwd: "  /root/Repos  "
        )
        XCTAssertEqual(
            full,
            RemoteHostInfo(
                id: "root@woodhaven.thefergies.com",
                displayName: "Surface WSL",
                sshTarget: "root@Woodhaven.TheFergies.com",
                defaultCwd: "/root/Repos",
                isLocal: false
            )
        )

        let defaulted = SSHHostCatalog.makeManualHost(
            sshTarget: "ubuntu@DevBox.internal.example.com",
            displayName: "   ",
            defaultCwd: ""
        )
        XCTAssertEqual(
            defaulted,
            RemoteHostInfo(
                id: "ubuntu@devbox.internal.example.com",
                displayName: "devbox",
                sshTarget: "ubuntu@DevBox.internal.example.com",
                defaultCwd: nil,
                isLocal: false
            )
        )

        let ipv4 = SSHHostCatalog.makeManualHost(sshTarget: "root@10.0.0.42")
        XCTAssertEqual(ipv4?.displayName, "10.0.0.42")

        XCTAssertNil(SSHHostCatalog.makeManualHost(sshTarget: ""))
        XCTAssertNil(SSHHostCatalog.makeManualHost(sshTarget: "   "))
        XCTAssertNil(SSHHostCatalog.makeManualHost(sshTarget: "-oProxyCommand=evil"))
        XCTAssertNil(SSHHostCatalog.makeManualHost(sshTarget: "user@host -p 2222"))
        XCTAssertNil(SSHHostCatalog.makeManualHost(sshTarget: "local"))
        XCTAssertNil(SSHHostCatalog.makeManualHost(sshTarget: "localhost"))
        XCTAssertNil(SSHHostCatalog.makeManualHost(sshTarget: "127.0.0.1"))
        XCTAssertNil(SSHHostCatalog.makeManualHost(sshTarget: "::1"))
        XCTAssertNil(SSHHostCatalog.makeManualHost(sshTarget: "root@localhost"))
    }

    func testConfigurationPersistenceAndDiscoveryPrecedence() throws {
        try withTempDirectory { root in
            let statePath = root.appendingPathComponent("state.json")
            let sshConfigURL = root.appendingPathComponent("ssh_config")
            try """
            Host woodhaven.thefergies.com
              User root

            Host buildbox.example.com
              User builder
            """.write(to: sshConfigURL, atomically: true, encoding: .utf8)

            // Default configuration when hosts.json is absent: autoDiscover == true, hosts == [].
            let defaultConfig = SSHHostCatalog.loadConfiguration(statePath: statePath)
            XCTAssertTrue(defaultConfig.autoDiscover)
            XCTAssertTrue(defaultConfig.hosts.isEmpty)
            XCTAssertEqual(
                SSHHostCatalog.defaultAvailableHosts(statePath: statePath).map(\.id),
                ["local", "woodhaven.thefergies.com", "buildbox.example.com"]
            )

            // Manual host overrides matching auto-discovered host and appears first;
            // invalid/local entries are filtered on load.
            let manualWoodhaven = try XCTUnwrap(
                SSHHostCatalog.makeManualHost(
                    sshTarget: "woodhaven.thefergies.com",
                    displayName: "Custom Woodhaven",
                    defaultCwd: "/srv/work"
                )
            )
            let manualStaging = try XCTUnwrap(
                SSHHostCatalog.makeManualHost(
                    sshTarget: "deploy@staging.example.com",
                    displayName: "Staging"
                )
            )
            let saved = SSHHostCatalog.saveConfiguration(
                SSHHostConfiguration(
                    autoDiscover: true,
                    hosts: [
                        .local,
                        RemoteHostInfo(id: "", displayName: "Invalid", isLocal: false),
                        manualStaging,
                        manualWoodhaven,
                    ]
                ),
                statePath: statePath
            )
            XCTAssertTrue(saved)

            let loaded = SSHHostCatalog.loadConfiguration(statePath: statePath)
            XCTAssertTrue(loaded.autoDiscover)
            XCTAssertEqual(loaded.hosts, [manualStaging, manualWoodhaven])

            let combined = SSHHostCatalog.defaultAvailableHosts(statePath: statePath)
            XCTAssertEqual(
                combined,
                [
                    .local,
                    manualStaging,
                    manualWoodhaven,
                    RemoteHostInfo(
                        id: "buildbox.example.com",
                        displayName: "buildbox",
                        sshTarget: "buildbox.example.com",
                        defaultCwd: nil,
                        isLocal: false
                    ),
                ]
            )

            // Disabling autoDiscover omits ~/.ssh/config hosts while keeping manual hosts.
            SSHHostCatalog.saveConfiguration(
                SSHHostConfiguration(autoDiscover: false, hosts: [manualStaging]),
                statePath: statePath
            )
            let manualOnly = SSHHostCatalog.defaultAvailableHosts(statePath: statePath)
            XCTAssertEqual(manualOnly, [.local, manualStaging])
        }
    }

    func testAppModelManualSSHHostManagementAndInteractiveModal() throws {
        try withTempDirectory { root in
            let statePath = root.appendingPathComponent("state.json")
            try """
            Host autodiscovered.example.com
              User dev
            """.write(
                to: root.appendingPathComponent("ssh_config"),
                atomically: true,
                encoding: .utf8
            )

            var modalStep = 0
            var invalidAlertTitles: [String] = []
            let repository = StateRepository(path: statePath)
            let model = AppModel(
                stateRepository: repository,
                isAppActive: { false },
                agentActivityDirectory: root,
                resumeMarkerDirectory: root,
                kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images")),
                gracefulSessionDestroyer: { _, _ in Task {} },
                forcedSessionDestroyer: { _ in },
                alertPresenter: { alert in
                    if alert.messageText == "Add SSH Host" {
                        let fields = alert.accessoryView?.subviews.compactMap { $0 as? NSTextField } ?? []
                        XCTAssertEqual(fields.count, 3)
                        modalStep += 1
                        if modalStep == 1 {
                            fields[0].stringValue = "admin@gpu-box.example.com"
                            fields[1].stringValue = "GPU Box"
                            fields[2].stringValue = "~/Models"
                            return .alertFirstButtonReturn
                        } else {
                            fields[0].stringValue = "-bad-flag"
                            return .alertFirstButtonReturn
                        }
                    } else {
                        invalidAlertTitles.append(alert.messageText)
                        return .alertFirstButtonReturn
                    }
                }
            )
            defer {
                model.forcePendingSessionDestroys()
                model.detachAllClients()
            }

            XCTAssertTrue(model.autoDiscoverSSHHosts)
            XCTAssertEqual(model.availableHosts.map(\.id), ["local", "autodiscovered.example.com"])

            model.setAutoDiscoverSSHHosts(false)
            XCTAssertFalse(model.autoDiscoverSSHHosts)
            XCTAssertEqual(model.availableHosts.map(\.id), ["local"])

            model.addManualSSHHostInteractive()
            XCTAssertEqual(model.manualSSHHosts.count, 1)
            XCTAssertEqual(model.manualSSHHosts.first?.displayName, "GPU Box")
            XCTAssertEqual(model.manualSSHHosts.first?.defaultCwd, "~/Models")
            XCTAssertEqual(model.availableHosts.map(\.id), ["local", "admin@gpu-box.example.com"])

            // Updating an existing manual host with the same case-insensitive id replaces it in place.
            let updated = model.addManualSSHHost(
                sshTarget: "ADMIN@GPU-BOX.EXAMPLE.COM",
                displayName: "Renamed GPU Box",
                defaultCwd: "/data"
            )
            XCTAssertEqual(updated?.displayName, "Renamed GPU Box")
            XCTAssertEqual(model.manualSSHHosts.count, 1)
            XCTAssertEqual(model.manualSSHHosts.first?.displayName, "Renamed GPU Box")
            XCTAssertEqual(model.manualSSHHosts.first?.defaultCwd, "/data")

            // Invalid interactive input shows an error alert and leaves manual hosts unchanged.
            model.addManualSSHHostInteractive()
            XCTAssertEqual(invalidAlertTitles, ["Invalid SSH Host"])
            XCTAssertEqual(model.manualSSHHosts.count, 1)

            model.removeManualSSHHost(id: "admin@gpu-box.example.com")
            XCTAssertTrue(model.manualSSHHosts.isEmpty)
            XCTAssertEqual(model.availableHosts.map(\.id), ["local"])
        }
    }
}
