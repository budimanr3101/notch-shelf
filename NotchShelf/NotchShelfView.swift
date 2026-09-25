import SwiftUI

struct NotchShelfView: View {
    @ObservedObject var model: NotchOverlayModel

    private var symbol: String {
        switch model.state {
        case .staged: return model.itemCount > 1 ? "doc.on.doc.fill" : "doc.fill"
        case .moving: return "arrow.right.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        }
    }

    private var compactLabel: String {
        model.itemCount == 1 ? "1" : "\(model.itemCount)"
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.compact && model.state == .staged {
                HStack(spacing: 7) {
                    Image(systemName: "tray.full.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text(compactLabel)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white)
                .frame(width: 94, height: 34)
                .background(Color.black)
                .clipShape(Capsule())
                .transition(.scale(scale: 0.72).combined(with: .opacity))
            } else {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(.white.opacity(0.12))
                            .frame(width: 40, height: 40)
                        Image(systemName: symbol)
                            .font(.system(size: 17, weight: .semibold))
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text(model.subtitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 8)

                    if model.state == .moving {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 17)
                .frame(width: 330, height: 58)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .transition(.scale(scale: 0.82, anchor: .top).combined(with: .opacity))
            }
        }
        .frame(width: 360, height: 112, alignment: .top)
        .padding(.top, 2)
        .animation(.spring(response: 0.34, dampingFraction: 0.8), value: model.compact)
        .animation(.spring(response: 0.34, dampingFraction: 0.8), value: model.state)
    }
}
