import SwiftUI

// MARK: - Formulario

/// Un formulario: cada campo con su etiqueta, la validación al enviar y el botón. Al llegar, los
/// campos se cambian por el texto de «enviado». Los campos no son de cristal: van dentro de una
/// tarjeta que ya lo es (nunca cristal sobre cristal).
struct FormBlockView: View {
    let block: Block.Form
    let blockId: String
    @Environment(\.messagesTheme) private var theme
    @Environment(\.messageSurface) private var surface
    @Environment(\.messageLanguage) private var language
    @Environment(\.messageActionHandler) private var handler
    @State private var values: [String: String] = [:]
    /// El problema de cada campo: solo tras intentar enviar, y se quita al escribir en él.
    @State private var problems: [String: String] = [:]
    @State private var phase: Phase = .editing
    /// Id de la respuesta: el mismo al reintentar (el hub no la duplica), otro si cambia lo escrito.
    @State private var submissionId = UUID().uuidString.lowercased()
    @FocusState private var focused: String?

    enum Phase: Hashable { case editing, sending, sent, failed }

    var body: some View {
        Group {
            if phase == .sent {
                sentView.transition(.blurReplace)
            } else {
                formView.transition(.blurReplace)
            }
        }
        .animation(.smooth(duration: 0.35), value: phase)
        // Si cambia el formulario (editándolo en el admin), vuelve a empezar.
        .onChange(of: block) {
            phase = .editing
            problems = [:]
        }
    }

    // MARK: Campos

    private var formView: some View {
        VStack(spacing: 14) {
            ForEach(block.fields) { field in
                fieldView(field)
            }
            if phase == .failed {
                Label(L.string("No se ha podido enviar. Revisa la conexión e inténtalo otra vez.",
                               "Couldn't send it. Check your connection and try again.", language: language),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(theme.color("danger"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
            MessageButton(
                button: Block.Button(id: blockId, title: block.submitTitle, style: block.submitStyle, action: .dismiss),
                onTap: submit,
                isLoading: phase == .sending
            )
            .padding(.top, 2)
        }
        .animation(.smooth(duration: 0.2), value: problems)
    }

    private func fieldView(_ field: Block.Form.Field) -> some View {
        let problem = problems[field.id]
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return VStack(alignment: .leading, spacing: 6) {
            if !field.label.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(field.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.color("primaryText"))
                    if !field.required {
                        Text(L.string("Opcional", "Optional", language: language))
                            .font(.caption)
                            .foregroundStyle(theme.color("secondaryText"))
                    }
                }
                .fontDesign(theme.fontDesign)
                .accessibilityHidden(true)
            }
            input(field)
                .textFieldStyle(.plain)
                .font(.body)
                .fontDesign(theme.fontDesign)
                .foregroundStyle(theme.color("primaryText"))
                .tint(theme.accent)
                .focused($focused, equals: field.id)
                .submitLabel(field.id == block.fields.last?.id ? .send : .next)
                .onSubmit { advance(from: field) }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(minHeight: 48)
                .background(.fill.tertiary, in: shape)
                .overlay {
                    shape.strokeBorder(problem != nil ? theme.color("danger") : focused == field.id ? theme.accent.opacity(0.8) : .clear, lineWidth: 1.5)
                }
                .contentShape(shape)
                .onTapGesture { focused = field.id }
                .disabled(phase == .sending)
                .accessibilityLabel(field.label.isEmpty ? (field.placeholder ?? "") : field.label)
                .accessibilityHint(field.required ? L.string("Obligatorio", "Required", language: language) : "")
            if let problem {
                Text(problem)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(theme.color("danger"))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func input(_ field: Block.Form.Field) -> some View {
        let text = binding(field.id)
        let prompt = field.placeholder.map { Text($0).foregroundStyle(theme.color("secondaryText")) }
        let label = Text(field.label)
        if field.type == .multiline {
            TextField(text: text, prompt: prompt, axis: .vertical) { label }
                .lineLimit(3...6)
                .keyboard(for: field.type)
        } else {
            TextField(text: text, prompt: prompt) { label }
                .keyboard(for: field.type)
        }
    }

    /// Lo escrito en un campo. Al cambiarlo se quita su aviso y la respuesta pasa a ser otra.
    private func binding(_ id: String) -> Binding<String> {
        Binding(
            get: { values[id] ?? "" },
            set: { newValue in
                guard newValue != values[id] ?? "" else { return }
                values[id] = newValue
                problems[id] = nil
                submissionId = UUID().uuidString.lowercased()
                if phase == .failed { phase = .editing }
            }
        )
    }

    /// Intro en un campo: al siguiente, o envía si es el último.
    private func advance(from field: Block.Form.Field) {
        guard let i = block.fields.firstIndex(where: { $0.id == field.id }) else { return }
        if i + 1 < block.fields.count { focused = block.fields[i + 1].id } else { submit() }
    }

    // MARK: Enviar

    private func submit() {
        guard phase != .sending, phase != .sent else { return }
        var found: [String: String] = [:]
        for f in block.fields {
            if let p = f.problem(with: values[f.id] ?? "", language: language) { found[f.id] = p }
        }
        problems = found
        guard found.isEmpty else {
            focused = block.fields.first { found[$0.id] != nil }?.id
            return
        }
        focused = nil
        // Solo lo que tiene algo escrito, sin espacios a los lados. Una clave repetida: la primera.
        let clean = Dictionary(block.fields.compactMap { f -> (String, String)? in
            let v = (values[f.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? nil : (f.id, v)
        }, uniquingKeysWith: { first, _ in first })
        let submission = FormSubmission(id: submissionId, blockId: blockId, values: clean)
        phase = .sending
        Task {
            do {
                try await handler?.submit?(submission)
                phase = .sent
                AccessibilityNotification.Announcement(successText).post()
            } catch {
                phase = .failed
            }
        }
    }

    // MARK: Enviado

    private var successText: String {
        block.successText?.nonEmptyTrimmed ?? L.string("¡Gracias!", "Thank you!", language: language)
    }

    private var sentView: some View {
        let align = surface.defaultAlignment
        return VStack(alignment: align.horizontal, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(theme.color("positive"))
                .symbolEffect(.bounce, value: phase)
                .accessibilityHidden(true)
            MarkdownText(successText)
                .font(.headline)
                .fontDesign(theme.fontDesign)
                .foregroundStyle(theme.color("primaryText"))
                .multilineTextAlignment(align.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: align.frame)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

private extension String {
    var nonEmptyTrimmed: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

private extension View {
    /// Teclado y autorrelleno de cada tipo de campo (en el Mac no hay teclados distintos).
    @ViewBuilder
    func keyboard(for type: Block.Form.Field.FieldType) -> some View {
        #if os(iOS)
        switch type {
        case .email:
            keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        case .phone:
            keyboardType(.phonePad).textContentType(.telephoneNumber).autocorrectionDisabled()
        case .number:
            keyboardType(.decimalPad).autocorrectionDisabled()
        case .text, .multiline:
            self
        }
        #else
        switch type {
        case .email, .phone, .number: autocorrectionDisabled()
        case .text, .multiline: self
        }
        #endif
    }
}
