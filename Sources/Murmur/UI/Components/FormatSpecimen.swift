import MurmurCore
import SwiftUI

/// The shape a format gives the text, drawn as a miniature: bars for lines, never invented words, so it shows the
/// shape without claiming what Hushy would write. Your own format shows its instruction instead.
enum FormatShape: Equatable {
    case plain, email, message, note, bullets
    case custom(String)

    init(_ mode: Mode) {
        switch mode.id {
        case Mode.BuiltInID.email: self = .email
        case Mode.BuiltInID.message: self = .message
        case Mode.BuiltInID.note: self = .note
        case Mode.BuiltInID.bulletPoints: self = .bullets
        case Mode.BuiltInID.default where !mode.isTransform: self = .plain
        default:
            let prompt = mode.prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self = prompt.isEmpty ? .plain : .custom(prompt)
        }
    }
}

/// A sunken well holding a sheet of paper that runs off its bottom edge, the format's shape drawn on it. Under the
/// pointer the sheet rises a little, as if being pulled out to read.
struct FormatSpecimen: View {
    let shape: FormatShape
    let isHot: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let well = RoundedRectangle(cornerRadius: 8, style: .continuous)
        ZStack(alignment: .top) {
            well.fill(Theme.well(scheme).shadow(.inner(color: .black.opacity(scheme == .dark ? 0.45 : 0.06), radius: 2, y: 1)))
            if shape == .message {
                messages.padding(.horizontal, 14).padding(.top, 14)
            } else {
                sheet
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .offset(y: isHot && !reduceMotion ? -4 : 0)
            }
        }
        .frame(height: 92)
        .clipShape(well)
        .animation(Theme.Motion.lift, value: isHot)
        .accessibilityHidden(true)
    }

    private var ink: Color { Theme.textTertiary.opacity(isHot ? 0.5 : 0.32) }
    private var accent: Color { isHot ? Theme.phosphor.opacity(0.8) : Theme.textTertiary.opacity(0.62) }

    private var sheet: some View {
        content
            .padding(.horizontal, 12).padding(.top, 11)
            .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
            .background(UnevenRoundedRectangle(topLeadingRadius: 5, topTrailingRadius: 5, style: .continuous)
                .fill(scheme == .dark ? Color(hex: 0x22252B) : Theme.bgRaised)
                .shadow(color: .black.opacity(scheme == .dark ? 0.5 : (isHot ? 0.14 : 0.08)), radius: isHot ? 6 : 3, y: isHot ? 2 : 1))
    }

    @ViewBuilder private var content: some View {
        switch shape {
        case .plain, .message:
            VStack(alignment: .leading, spacing: 6) { bar(1); bar(0.92); bar(0.97); bar(0.55) }
        case .email:
            VStack(alignment: .leading, spacing: 5) {
                bar(0.3, color: accent)
                bar(0.95).padding(.top, 3); bar(0.82); bar(0.6)
                HStack(spacing: 4) { bar(0, color: accent, fixed: 30); bar(0, fixed: 24) }.padding(.top, 3)
            }
        case .note:
            VStack(alignment: .leading, spacing: 6) {
                bar(0.5, color: accent, height: 7)
                bar(0.9).padding(.top, 2); bar(0.72); bar(0.84)
            }
        case .bullets:
            VStack(alignment: .leading, spacing: 8) {
                ForEach([0.78, 0.6, 0.7], id: \.self) { width in
                    HStack(spacing: 7) {
                        Circle().fill(accent).frame(width: 5, height: 5)
                        bar(width)
                    }
                }
            }
        case .custom(let instruction):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(accent)
                Text(instruction)
                    .font(.system(size: 11.5, design: .serif)).italic()
                    .foregroundStyle(isHot ? Theme.textSecondary : Theme.textTertiary)
                    .lineLimit(3)
            }
        }
    }

    private var messages: some View {
        VStack(alignment: .leading, spacing: 6) {
            bubble(widths: [92, 58], isMine: false)
            bubble(widths: [70], isMine: true)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .offset(y: isHot && !reduceMotion ? -3 : 0)
        }
    }

    private func bar(_ fraction: CGFloat, color: Color? = nil, height: CGFloat = 5, fixed: CGFloat? = nil) -> some View {
        GeometryReader { proxy in
            Capsule().fill(color ?? ink).frame(width: fixed ?? proxy.size.width * fraction, height: height)
        }
        .frame(width: fixed, height: height)
    }

    private func bubble(widths: [CGFloat], isMine: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(widths.enumerated()), id: \.offset) { _, width in
                Capsule().fill(isMine && isHot ? Theme.onPhosphor.opacity(0.35) : ink).frame(width: width, height: 5)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(UnevenRoundedRectangle(
            topLeadingRadius: 11, bottomLeadingRadius: isMine ? 11 : 3, bottomTrailingRadius: isMine ? 3 : 11,
            topTrailingRadius: 11, style: .continuous)
            .fill(isMine ? (isHot ? Theme.phosphorFill.opacity(0.6) : Theme.textTertiary.opacity(0.18))
                  : (scheme == .dark ? Color(hex: 0x22252B) : Theme.bgRaised))
            .shadow(color: .black.opacity(isMine || scheme == .dark ? 0 : 0.06), radius: 2, y: 1))
    }
}
