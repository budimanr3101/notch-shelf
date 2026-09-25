import AppKit
import SwiftUI

struct NotchShelfView: View {
    @ObservedObject var model: NotchOverlayModel

    private enum Metrics {
        // These are the same minimal-notch proportions Glance uses.
        static let closedTopRadius: CGFloat = 8
        static let closedBottomRadius: CGFloat = 12
        static let openTopRadius: CGFloat = 12
        static let openBottomRadius: CGFloat = 22
        static let flankWidth: CGFloat = 42
        static let heightBump: CGFloat = 12
        static let contentEdgeInset: CGFloat = 4
        static let windowSize = CGSize(width: 380, height: 82)
    }

    private var bodySize: CGSize {
        if model.presented {
            return CGSize(
                width: model.hardwareWidth + Metrics.flankWidth * 2,
                height: model.hardwareHeight + Metrics.heightBump
            )
        }

        return CGSize(width: model.hardwareWidth, height: model.hardwareHeight)
    }

    private var topRadius: CGFloat {
        model.presented ? Metrics.openTopRadius : Metrics.closedTopRadius
    }

    private var bottomRadius: CGFloat {
        model.presented ? Metrics.openBottomRadius : Metrics.closedBottomRadius
    }

    // The flare is outside the real black body. Matching Glance here is the
    // important bit: the body width remains the measured hardware notch width
    // in the closed state, so it visually disappears into the physical cutout.
    private var currentSize: CGSize {
        CGSize(
            width: bodySize.width + topRadius * 2,
            height: bodySize.height
        )
    }

    var body: some View {
        ZStack {
            if model.presented {
                flankContent
                    .blur(radius: 0)
                    .opacity(1)
                    .scaleEffect(1)
            }
        }
        .frame(width: currentSize.width, height: currentSize.height)
        .background(Color.black)
        .clipShape(
            NotchShelfShape(
                topRadius: topRadius,
                bottomRadius: bottomRadius
            )
        )
        .shadow(
            color: .black.opacity(model.presented ? 0.30 : 0),
            radius: 9
        )
        .animation(
            model.presented
                ? .spring(response: 0.45, dampingFraction: 0.70)
                : .spring(response: 0.45, dampingFraction: 1.0),
            value: model.presented
        )
        .animation(.smooth(duration: 0.18), value: model.state)
        .frame(
            width: Metrics.windowSize.width,
            height: Metrics.windowSize.height,
            alignment: .top
        )
    }

    /// Same layout idea as Glance's MinimalUnlockView:
    /// [ left flank ][ physical camera cutout ][ right flank ]
    /// Nothing is drawn over the actual notch in the middle.
    private var flankContent: some View {
        HStack(spacing: 0) {
            leftFlank
                .frame(width: 40, height: currentSize.height)

            Spacer(minLength: 0)

            rightFlank
                .frame(width: 40, height: currentSize.height)
        }
        .padding(.horizontal, Metrics.contentEdgeInset + topRadius)
        .frame(width: currentSize.width, height: currentSize.height)
        .foregroundStyle(.white)
        .transition(.opacity.combined(with: .scale(scale: 0.72)))
    }

    @ViewBuilder
    private var leftFlank: some View {
        switch model.state {
        case .staged, .moving:
            stagedIcon(size: 18)

        case .success:
            Image(systemName: "checkmark")
                .font(.system(size: 15, weight: .bold))
                .contentTransition(.symbolEffect(.replace))

        case .failure:
            Image(systemName: "exclamationmark")
                .font(.system(size: 15, weight: .bold))
        }
    }

    @ViewBuilder
    private var rightFlank: some View {
        switch model.state {
        case .staged:
            if model.itemCount > 1 {
                Text("\(model.itemCount)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
            } else {
                Image(systemName: "tray.full.fill")
                    .font(.system(size: 14, weight: .semibold))
            }

        case .moving:
            ProgressView()
                .controlSize(.mini)
                .tint(.white)

        case .success:
            Image(systemName: "tray.fill")
                .font(.system(size: 14, weight: .semibold))

        case .failure:
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
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

/// Adapted from jonnyoo/glance's MIT-licensed NotchShape.
/// The top corners flare outward into the menu-bar edge; bottom corners use
/// SwiftUI's continuous geometry so the expansion reads as one physical notch.
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
        let bottom = max(0, min(bottomRadius, min(rect.width / 2 - top, rect.height)))

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
