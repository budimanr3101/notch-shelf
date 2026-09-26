import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Proven physical-notch geometry

struct PocketbookV3Wings: Shape {
    let geometry: NotchGeometry
    var expansion: CGFloat
    var extraDepth: CGFloat
    var wingWidth: CGFloat
    var maximumDepth: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { return AnimatablePair(AnimatablePair(expansion, extraDepth), wingWidth) }
        set {
            expansion = newValue.first.first
            extraDepth = newValue.first.second
            wingWidth = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        guard expansion > 0 else { return Path() }
        let progress = min(max(expansion, 0), 1.08)
        let extent = wingWidth * progress
        let overlap = NotchGeometry.connectionOverlap * min(progress, 1)
        let depth = min(max(extraDepth, 0), maximumDepth)
        let renderedHeight = geometry.hardwareHeight + depth
        let leftHardwareEdge = rect.midX - geometry.hardwareWidth / 2
        let rightHardwareEdge = rect.midX + geometry.hardwareWidth / 2

        let silhouette = PocketbookV3ShelfShape(
            topRadius: NotchGeometry.topRadius,
            bottomRadius: 16
        ).path(in: CGRect(
            x: leftHardwareEdge - extent - NotchGeometry.topRadius,
            y: rect.minY,
            width: geometry.hardwareWidth + 2 * (extent + NotchGeometry.topRadius),
            height: renderedHeight
        ))

        let leftJoin = leftHardwareEdge + overlap
        let rightJoin = rightHardwareEdge - overlap
        var drawableRegions = Path()
        drawableRegions.addRect(CGRect(
            x: rect.minX, y: rect.minY,
            width: max(0, leftJoin - rect.minX),
            height: geometry.hardwareHeight
        ))
        drawableRegions.addRect(CGRect(
            x: rightJoin, y: rect.minY,
            width: max(0, rect.maxX - rightJoin),
            height: geometry.hardwareHeight
        ))

        if depth > 0 {
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
        return silhouette.intersection(drawableRegions).intersection(bounds)
    }
}

struct PocketbookV3ShelfShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { return AnimatablePair(topRadius, bottomRadius) }
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

        if let corners = PocketbookV3ContinuousCorner.bottomCorners(bodyRect: bodyRect, radius: bottom) {
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

enum PocketbookV3ContinuousCorner {
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

struct PocketbookV3OuterEdge: Shape {
    let geometry: NotchGeometry
    var expansion: CGFloat
    var extraDepth: CGFloat
    var wingWidth: CGFloat
    var maximumDepth: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { return AnimatablePair(AnimatablePair(expansion, extraDepth), wingWidth) }
        set {
            expansion = newValue.first.first
            extraDepth = newValue.first.second
            wingWidth = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        guard expansion > 0 else { return Path() }
        let progress = min(max(expansion, 0), 1.08)
        let extent = wingWidth * progress
        let depth = min(max(extraDepth, 0), maximumDepth)
        let topRadius = NotchGeometry.topRadius
        let bottomRadius = min(CGFloat(16), depth / 2)
        let leftHardwareEdge = rect.midX - geometry.hardwareWidth / 2
        let rightHardwareEdge = rect.midX + geometry.hardwareWidth / 2
        let leftBody = leftHardwareEdge - extent
        let rightBody = rightHardwareEdge + extent
        let bottomY = geometry.hardwareHeight + depth

        var path = Path()
        path.move(to: CGPoint(x: leftBody - topRadius, y: 0))
        path.addQuadCurve(
            to: CGPoint(x: leftBody, y: topRadius),
            control: CGPoint(x: leftBody, y: 0)
        )
        path.addLine(to: CGPoint(x: leftBody, y: bottomY - bottomRadius))
        path.addQuadCurve(
            to: CGPoint(x: leftBody + bottomRadius, y: bottomY),
            control: CGPoint(x: leftBody, y: bottomY)
        )
        path.addLine(to: CGPoint(x: rightBody - bottomRadius, y: bottomY))
        path.addQuadCurve(
            to: CGPoint(x: rightBody, y: bottomY - bottomRadius),
            control: CGPoint(x: rightBody, y: bottomY)
        )
        path.addLine(to: CGPoint(x: rightBody, y: topRadius))
        path.addQuadCurve(
            to: CGPoint(x: rightBody + topRadius, y: 0),
            control: CGPoint(x: rightBody, y: 0)
        )
        return path
    }
}
