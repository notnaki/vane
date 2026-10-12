import SwiftUI

struct PasswordGeneration: Equatable {
    let origin: PasswordOrigin
    let target: String
    let anchor: CGRect
}

/// Appears only beside a focused new-password field. No secret is retained in the card.
struct PasswordGenerationCard: View {
    let website: String
    var problem: String? = nil
    let use: (PasswordGenerator.Options) -> Void
    let dismiss: () -> Void
    @State private var options = PasswordGenerator.Options()

    var body: some View {
        VStack(alignment: .leading, spacing: Look.inset) {
            HStack {
                Label("Generate password", systemImage: "sparkles").font(Look.text.weight(.medium))
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Dismiss password generator")
            }
            Text(website).font(Look.caption).foregroundStyle(Look.inkSecondary).lineLimit(1)
            PasswordGeneratorOptions(options: $options)
            if let problem { Text(problem).font(Look.caption).foregroundStyle(Look.warning) }
            Button("Use generated password") { use(options) }
                .buttonStyle(.borderedProminent).disabled(!options.hasCharacters)
                .help("Fill the new password and its confirmation. The form will not be submitted.")
        }
        .padding(Look.cardInset).frame(maxWidth: .infinity, alignment: .leading)
        .background(Look.panelFill, in: .rect(cornerRadius: Look.pillRadius))
        .hairline(radius: Look.pillRadius)
        .shadow(color: Look.floatShadow, radius: Look.floatShadowRadius, y: Look.floatShadowY)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Password generator for \(website)")
    }
}

struct PasswordGeneratorOptions: View {
    @Binding var options: PasswordGenerator.Options
    var body: some View {
        VStack(alignment: .leading, spacing: Look.inset) {
            Stepper("\(options.length) characters", value: $options.length, in: 12...64)
                .accessibilityLabel("Password length").accessibilityValue("\(options.length) characters")
            HStack {
                VStack(alignment: .leading) {
                    Toggle("Lowercase", isOn: $options.lowercase)
                    Toggle("Uppercase", isOn: $options.uppercase)
                }
                Spacer(minLength: Look.inset)
                VStack(alignment: .leading) {
                    Toggle("Numbers", isOn: $options.digits)
                    Toggle("Symbols", isOn: $options.symbols)
                }
            }.toggleStyle(.checkbox)
        }.font(Look.caption)
    }
}
