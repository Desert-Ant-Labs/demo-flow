import AppKit
import SwiftUI

/// A flow's runs on its own, newest first and by day, in the window's
/// inspector: what came of each, with Open and Undo.
struct RunHistory: View {
    let path: String
    @State private var center = TriggerCenter.shared
    @State private var open = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let runs = center.history.filter { $0.flow == path }
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(reduceMotion ? nil : .snappy) { open.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").rotationEffect(.degrees(open ? 90 : 0)).font(.caption)
                    Text("Runs").font(.headline)
                    Spacer()
                    Text(runs.isEmpty ? "" : "\(runs.count)").font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            if open {
                if runs.isEmpty {
                    Text(center.isOn(path) ? "No runs yet. It runs on its own from now on." : "Turn it on in its first step to run on its own.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(days(runs), id: \.day) { day, records in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(Self.label(day)).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            VStack(spacing: 0) {
                                ForEach(records) { record in
                                    RunRow(record: record)
                                    if record.id != records.last?.id { Divider().padding(.leading, 52) }
                                }
                            }
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.stepFill))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.background.secondary))
    }

    private func days(_ runs: [RunRecord]) -> [(day: Date, records: [RunRecord])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: runs.prefix(60)) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0]!.sorted { $0.date > $1.date }) }
    }

    private static func label(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

/// One run: what came of it and when. Clicking opens what it made; Undo puts
/// back what it did to files.
private struct RunRow: View {
    let record: RunRecord
    @State private var hover = false
    private var center: TriggerCenter { .shared }

    var body: some View {
        HStack(spacing: 10) {
            thumbnail
            VStack(alignment: .leading, spacing: 1) {
                Text(record.summary)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(record.failed ? AnyShapeStyle(Theme.danger) : AnyShapeStyle(.primary))
                    .lineLimit(2)
                Text([record.date.formatted(date: .omitted, time: .shortened), record.undone ? "Undone" : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if hover && record.canUndo {
                Button("Undo") { center.undo(record) }.controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(hover ? Theme.hairline.opacity(0.6) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { center.openResult(record) }
        .onHover { hover = $0 }
        .contextMenu {
            Button("Open Result") { center.openResult(record) }
            Button("Show Run") { center.open(record.file) }
            if record.canUndo { Button("Undo") { center.undo(record) } }
        }
        .help("Open what it made")
    }

    @ViewBuilder private var thumbnail: some View {
        if let path = record.thumbnail, let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image).resizable().scaledToFill().frame(width: 32, height: 32).clipShape(.rect(cornerRadius: 6))
        } else {
            Image(systemName: record.failed ? "exclamationmark" : "checkmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(record.failed ? Theme.danger : .secondary)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.hairline))
        }
    }
}

