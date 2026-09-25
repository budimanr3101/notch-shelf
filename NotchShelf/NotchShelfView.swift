import AppKit
import SwiftUI

struct NotchShelfView: View {
    @ObservedObject var model: NotchOverlayModel

    private enum Metrics {
        // Horizontal-only mode: the software extension is never taller than the
        // physical notch. These radii intentionally stay identical while opening.
        static let topRadius: CGFloat = 8
        static let bottomRadius: CGFloat = 12
        static let flankWidth: CGFloat = 54
        static let contentWidth: CGFloat = 40
        static let contentEdgeInset: CGFloat = 4
        static let windowSize = CGSize(width: 400, height: 64)

        static let openResponse: Double = 0.34
        static let openDamping: Double = 0.82
        static let closeResponse: Double = 0.28
        static let closeDamping: Double = 1.0
    }

    private var bodyWidth: CGFloat {
        model.hardwareWidth + (model.presented ? Metrics.flankWidth * 2 : 0)
    }

    // Critical invariant: NotchShelf never grows downward.
    private var bodyHeight: CGFloat {
        model.hardwareHeight
    }

    private var currentSize: CGSize {
        CGSize(
            width: bodyWidth + Metrics.topRadius * 2,
            height: bodyHeight
        )
    }

    private var closedSilhouetteSize: CGSize {
        CGSize(
            width: model.hardwareWidth + Metrics.topRadius * 2,
            height: model.hardwareHeight
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            NotchExtensionLayer(
                topRadius: Metrics.topRadius,
                bottomRadius: Metrics.bottomRadius,
                closedSilhouetteSize: closedSilhouetteSize
            )
            .frame(width: currentSize.width, height: currentSize.height)

            if model.presented {
                flankContent
                    .frame(width: currentSize.width, height: currentSize.height)
                    .transition(.opacity)
            }
        }
        .frame(width: currentSize.width, height: currentSize.height, alignment: .top)
        .animation(
            model.presented
                ? .spring(response: Metrics.openResponse, dampingFraction: Metrics.openDamping)
                : .spring(response: Metrics.closeResponse, dampingFraction: Metrics.closeDamping),
            value: model.presented
        )
        .animation(.smooth(duration: 0.14), value: model.state)
        .frame(
            width: Metrics.windowSize.width,
            height: Metrics.windowSize.height,
            alignment: .top
        )
    }

    // Layout is deliberately [small icon] [real hardware notch] [small status].
    // The center remains empty and transparent in software.
    private var flankContent: some View {
        HStack(spacing: 0) {
            stagedIcon(size: 17)
                .frame(width: Metrics.contentWidth, height: bodyHeight)

            Spacer(minLength: 0)

            rightStatus
                .frame(width: Metrics.contentWidth, height: bodyHeight)
        }
        .padding(.horizontal, Metrics.contentEdgeInset + Metrics.topRadius)
        .frame(width: currentSize.width, height: bodyHeight)
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var rightStatus: some View {
        switch model.state {
        case .staged:
            if model.itemCount > 1 {
                Text("\(model.itemCount)")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
            } else {
                Image(systemName: "tray.full.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
            }

        case .moving:
            ProgressView()
                .controlSize(.mini)
                .tint(.white)

        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.green)
                .contentTransition(.symbolEffect(.replace))

        case .failure:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.red)
                .contentTransition(.symbolEffect(.replace))
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
                .foregroundStyle(.white.opacity(0.94))
        }
    }
}

/// Draws only the extra pixels outside the physical notch footprint. The center
/// is punched out, so NotchShelf never paints a second black notch behind the
/// real camera housing.
private struct NotchExtensionLayer: View {
    let topRadius: CGFloat
    let bottomRadius: CGFloat
    let closedSilhouetteSize: CGSize

    var body: some View {
        Canvas { context, size in
            let expandedPath = NotchShelfShape(
                topRadius: topRadius,
                bottomRadius: bottomRadius
            ).path(in: CGRect(origin: .zero, size: size))

            context.fill(expandedPath, with: .color(.black))

            let closedRect = CGRect(
                x: (size.width - closedSilhouetteSize.width) / 2,
                y: 0,
                width: closedSilhouetteSize.width,
                height: closedSilhouetteSize.height
            )
            let closedPath = NotchShelfShape(
                topRadius: topRadius,
                bottomRadius: bottomRadius
            ).path(in: closedRect)

            context.blendMode = .destinationOut
            context.fill(closedPath, with: .color(.black))
        }
        .compositingGroup()
        .allowsHitTesting(false)
    }
}

/// Port of the physical-notch silhouette approach used by jonnyoo/glance (MIT).
/// It keeps concave top flares and continuous bottom corners, but in NotchShelf
/// the silhouette only widens; its height never changes.
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

        let bodyRect = CGRect(
            x: rect.minX + top,
            y: rect.minY,
            width: rect.width - 2 * top,
            height: rect.height
        )

        if let corners = ContinuousNotchCorner.bottomCorners(bodyRect: bodyRect, radius: bottom) {
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
