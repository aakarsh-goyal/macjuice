import SwiftUI

/// Liquid Glass segmented control. One persistent interactive-glass capsule
/// slides between equal-width segments — the lensing travels with it, and the
/// labels always render above the glass (putting glass in a sibling layer
/// gets z-hoisted over the text and ruins readability). Mouse-first: no
/// keyboard focus ring.
@available(macOS 26.0, *)
struct GlassSegmentedControl<T>: View
where T: Hashable & Identifiable & RawRepresentable, T.RawValue == String {
    @Binding var selection: T
    let items: [T]
    var segmentWidth: CGFloat = 56

    private let height: CGFloat = 22

    private var selectedIndex: Int {
        items.firstIndex(of: selection) ?? 0
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(.clear)
                .glassEffect(.regular.interactive(), in: Capsule())
                .frame(width: segmentWidth, height: height)
                .offset(x: CGFloat(selectedIndex) * segmentWidth)
            HStack(spacing: 0) {
                ForEach(items) { item in
                    Button {
                        selection = item
                    } label: {
                        Text(item.rawValue)
                            .font(.system(size: 11, weight: item == selection ? .semibold : .medium))
                            .foregroundStyle(item == selection ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                            .frame(width: segmentWidth, height: height)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                }
            }
        }
        .animation(.snappy(duration: 0.32), value: selectedIndex)
        .focusEffectDisabled()
        // 2pt inset keeps the thumb concentric inside the track capsule.
        .padding(2)
        .background(.quaternary.opacity(0.25), in: Capsule())
    }
}
