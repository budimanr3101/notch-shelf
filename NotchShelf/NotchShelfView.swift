import AppKit
import SwiftUI

struct NotchShelfView: View {
    @ObservedObject var model: NotchOverlayModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var footerDepth: CGFloat {
        guard model.presented else { return 0 }

        switch model.state {
        case .staged, .failure:
            return NotchGeometry.labelDepth
        case .moving, .success:
            return NotchGeometry.progressDepth
        }
    }

    var body: some View {
        if let geometry = model.geometry {
            let surface = NotchWings(
                geometry: geometry,
                expansion: model.presented ? 1 : 0,
                extraDepth: footerDepth
            )

            ZStack(alignment: .top) {
                surface.fill(.black)

                HStack(spacing: 0) {
                    leftStatus
                        .frame(width: NotchGeometry.wingWidth)

                    Color.clear
                        .frame(width: geometry.hardwareWidth)

                    rightStatus
                        .frame(width: NotchGeometry.wingWidth)
                }
                .frame(height: geometry.hardwareHeight)
                .opacity(model.presented ? 1 : 0)
                .frame(width: geometry.windowSize.width, alignment: .center)
                .mask(surface)

                if model.presented {
                    footer(for: geometry)
                        .offset(y: geometry.hardwareHeight)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                }
            }
            .frame(
                width: geometry.windowSize.width,
                height: geometry.windowSize.height,
                alignment: .top
            )
            .clipped()
            .animation(
                reduceMotion
                    ? nil
                    : .spring(
                        response: 0.4,
                        dampingFraction: model.presented ? 0.82 : 1.0
                    ),
                value: model.presented
            )
            .animation(
                reduceMotion ? nil : .spring(response: 0.30, dampingFraction: 0.9),
                value: model.state
            )
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func footer(for geometry: NotchGeometry) -> some View {
        switch model.state {
        case .staged:
            Text(model.itemLabel)
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(
                    width: footerWidth(for: geometry),
                    height: NotchGeometry.labelDepth,
                    alignment: .center
                )

        case .moving:
            progressFooter(
                title: "Moving…",
                geometry: geometry,
                success: false
            )

        case .success:
            progressFooter(
                title: "Done",
                geometry: geometry,
                success: true
            )

        case .failure:
            Text("Couldn't move")
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundStyle(.orange.opacity(0.95))
                .frame(
                    width: footerWidth(for: geometry),
                    height: NotchGeometry.labelDepth,
                    alignment: .center
                )
        }
    }

    private func progressFooter(
        title: String,
        geometry: NotchGeometry,
        success: Bool
    ) -> some View {
        VStack(spacing: 2.5) {
            Text(title)
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundStyle(
                    success ? Color.green.opacity(0.96) : Color.white.opacity(0.88)
                )
                .contentTransition(.opacity)

            progressBar(success: success)
                .frame(width: footerWidth(for: geometry), height: 2.5)
        }
        .frame(
            width: footerWidth(for: geometry),
            height: NotchGeometry.progressDepth,
            alignment: .center
        )
    }

    private func footerWidth(for geometry: NotchGeometry) -> CGFloat {
        geometry.hardwareWidth + 2 * (NotchGeometry.wingWidth - 8)
    }

    private func progressBar(success: Bool) -> some View {
        GeometryReader { proxy in
            let clamped = min(max(model.visualProgress, 0), 1)
            let fillWidth = max(2, proxy.size.width * clamped)
            let barColor: Color = success ? .green : .accentColor

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.13))

                Capsule()
                    .fill(barColor)
                    .frame(width: fillWidth)
                    .shadow(color: barColor.opacity(success ? 0.38 : 0.50), radius: 2.5)
                    .overlay(alignment: .trailing) {
                        if !success && fillWidth > 18 {
                            LinearGradient(
                                colors: [
                                    .clear,
                                    .white.opacity(0.72),
                                    .clear,
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: 20)
                            .clipShape(Capsule())
                            .blendMode(.screen)
                        }
                    }
            }
        }
        .animation(
            reduceMotion
                ? nil
                : (model.state == .success
                    ? .easeOut(duration: 0.30)
                    : .linear(duration: 0.13)),
            value: model.visualProgress
        )
        .animation(.easeInOut(duration: 0.18), value: model.state)
    }

    @ViewBuilder
    private var leftStatus: some View {
        switch model.state {
        case .success:
            Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.green)
                .transition(.scale(scale: 0.72).combined(with: .opacity))

        case .failure:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)

        case .staged, .moving:
            stagedIcon(size: 17)
        }
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
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.green)
                .transition(.scale(scale: 0.72).combined(with: .opacity))

        case .failure:
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.red)
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

/// Horizontal software wings around the real camera cutout. Staged adds only a
/// tiny footer for the filename. Moving/success grows a little farther downward
/// for a status label and progress rail, while the NSPanel itself stays fixed.
struct NotchWings: Shape {
    let geometry: NotchGeometry
    var expansion: CGFloat
    var extraDepth: CGFloat = 0

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(expansion, extraDepth) }
        set {
            expansion = newValue.first
            extraDepth = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        guard expansion > 0 else { return Path() }

        let progress = min(max(expansion, 0), 1.08)
        let extent = NotchGeometry.wingWidth * progress
        let overlap = NotchGeometry.connectionOverlap * min(progress, 1)
        let depth = min(max(extraDepth, 0), NotchGeometry.progressDepth)
        let renderedHeight = geometry.hardwareHeight + depth

        let leftHardwareEdge = rect.midX - geometry.hardwareWidth / 2
        let rightHardwareEdge = rect.midX + geometry.hardwareWidth / 2

        let silhouette = NotchShelfShape(
            topRadius: NotchGeometry.topRadius,
            bottomRadius: NotchGeometry.bottomRadius
        )
        .path(in: CGRect(
            x: leftHardwareEdge - extent - NotchGeometry.topRadius,
            y: rect.minY,
            width: geometry.hardwareWidth + 2 * (extent + NotchGeometry.topRadius),
            height: renderedHeight
        ))

        let leftJoin = leftHardwareEdge + overlap
        let rightJoin = rightHardwareEdge - overlap

        var drawableRegions = Path()
        drawableRegions.addRect(CGRect(
            x: rect.minX,
            y: rect.minY,
            width: max(0, leftJoin - rect.minX),
            height: geometry.hardwareHeight
        ))
        drawableRegions.addRect(CGRect(
            x: rightJoin,
            y: rect.minY,
            width: max(0, rect.maxX - rightJoin),
            height: geometry.hardwareHeight
        ))

        if depth > 0 {
            // The lower bridge connects the side wings beneath the real cutout.
            // It is the only region allowed to exist under the center, and only
            // for the small label/progress footer.
            let bridgeLeft = leftHardwareEdge - extent - NotchGeometry.topRadius
            let bridgeRight = rightHardwareEdge + extent + NotchGeometry.topRadius
            drawableRegions.addRect(CGRect(
                x: bridgeLeft,
                y: geometry.hardwareHeight - 1,
                width: bridgeRight - bridgeLeft,
                height: depth + 1
            ))
        }

        let flare = NotchGeometry.topRadius * min(progress, 1)
        let bounds = Path(CGRect(
            x: leftHardwareEdge - extent - flare,
            y: rect.minY,
            width: geometry.hardwareWidth + 2 * (extent + flare),
            height: renderedHeight
        ))

        return silhouette
            .intersection(drawableRegions)
            .intersection(bounds)
    }
}

/// Physical-notch silhouette adapted from jonnyoo/glance's MIT-licensed shape.
/// Concave top flares blend into the menu-bar edge; bottom corners use SwiftUI's
/// continuous-corner geometry rather than a capsule.
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

        if let corners = ContinuousNotchCorner.bottomCorners(
            bodyRect: bodyRect,
            radius: bottom
        ) {
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
        )
        .path(in: bodyRect)

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
              case .curve(let p8, let c8a, let c8b) = elements[8] else {
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
