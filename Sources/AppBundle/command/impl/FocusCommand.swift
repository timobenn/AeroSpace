import AppKit
import Common

struct FocusCommand: Command {
    let args: FocusCmdArgs

    func run(_ env: CmdEnv, _ io: CmdIo) -> Bool {
        guard let target = args.resolveTargetOrReportError(env, io) else { return false }
        // todo bug: floating windows break mru
        let floatingWindows = args.floatingAsTiling ? makeFloatingWindowsSeenAsTiling(workspace: target.workspace) : []
        defer {
            if args.floatingAsTiling {
                restoreFloatingWindows(floatingWindows: floatingWindows, workspace: target.workspace)
            }
        }

        switch args.target {
            case .direction(let direction):
                let window = target.windowOrNil
                if let (parent, ownIndex) = window?.closestParent(hasChildrenInDirection: direction, withLayout: nil) {
                    guard let windowToFocus = parent.children[ownIndex + direction.focusOffset]
                        .findFocusTargetRecursive(snappedTo: direction.opposite) else { return false }
                    return windowToFocus.focusWindow()
                } else {
                    return hitWorkspaceBoundaries(target, io, args, .cardinal(direction))
                }
            case .windowId(let windowId):
                if let windowToFocus = Window.get(byId: windowId) {
                    return windowToFocus.focusWindow()
                } else {
                    return io.err("Can't find window with ID \(windowId)")
                }
            case .dfsIndex(let dfsIndex):
                if let windowToFocus = target.workspace.rootTilingContainer.allLeafWindowsRecursive.getOrNil(atIndex: Int(dfsIndex)) {
                    return windowToFocus.focusWindow()
                } else {
                    return io.err("Can't find window with DFS index \(dfsIndex)")
                }
            case .dfsRelative(let dfsDirection):
                if let window = target.windowOrNil {
                    let workspaceWindows = target.workspace.rootTilingContainer.allLeafWindowsRecursive
                    if let currIndex = workspaceWindows.firstIndex(of: window) {
                        let dfsIndex = dfsDirection.isPositive ? currIndex + 1 : currIndex - 1
                        if let windowToFocus = workspaceWindows.getOrNil(atIndex: Int(dfsIndex)) {
                            return windowToFocus.focusWindow()
                        } else {
                            return hitWorkspaceBoundaries(target, io, args, .dfs(dfsDirection))
                        }
                    } else {
                        return io.err("Can't get index of current window")
                    }
                } else {
                    return hitWorkspaceBoundaries(target, io, args, .dfs(dfsDirection))
                }
        }
    }
}

@MainActor private func hitWorkspaceBoundaries(
    _ target: LiveFocus,
    _ io: CmdIo,
    _ args: FocusCmdArgs,
    _ direction: CardinalOrDfsDirection
) -> Bool {
    switch args.boundaries {
        case .workspace:
            return switch args.boundariesAction {
                case .stop: true
                case .fail: false
                case .wrapAroundTheWorkspace: wrapAroundTheWorkspace(target, io, direction)
                case .wrapAroundAllMonitors: errorT("Must be discarded by args parser")
            }
        case .allMonitorsUnionFrame:
            let currentMonitor = target.workspace.workspaceMonitor
            switch direction {
                case .dfs(let direction):
                    let monitors = sortedMonitors
                    guard let curIndex = monitors.firstIndex(where: { $0.rect.topLeftCorner == currentMonitor.rect.topLeftCorner }) else {
                        return io.err("Can't find current monitor")
                    }
                    let targetIndex = direction == .dfsNext ? curIndex + 1 : curIndex - 1
                    if let targetMonitor = monitors.getOrNil(atIndex: targetIndex) {
                        let workspaceWindows = targetMonitor.activeWorkspace.rootTilingContainer.allLeafWindowsRecursive
                        if direction.isPositive {
                            workspaceWindows.getOrNil(atIndex: 0)?.markAsMostRecentChild()
                        } else {
                            workspaceWindows.getOrNil(atIndex: workspaceWindows.count - 1)?.markAsMostRecentChild()
                        }
                        return targetMonitor.activeWorkspace.focusWorkspace()
                    } else {
                        guard let wrapped = monitors.get(wrappingIndex: targetIndex) else { return false }
                        return hitAllMonitorsOuterFrameBoundaries(target, io, args, .dfs(direction), wrapped)
                    }
                case .cardinal(let direction):
                    guard let (monitors, index) = currentMonitor.findRelativeMonitor(inDirection: direction) else {
                        return io.err("Can't find monitor in direction \(direction)")
                    }

                    if let targetMonitor = monitors.getOrNil(atIndex: index) {
                        return targetMonitor.activeWorkspace.focusWorkspace()
                    } else {
                        guard let wrapped = monitors.get(wrappingIndex: index) else { return false }
                        return hitAllMonitorsOuterFrameBoundaries(target, io, args, .cardinal(direction), wrapped)
                    }
            }
    }
}

@MainActor private func hitAllMonitorsOuterFrameBoundaries(
    _ target: LiveFocus,
    _ io: CmdIo,
    _ args: FocusCmdArgs,
    _ direction: CardinalOrDfsDirection,
    _ wrappedMonitor: Monitor
) -> Bool {
    switch args.boundariesAction {
        case .stop:
            return true
        case .fail:
            return false
        case .wrapAroundTheWorkspace:
            return wrapAroundTheWorkspace(target, io, direction)
        case .wrapAroundAllMonitors:
            switch direction {
            case .dfs(let direction):
                let workspaceWindows = wrappedMonitor.activeWorkspace.rootTilingContainer.allLeafWindowsRecursive
                if direction.isPositive {
                    workspaceWindows.getOrNil(atIndex: 0)?.markAsMostRecentChild()
                } else {
                    workspaceWindows.getOrNil(atIndex: workspaceWindows.count - 1)?.markAsMostRecentChild()
                }
            case .cardinal(let direction):
                wrappedMonitor.activeWorkspace.findFocusTargetRecursive(snappedTo: direction.opposite)?.markAsMostRecentChild()
            }

            return wrappedMonitor.activeWorkspace.focusWorkspace()
    }
}

@MainActor private func wrapAroundTheWorkspace(_ target: LiveFocus, _ io: CmdIo, _ direction: CardinalOrDfsDirection) -> Bool {
    let workspaceWindows = target.workspace.rootTilingContainer.allLeafWindowsRecursive
    guard let windowToFocus = switch direction {
        case .dfs(let direction):
            if direction.isPositive {
                workspaceWindows.getOrNil(atIndex: 0)
            } else {
                workspaceWindows.getOrNil(atIndex: workspaceWindows.count - 1)
            }
        case .cardinal(let direction):
            target.workspace.findFocusTargetRecursive(snappedTo: direction.opposite) 
    } else {
        return io.err(noWindowIsFocused)   
    }

    return windowToFocus.focusWindow()
}

@MainActor private func makeFloatingWindowsSeenAsTiling(workspace: Workspace) -> [FloatingWindowData] {
    let mruBefore = workspace.mostRecentWindowRecursive
    defer {
        mruBefore?.markAsMostRecentChild()
    }
    let floatingWindows: [FloatingWindowData] = workspace.floatingWindows
        .map { (window: Window) -> FloatingWindowData? in
            let center = window.getCenter() // todo bug: we shouldn't access ax api here. What if the window was moved but it wasn't committed to ax yet?
            guard let center else { return nil }
            // todo bug: what if there are no tiling windows on the workspace?
            guard let target = center.coerceIn(rect: workspace.workspaceMonitor.visibleRectPaddedByOuterGaps).findIn(tree: workspace.rootTilingContainer, virtual: true) else { return nil }
            guard let targetCenter = target.getCenter() else { return nil }
            guard let tilingParent = target.parent as? TilingContainer else { return nil }
            let index = center.getProjection(tilingParent.orientation) >= targetCenter.getProjection(tilingParent.orientation)
                ? target.ownIndex + 1
                : target.ownIndex
            let data = window.unbindFromParent()
            return FloatingWindowData(window: window, center: center, parent: tilingParent, adaptiveWeight: data.adaptiveWeight, index: index)
        }
        .filterNotNil()
        .sortedBy { $0.center.getProjection($0.parent.orientation) }
        .reversed()

    for floating in floatingWindows { // Make floating windows be seen as tiling
        floating.window.bind(to: floating.parent, adaptiveWeight: 1, index: floating.index)
    }
    return floatingWindows
}

@MainActor private func restoreFloatingWindows(floatingWindows: [FloatingWindowData], workspace: Workspace) {
    let mruBefore = workspace.mostRecentWindowRecursive
    defer {
        mruBefore?.markAsMostRecentChild()
    }
    for floating in floatingWindows {
        floating.window.bind(to: workspace, adaptiveWeight: floating.adaptiveWeight, index: INDEX_BIND_LAST)
    }
}

private struct FloatingWindowData {
    let window: Window
    let center: CGPoint

    let parent: TilingContainer
    let adaptiveWeight: CGFloat
    let index: Int
}

private extension TreeNode {
    func findFocusTargetRecursive(snappedTo direction: CardinalDirection) -> Window? {
        switch nodeCases {
            case .workspace(let workspace):
                return workspace.rootTilingContainer.findFocusTargetRecursive(snappedTo: direction)
            case .window(let window):
                return window
            case .tilingContainer(let container):
                if direction.orientation == container.orientation {
                    return (direction.isPositive ? container.children.last : container.children.first)?
                        .findFocusTargetRecursive(snappedTo: direction)
                } else {
                    return mostRecentChild?.findFocusTargetRecursive(snappedTo: direction)
                }
            case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer,
                 .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer:
                error("Impossible")
        }
    }
}
