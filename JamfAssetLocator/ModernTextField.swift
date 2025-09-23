//
//  ModernTextField.swift
//  JamfAssetLocator
//
//  Created by Gabriel Marcelino on 8/14/25.
//

import SwiftUI
import UIKit

struct ModernTextField: View {
    let placeholder: String
    @Binding var text: String

    // Optional content type for better autofill (nil == none)
    let contentType: UITextContentType?
    // SwiftUI’s autocapitalization (iOS 15+) uses TextInputAutocapitalization
    let capitalization: TextInputAutocapitalization
    // Keyboard and autocorrection controls
    let keyboard: UIKeyboardType
    let autocorrection: Bool

    init(
        placeholder: String,
        text: Binding<String>,
        contentType: UITextContentType? = nil,
        capitalization: TextInputAutocapitalization = .sentences,
        keyboard: UIKeyboardType = .default,
        autocorrection: Bool = true
    ) {
        self.placeholder = placeholder
        self._text = text
        self.contentType = contentType
        self.capitalization = capitalization
        self.keyboard = keyboard
        self.autocorrection = autocorrection
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .textInputAutocapitalization(capitalization)
            .keyboardType(keyboard)
            .autocorrectionDisabled(!autocorrection)
            .textContentType(contentType) // Pass through the optional directly
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
