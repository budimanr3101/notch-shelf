import AppKit
import SwiftUI

struct NotchShelfView: View {
    @ObservedObject var model: NotchOverlayModel

    private struct Layout {
        let bodyWidth: CGFloat
        let height: CGFloat
        let topRadius: CGFloat
        let bottomRadius: CGFloat

        var totalWidth: CGFloat { bodyWidth + topRadius * 2 }
    }

    private var layout: Layout {
        let notchWidth = model.hardwareWidth
        let notchHeight = model.hardwareHeight

        guard model.presented else {
            return Layout(
                bodyWidth: notchWidth,
                height: notchHeight,
                topRadius: 8,
                bottomRadius: 12
            )
        }

        switch model.state {
        case .staged where model.compact:
            return Layout(
                bodyWidth: notchWidth + 42,
                height: notchHeight + 17,
                topRadius: 9,
                bottomRadius: 18
            )

        case .staged:
            return Layout(
                bodyWidth: max(notchWidth + 108, 300),
                height: notchHeight + 48,
                topRadius: 13,
                bottomRadius: 28
            )

        case .moving:
            return Layout(
                bodyWidth: max(notchWidth + 118, 310),
                height: notchHeight + 50,
                topRadius: 13,
                bottomRadius: 30
            )

        case .success:
            return Layout(
                bodyWidth: notchWidth + 68,
                height: notchHeight + 22,
                topRadius: 10,
                bottomRadius: 22
            )

        case .failure:
            return Layout(
                bodyWidth: max(notchWidth + 128, 326),
                height: notchHeight + 54,
                topRadius: 14,
                bottomRadius: 30
            )
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear

            NotchShelfShape(
                topRadius: layout.topRadius,
                bottomRadius: layout.bottomRadius
            )
            .fill(.black)
            .frame(width: layout.totalWidth, height: layout.height)
            .shadow(
                color: model.presented ? .black.opacity(0.22) : .clear,
                radius: 7,
                x: 0,
                y: 3
            )

            if model.presented {
                VStack(spacing: 0) {
                    Color.clear
                        .frame(height: model.hardwareHeight)

                    shelfContent
                        .frame(
                            width: max(layout.bodyWidth - 28, 0),
                            height: max(layout.height - model.hardwareHeight, 0)
                        )
                }
                .frame(width: layout.bodyWidth, height: layout.height, alignment: .top)
                .transition(.opacity.combined(with: .offset(y: -10)))
            }
        }
        .frame(width: 460, height: 132, alignment: .top)
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: model.presented)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: model.compact)
        .animation(.spring(response: 0.38, dampingFraction: 0.84), value: model.state)
    }

    @ViewBuilder
    private var shelfContent: some View {
        switch model.state {
        case .staged where model.compact:
            compactStagedContent

        case .staged:
            HStack(spacing: 10) {
                stagedIcon(size: 24)

                VStack(alignment: .leading, spacing: 1) {
                    Text(model.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text("⌘V to move")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 6)

        case .moving:
            HStack(spacing: 10) {
                stagedIcon(size: 23)

                VStack(alignment: .leading, spacing: 1) {
                    Text(model.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(model.subtitle)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 2)

                ProgressView()
                    .controlSize(.mini)
                    .tint(.white)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 6)

        case .success:
            HStack(spacing: 7) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                Text(model.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)

        case .failure:
            HStack(spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))

                VStack(alignment: .leading, spacing: 1) {
                    Text(model.title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(model.subtitle)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
        }
    }

    private var compactStagedContent: some View {
        HStack(spacing: 6) {
            stagedIcon(size: 15)

            if model.itemCount > 1 {
                Text("\(model.itemCount)")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.86))
            }
        }
        .foregroundStyle(.white)
        .transition(.opacity.combined(with: .scale(scale: 0.84, anchor: .top)))
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
                .font(.system(size: size * 0.72, weight: .semibold))
                .frame(width: size, height: size)
        }
    }
}

/// Adapted from the notch silhouette approach used by jonnyoo/glance (MIT):
/// concave top flares merge into the menu-bar edge while Apple's continuous
/// bottom corners make the expansion read as part of the physical notch.
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
        let availableBodyHalfWidth = max(0, rect.width / 2 - top)
        let bottom = max(0, min(bottomRadius, min(availableBodyHalfWidth, rect.height)))

        var path = Path()

        // Concave flare into the screen edge on the left.
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
                path.addCurve(
                    to: segment.to,
                    control1: segment.control1,
                    control2: segment.control2
                )
            }

            path.addLine(to: corners.bottomEdgeRightReach)
            for segment in corners.right {
                path.addCurve(
                    to: segment.to,
                    control1: segment.control1,
                    control2: segment.control2
                )
            }

            path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        } else {
            // Defensive fallback for a future SwiftUI path-emission change.
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

        // Matching concave flare into the screen edge on the right.
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
        else {
            return nil
        }

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
