import AppKit
import SwiftUI

struct ProjectSplitView<Projects: View, Content: View>: NSViewControllerRepresentable {
    let showsProjects: Bool
    let onProjectsHidden: (NSWindow) -> Void
    @ViewBuilder var projects: Projects
    @ViewBuilder var content: Content

    func makeNSViewController(context: Context) -> Controller {
        Controller(projects: projects, content: content, showsProjects: showsProjects)
    }

    func updateNSViewController(_ controller: Controller, context: Context) {
        controller.projects.rootView = projects
        controller.content.rootView = content
        controller.setProjectsVisible(showsProjects, onHidden: onProjectsHidden)
    }

    final class Controller: NSSplitViewController {
        let projects: NSHostingController<Projects>
        let content: NSHostingController<Content>
        let projectsItem: NSSplitViewItem
        var showsProjects: Bool

        init(projects: Projects, content: Content, showsProjects: Bool) {
            self.projects = NSHostingController(rootView: projects)
            self.content = NSHostingController(rootView: content)
            projectsItem = NSSplitViewItem(viewController: self.projects)
            self.showsProjects = showsProjects
            super.init(nibName: nil, bundle: nil)

            projectsItem.minimumThickness = 176
            projectsItem.maximumThickness = 360
            projectsItem.holdingPriority = .init(251)
            projectsItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
            projectsItem.isCollapsed = !showsProjects
            if UserDefaults.standard.object(forKey: "NSSplitView Subview Frames copilot-projects.projects") == nil {
                self.projects.view.setFrameSize(NSSize(width: 176, height: 500))
            }
            addSplitViewItem(projectsItem)
            addSplitViewItem(NSSplitViewItem(viewController: self.content))
            splitView.autosaveName = showsProjects ? "copilot-projects.projects" : nil
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func setProjectsVisible(_ visible: Bool, onHidden: (NSWindow) -> Void) {
            let wasVisible = showsProjects
            showsProjects = visible
            // Save only expanded geometry; hiding Projects is not a persisted preference.
            if !visible { splitView.autosaveName = nil }
            projectsItem.isCollapsed = !visible
            if visible, splitView.autosaveName == nil {
                splitView.autosaveName = "copilot-projects.projects"
            }
            if wasVisible && !visible, let window = view.window {
                onHidden(window)
            }
        }

        override func viewDidLayout() {
            super.viewDidLayout()
            // Native autosave also restores collapse; scene visibility remains authoritative.
            if projectsItem.isCollapsed == showsProjects {
                projectsItem.isCollapsed = !showsProjects
            }
        }
    }
}
