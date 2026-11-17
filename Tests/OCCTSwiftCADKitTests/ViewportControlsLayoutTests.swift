import Combine
import Foundation
import OCCTSwiftViewport
import SwiftUI
import Testing

@testable import OCCTSwiftCADKit

#if canImport(AppKit)
    import AppKit
    import Metal
#endif

/// Holds down the layout rule that keeps the display-mode controls off the view cube.
///
/// OCCTSwiftInteraction#44: the controls drew over the cube in the default corner. None of this
/// needs a Metal device: the controls are laid out by SwiftUI over a placeholder in an
/// `ImageRenderer`, and their frame is read back through `controlsFrameObserver`.
///
/// `ViewCubeModel` is the oracle: what OCCTSwiftViewport 1.3.2 draws, written out as literals
/// rather than read back from `ViewportControlsLayout`, so the rule is checked against the cube
/// and not against its own constants. `viewCubeFootprintMatchesViewportSource` checks the oracle.
@MainActor
@Suite("CADViewportView controls layout")
struct ViewportControlsLayoutTests {
    /// The cube's frame inside a viewport of `viewport` size, in y-down coordinates.
    private enum ViewCubeModel {
        static let side: CGFloat = 96
        static let margin: CGFloat = 12

        static func frame(at position: _ViewCubePosition, in viewport: CGSize) -> CGRect {
            let leading = position == .topLeading || position == .bottomLeading
            let top = position == .topLeading || position == .topTrailing
            return CGRect(
                x: leading ? margin : viewport.width - margin - side,
                y: top ? margin : viewport.height - margin - side,
                width: side,
                height: side)
        }
    }

    /// The controls' own frame, as laid out by SwiftUI in a viewport of `viewport` size.
    private func controlsFrame(of view: CADViewportView, in viewport: CGSize) throws -> CGRect {
        let collected = CollectedFrame()
        var observed = view
        observed.controlsFrameObserver = { collected.frame = $0 }
        let renderer = ImageRenderer(
            content: observed.overlays(on: Color.clear)
                .frame(width: viewport.width, height: viewport.height))
        renderer.proposedSize = ProposedViewSize(viewport)
        _ = renderer.cgImage
        return try #require(collected.frame, "the controls reported no frame")
    }

    private func controlsFrame(
        cube position: _ViewCubePosition, shown: Bool = true, in viewport: CGSize
    ) throws -> CGRect {
        let controller = _ViewportController(
            configuration: _ViewportConfiguration(
                showViewCube: shown, viewCubePosition: position))
        return try controlsFrame(
            of: CADViewportView(bodies: [], controller: controller), in: viewport)
    }

    private func overlapArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let overlap = a.intersection(b)
        return overlap.isNull ? 0 : overlap.width * overlap.height
    }

    /// Phone and desktop viewports, from the narrowest portrait to a large display.
    private static let viewports: [CGSize] = [
        CGSize(width: 320, height: 480),
        CGSize(width: 390, height: 844),
        CGSize(width: 800, height: 600),
        CGSize(width: 1440, height: 900),
        CGSize(width: 2560, height: 1440),
    ]

    @Test("the controls clear the cube, with the margin to spare, whichever corner it is in")
    func controlsClearTheCubeInEveryCorner() throws {
        for position in _ViewCubePosition.allCases {
            for viewport in Self.viewports {
                let controls = try controlsFrame(cube: position, in: viewport)
                let cube = ViewCubeModel.frame(at: position, in: viewport)
                let label = "cube \(position), viewport \(viewport), controls \(controls)"

                #expect(controls.width > 0 && controls.height > 0, "empty controls: \(label)")
                #expect(
                    overlapArea(controls.insetBy(dx: -8, dy: -8), cube) == 0,
                    "controls within a margin of the cube: \(label)")
                #expect(
                    CGRect(origin: .zero, size: viewport).contains(controls),
                    "controls pushed out of the viewport: \(label)")
            }
        }
    }

    @Test("the default cube corner, bottom-trailing, lifts the controls onto the cube's top edge")
    func defaultCornerStacksTheControlsOnTheCube() throws {
        let viewport = CGSize(width: 800, height: 600)
        let controls = try controlsFrame(cube: .bottomTrailing, in: viewport)
        let cube = ViewCubeModel.frame(at: .bottomTrailing, in: viewport)

        // Resting on the cube: one margin above its top edge, and the same margin from the side.
        #expect(cube.minY - controls.maxY == 8)
        #expect(viewport.width - controls.maxX == 8)
    }

    @Test("the service's default configuration, the case the issue reports, clears the cube")
    func serviceDefaultConfigurationClearsTheCube() throws {
        let service = CADViewportService()
        #expect(service.controller.configuration.viewCubePosition == .bottomTrailing)
        #expect(service.controller.showViewCube)

        let viewport = CGSize(width: 800, height: 600)
        let controls = try controlsFrame(of: CADViewportView(service: service), in: viewport)
        let cube = ViewCubeModel.frame(at: .bottomTrailing, in: viewport)

        #expect(overlapArea(controls, cube) == 0)
    }

    @Test(
        "a cube in another corner leaves the controls exactly where they have always been",
        arguments: [_ViewCubePosition.topLeading, .topTrailing, .bottomLeading])
    func otherCornersLeaveTheControlsAlone(position: _ViewCubePosition) throws {
        let viewport = CGSize(width: 800, height: 600)
        let controls = try controlsFrame(cube: position, in: viewport)

        #expect(viewport.width - controls.maxX == 8)
        #expect(viewport.height - controls.maxY == 8)
    }

    @Test(
        "a hidden cube leaves the controls where they have always been",
        arguments: _ViewCubePosition.allCases)
    func hiddenCubeLeavesTheControlsAlone(position: _ViewCubePosition) throws {
        let viewport = CGSize(width: 800, height: 600)
        let controls = try controlsFrame(cube: position, shown: false, in: viewport)

        #expect(viewport.width - controls.maxX == 8)
        #expect(viewport.height - controls.maxY == 8)
    }

    @Test("a cube moved to top-trailing, as ACADStudio does, keeps the controls where they were")
    func topTrailingCubeIsUnchanged() throws {
        var configuration = CADViewportService().controller.configuration
        configuration.viewCubePosition = .topTrailing
        let service = CADViewportService(configuration: configuration)
        let viewport = CGSize(width: 800, height: 600)
        let controls = try controlsFrame(of: CADViewportView(service: service), in: viewport)

        #expect(viewport.width - controls.maxX == 8)
        #expect(viewport.height - controls.maxY == 8)
    }

    @Test("the clearance is the cube's footprint in its own corner and nothing elsewhere")
    func clearanceRule() {
        for position in _ViewCubePosition.allCases {
            let shown = ViewportControlsLayout.bottomClearance(
                viewCubeVisible: true, viewCubePosition: position)
            let hidden = ViewportControlsLayout.bottomClearance(
                viewCubeVisible: false, viewCubePosition: position)

            #expect(shown == (position == .bottomTrailing ? 108 : 0), "cube \(position) shown")
            #expect(hidden == 0, "cube \(position) hidden")
        }
    }

    @Test("the view re-reads the cube's visibility, so toggling it moves the controls live")
    func viewFollowsTheCubeBeingToggled() {
        let controller = _ViewportController(
            configuration: _ViewportConfiguration(
                showViewCube: true, viewCubePosition: .bottomTrailing))
        let view = CADViewportView(bodies: [], controller: controller)

        // Toggling the flag announces a change to anything observing the controller...
        var announcements = 0
        let subscription = controller.objectWillChange.sink { announcements += 1 }
        controller.showViewCube = false
        #expect(announcements == 1)
        subscription.cancel()

        // ...the view observes its controller, so that announcement re-evaluates it...
        #expect(
            Mirror(reflecting: view).children.contains {
                $0.value is ObservedObject<_ViewportController>
            })

        // ...and each evaluation reads the flag afresh.
        #expect(view.controlsBottomClearance == 0)
        controller.showViewCube = true
        #expect(view.controlsBottomClearance == 108)
    }

    @Test("a viewport too short to lift the controls keeps them on its bottom edge")
    func shortViewportKeepsTheControlsOnScreen() throws {
        for height in [60, 100, 140] as [CGFloat] {
            let viewport = CGSize(width: 800, height: height)
            let controls = try controlsFrame(cube: .bottomTrailing, in: viewport)

            #expect(
                CGRect(origin: .zero, size: viewport).contains(controls),
                "viewport \(viewport), controls \(controls)")
            #expect(viewport.height - controls.maxY == 8, "viewport \(viewport)")
        }
    }

    #if canImport(AppKit)
        /// Hosts the real view, Metal viewport included, so the whole of `body` and the controller's
        /// observation are in play, which the placeholder renders above cannot show.
        @Test(
            "hosted for real, the controls follow the cube being hidden and shown again",
            .enabled(if: MTLCreateSystemDefaultDevice() != nil, "the viewport needs a Metal device")
        )
        func hostedControlsFollowTheCube() async throws {
            let controller = _ViewportController(
                configuration: _ViewportConfiguration(
                    showViewCube: true, viewCubePosition: .bottomTrailing))
            let size = CGSize(width: 800, height: 600)
            let collected = CollectedFrame()
            var view = CADViewportView(bodies: [], controller: controller)
            view.controlsFrameObserver = { collected.frame = $0 }
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
            host.frame = CGRect(origin: .zero, size: size)

            func gapBelowControls() async throws -> CGFloat {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded()
                return try size.height - #require(collected.frame).maxY
            }

            #expect(try await gapBelowControls() == 116)
            controller.showViewCube = false
            #expect(try await gapBelowControls() == 8)
            controller.showViewCube = true
            #expect(try await gapBelowControls() == 116)
        }
    #endif

    /// Reads OCCTSwiftViewport's `viewCubeOverlay` out of the resolved checkout, so a change to
    /// the cube's size or margin there fails here instead of putting the controls back on it.
    @Test(
        "the cube's footprint in this file's model is what OCCTSwiftViewport draws",
        .enabled(
            if: ViewportControlsLayoutTests.viewportSource() != nil,
            "no OCCTSwiftViewport checkout beside the build products, in .build or in SourcePackages"
        ))
    func viewCubeFootprintMatchesViewportSource() throws {
        let (file, source) = try #require(Self.viewportSource())
        let overlay = try #require(
            Self.block(of: "viewCubeOverlay", in: source),
            "viewCubeOverlay is gone from \(file.path)")

        let frame = try #require(
            overlay.firstMatch(of: /\.frame\(width: (\d+), height: (\d+)\)/),
            "the cube no longer has a fixed square frame in \(file.path)")
        #expect(CGFloat(Int(frame.1) ?? -1) == ViewCubeModel.side, "in \(file.path)")
        #expect(CGFloat(Int(frame.2) ?? -1) == ViewCubeModel.side, "in \(file.path)")

        let padding = try #require(
            overlay.firstMatch(of: /\.padding\((\d+)\)/),
            "the cube no longer has plain padding in \(file.path)")
        #expect(CGFloat(Int(padding.1) ?? -1) == ViewCubeModel.margin, "in \(file.path)")

        #expect(
            overlay.contains("controller.configuration.viewCubePosition.overlayAlignment"),
            "the cube is no longer aligned by configuration.viewCubePosition in \(file.path)")
    }

    /// `MetalViewportView.swift` and its text, from the resolved OCCTSwiftViewport checkout, if any.
    ///
    /// SwiftPM keeps `checkouts` beside the build products, wherever `--scratch-path` put them, and
    /// Xcode keeps them in `SourcePackages`, so this looks upward from the test bundle first. It
    /// then looks upward from this file as far as the package root and no further, so a checkout
    /// belonging to some other project is never read.
    private nonisolated static func viewportSource() -> (file: URL, text: String)? {
        let relative =
            "checkouts/OCCTSwiftViewport/Sources/OCCTSwiftViewport/Views/MetalViewportView.swift"
        let starts = [
            (Bundle(for: BundleToken.self).bundleURL, stopsAtPackageRoot: false),
            (URL(fileURLWithPath: #filePath), stopsAtPackageRoot: true),
        ]
        for (start, stopsAtPackageRoot) in starts {
            var directory = start
            while directory.path != "/" {
                for candidate in [relative, ".build/" + relative, "SourcePackages/" + relative] {
                    let file = directory.appendingPathComponent(candidate)
                    if let text = try? String(contentsOf: file, encoding: .utf8) {
                        return (file, text)
                    }
                }
                if stopsAtPackageRoot,
                    FileManager.default.fileExists(
                        atPath: directory.appendingPathComponent("Package.swift").path)
                {
                    break
                }
                directory.deleteLastPathComponent()
            }
        }
        return nil
    }

    /// The declaration body of the property called `name`, up to the next `// MARK:`.
    private static func block(of name: String, in source: String) -> String? {
        guard let start = source.range(of: "var \(name)") else { return nil }
        let rest = source[start.lowerBound...]
        let end = rest.range(of: "// MARK:")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }
}

/// Collects the controls' frame from the observer seam.
@MainActor
private final class CollectedFrame {
    var frame: CGRect?
}

/// Anchors `Bundle(for:)` to the test bundle.
private final class BundleToken {}
