import AppKit
import SwiftUI

struct NotchShelfView: View {
    @ObservedObject var model: NotchOverlayModel

    private enum Metrics {
        // Closed geometry follows Glance's physical-notch silhouette.
        static let closedTopRadius: CGFloat = 8
        static let closedBottomRadius: CGFloat = 12

        // Do NOT use Glance's minimal bottom radius (22 on ~44pt height) here.
        // That ratio reads as a capsule. Keep the same notch silhouette language,
        // but use a shallower shelf expansion so it remains visibly notch-shaped.
        static let openTopRadius: CGFloat = 12
        static let openBottomRadius: CGFloat = 15
        static let flankWidth: CGFloat = 46
        static let heightBump: CGFloat = 18

        static let contentEdgeInset: CGFloat = 4
        static let contentWidth: CGFloat = 38
        static let windowSize = CGSize(width: 400, height: 96)

        static let openResponse: Double = 0.42
        static let openDamping: Double = 0.78
        static let closeResponse: Double = 0.38
        static let closeDamping: Double = 1.0
    }

    private var expandedBodySize: CGSize {
        CGSize(
            width: model.hardwareWidth + Metrics.flankWidth * 2,
            height: model.hardwareHeight + Metrics.heightBump
        )
    }

    private var closedBodySize: CGSize {
        CGSize(width: model.hardwareWidth, height: model.hardwareHeight)
    }

    private var bodySize: CGSize {
        model.presented ? expandedBodySize : closedBodySize
    }

    private var topRadius: CGFloat {
        model.presented ? Metrics.openTopRadius : Metrics.closedTopRadius
    }

    private var bottomRadius: CGFloat {
        model.presented ? Metrics.openBottomRadius : Metrics.closedBottomRadius
    }

    /// Same convention as Glance: the visible black body is inset by the top
    /// flare radius, so the fixed silhouette width includes 2x flare allowance.
    private var currentSize: CGSize {
        CGSize(
            width: bodySize.width + topRadius * 2,
            height: bodySize.height
        )
    }

    /// The physical/closed notch silhouette that is subtracted from the software
    /// expansion. This is the key difference from the previous implementation:
    /// NotchShelf never paints another black shape on top of/behind the hardware
    /// notch. It only paints pixels that exist OUTSIDE the closed notch footprint.
    private var closedSilhouetteSize: CGSize {
        CGSize(
            width: model.hardwareWidth + Metrics.closedTopRadius * 2,
            height: model.hardwareHeight
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            NotchExtensionLayer(
                expandedTopRadius: topRadius,
                expandedBottomRadius: bottomRadius,
                closedTopRadius: Metrics.closedTopRadius,
                closedBottomRadius: Metrics.closedBottomRadius,
                closedSilhouetteSize: closedSilhouetteSize
            )
            .frame(width: currentSize.width, height: currentSize.height)

            if model.presented {
                flankContent
                    .frame(width: currentSize.width, height: currentSize.height)
                    .transition(.opacity.combined(with: .scale(scale: 0.82, anchor: .top)))
            }
        }
        .frame(width: currentSize.width, height: currentSize.height, alignment: .top)
        .animation(
            model.presented
                ? .spring(response: Metrics.openResponse, dampingFraction: Metrics.openDamping)
                : .spring(response: Metrics.closeResponse, dampingFraction: Metrics.closeDamping),
            value: model.presented
        )
        .animation(.smooth(duration: 0.16), value: model.state)
        .frame(
            width: Metrics.windowSize.width,
            height: Metrics.windowSize.height,
            alignment: .top
        )
    }

    /// Glance-style flank layout: [left content] [physical camera cutout] [right content].
    /// The middle stays completely empty. The black underneath it is the real notch,
    /// not a second software capsule.
    private var flankContent: some View {
        HStack(spacing: 0) {
            leftFlank
                .frame(width: Metrics.contentWidth, height: currentSize.height)

            Spacer(minLength: 0)

            rightFlank
                .frame(width: Metrics.contentWidth, height: currentSize.height)
        }
        .padding(.horizontal, Metrics.contentEdgeInset + topRadius)
        .frame(width: currentSize.width, height: currentSize.height)
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var leftFlank: some View {
        switch model.state {
        case .staged, .moving:
            stagedIcon(size: 18)

        case .success:
            Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .bold))
                .contentTransition(.symbolEffect(.replace))

        case .failure:
            Image(systemName: "exclamationmark")
                .font(.system(size: 14, weight: .bold))
        }
    }

    @ViewBuilder
    private var rightFlank: some View {
        switch model.state {
        case .staged:
            if model.itemCount > 1 {
                Text("\(model.itemCount)")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
            } else {
                Image(systemName: "tray.full.fill")
                    .font(.system(size: 13, weight: .semibold))
            }

        case .moving:
            ProgressView()
                .controlSize(.mini)
                .tint(.white)

        case .success:
            Image(systemName: "tray.fill")
                .font(.system(size: 13, weight: .semibold))

        case .failure:
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
        }
    }

    @ViewBuilder
    private func stagedIcon(size: CGFloat) -> some View {
        if let icon = model.fileIcon, model.itemCount == 1 {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: model.itemCount > 1 ? "doc.on.doc.fill" : "doc.fill")
                .font(.system(size: size * 0.74, weight: .semibold))
                .frame(width: size, height: size)
        }
    }
}

/// Draws only the DELTA between the expanded software notch and the closed
/// physical-notch silhouette. Using destinationOut here prevents the app from
/// ever rendering a second full black notch/pill behind the real camera cutout.
private struct NotchExtensionLayer: View {
    let expandedTopRadius: CGFloat
    let expandedBottomRadius: CGFloat
    let closedTopRadius: CGFloat
    let closedBottomRadius: CGFloat
    let closedSilhouetteSize: CGSize

    var body: some View {
        Canvas { context, size in
            let expandedRect = CGRect(origin: .zero, size: size)
            let expandedPath = NotchShelfShape(
                topRadius: expandedTopRadius,
                bottomRadius: expandedBottomRadius
            ).path(in: expandedRect)

            context.fill(expandedPath, with: .color(.black))

            // Punch the real notch footprint out of our software layer.
            // The hole is top-centered because both Glance and NotchShelf anchor
            // the physical notch to the top center of the fixed transparent window.
            let closedOrigin = CGPoint(
                x: (size.width - closedSilhouetteSize.width) / 2,
                y: 0
            )
            let closedRect = CGRect(origin: closedOrigin, size: closedSilhouetteSize)
            let closedPath = NotchShelfShape(
                topRadius: closedTopRadius,
                bottomRadius: closedBottomRadius
            ).path(in: closedRect)

            context.blendMode = .destinationOut
            context.fill(closedPath, with: .color(.black))
        }
        .compositingGroup()
        .allowsHitTesting(false)
    }
}

/// Port of the physical-notch path used by jonnyoo/glance (MIT).
/// Top corners are concave flares into the menu bar. Bottom corners use
/// SwiftUI continuous-corner geometry rather than a capsule/rounded rectangle.
private struct NotchShelfShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let top = max(0, min(topRadius, rect.width / 2))
        let bodyHalfWidth = max(0, rect.width / 2 - top)
        let bottom = max(0, min(bottomRadius, min(bodyHalfWidth, rect.height)))

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top, y: rect.minY + top),
            control: CGPoint(x: rect.minX + top, y: rect.minY)
        )

        if let corners = ContinuousNotchCorner.bottomCorners(
            bodyRect: CGRect(
                x: rect.minX + top,
                y: rect.minY,
                width: rect.width - 2 * top,
                height: rect.height
            ),
            radius: bottom
        ) {
            path.addLine(to: corners.leftEdgeReach)
            for segment in corners.left {
                path.addCurve(to: segment.to, control1: segment.control1, control2: segment.control2)
            }
            path.addLine(to: corners.bottomEdgeRightReach)
            for segment in corners.right {
                path.addCurve(to: segment.to, control1: segment.control1, control2: segment.control2)
            }
            path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        } else {
            path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
                control: CGPoint(x: rect.minX + top, y: rect.maxY)
            )
            path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
                control: CGPoint(x: rect.maxX - top, y: rect.maxY)
            )
            path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        }

        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - top, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

private enum ContinuousNotchCorner {
    struct Segment {
        let control1: CGPoint
        let control2: CGPoint
        let to: CGPoint
    }

    struct BottomCorners {
        let leftEdgeReach: CGPoint
        let left: [Segment]
        let bottomEdgeRightReach: CGPoint
        let right: [Segment]
    }

    static func bottomCorners(bodyRect: CGRect, radius: CGFloat) -> BottomCorners? {
        let reference = UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: radius,
            bottomTrailingRadius: radius,
            topTrailingRadius: 0,
            style: .continuous
        ).path(in: bodyRect)

        var elements: [Path.Element] = []
        reference.forEach { elements.append($0) }

        guard elements.count >= 9,
              case .line(let p1) = elements[1],
              case .curve(let p2, let c2a, let c2b) = elements[2],
              case .curve(let p3, let c3a, let c3b) = elements[3],
              case .curve(let p4, let c4a, let c4b) = elements[4],
              case .line(let l5) = elements[5],
              case .curve(let p6, let c6a, let c6b) = elements[6],
              case .curve(let p7, let c7a, let c7b) = elements[7],
              case .curve(let p8, let c8a, let c8b) = elements[8]
        else { return nil }

        return BottomCorners(
            leftEdgeReach: p8,
            left: [
                Segment(control1: c8b, control2: c8a, to: p7),
                Segment(control1: c7b, control2: c7a, to: p6),
                Segment(control1: c6b, control2: c6a, to: l5),
            ],
            bottomEdgeRightReach: p4,
            right: [
                Segment(control1: c4b, control2: c4a, to: p3),
                Segment(control1: c3b, control2: c3a, to: p2),
                Segment(control1: c2b, control2: c2a, to: p1),
            ]
        )
    }
}
