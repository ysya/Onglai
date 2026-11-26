import SwiftUI
import AlinFoundation

struct UtilitySearchField: View {
    let prompt: LocalizedStringKey
    @Binding var text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let colors = ThemeColors.shared(for: colorScheme)
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(colors.secondaryText)
                .accessibilityHidden(true)

            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .foregroundStyle(colors.primaryText)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(colors.secondaryText)
                }
                .buttonStyle(.plain)
                .help("Clear Search")
                .accessibilityLabel("Clear Search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .controlGroup(Capsule(style: .continuous), level: .primary)
    }
}

struct UtilityPageStatus: View {
    let title: LocalizedStringKey
    var systemImage: String? = nil
    var detail: LocalizedStringKey? = nil
    var action: (title: LocalizedStringKey, perform: () -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let colors = ThemeColors.shared(for: colorScheme)
        VStack(spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(colors.accent)
                    .accessibilityHidden(true)
            } else {
                ProgressView()
            }

            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(colors.primaryText)

            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(colors.secondaryText)
                    .frame(maxWidth: 350)
            }

            if let action {
                Button(action.title, action: action.perform)
                    .buttonStyle(.bordered)
            }
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
