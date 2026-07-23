// swift-format-ignore-file
// Distinct SwiftUI views with boilerplate modifier chains: the classic
// duplicate-detector false positive. Content differs; must stay silent.
import SwiftUI

struct TitleCard: View {
    var body: some View {
        Text("Title")
            .font(.headline)
            .padding(12)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct SubtitleCard: View {
    var body: some View {
        Label("Subtitle", systemImage: "star")
            .font(.subheadline)
            .padding(8)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
    }
}

struct FooterCard: View {
    var body: some View {
        HStack {
            Image(systemName: "clock")
            Text("Updated")
        }
        .font(.caption)
        .padding(6)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
