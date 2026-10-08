import SwiftUI

/// The search field above the library grid (tech spec §10): a magnifier, the
/// text, and a clear (x) button at the right-hand end while there is text,
/// which empties the query. A plain `TextField` rather than `.searchable`,
/// which needs a navigation container the extension doesn't have.
///
/// Text styles only, so it follows Dynamic Type; the button keeps a 44 pt
/// touch target. The magnifier is decoration, so VoiceOver skips it and reads
/// the field's label.
struct LibrarySearchField: View {
    @Binding var query: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search stickers", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, query.isEmpty ? 12 : 0)
        .frame(minHeight: 44)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}
