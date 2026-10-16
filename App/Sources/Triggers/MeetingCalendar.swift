import EventKit
import Foundation

/// The calendar event a call belongs to, to name its notes. Read only, and
/// only once access is given.
@MainActor
enum MeetingCalendar {
    private static let store = EKEventStore()

    /// Asks for calendar access the first time; after that, System Settings decides.
    static func ask() {
        guard EKEventStore.authorizationStatus(for: .event) == .notDetermined,
              Bundle.main.object(forInfoDictionaryKey: "NSCalendarsFullAccessUsageDescription") != nil else { return }
        Task { _ = try? await store.requestFullAccessToEvents() }
    }

    /// The event happening now, if there is one.
    static func now(at date: Date = .now) -> Event? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        let predicate = store.predicateForEvents(withStart: date.addingTimeInterval(-6 * 3600), end: date.addingTimeInterval(15 * 60), calendars: nil)
        let events = store.events(matching: predicate).map {
            Event(title: $0.title ?? "", start: $0.startDate, end: $0.endDate, allDay: $0.isAllDay,
                  call: Event.hasCallLink([$0.url?.absoluteString, $0.location, $0.notes]),
                  people: ($0.attendees ?? []).compactMap(\.name),
                  guests: ($0.attendees ?? []).filter { !$0.isCurrentUser }.compactMap(\.name))
        }
        return Event.pick(events, at: date)
    }

    struct Event: Sendable {
        let title: String
        let start: Date
        let end: Date
        let allDay: Bool
        /// It has a link to a video call.
        let call: Bool
        /// Who was invited, by name.
        var people: [String] = []
        /// Who was invited besides you.
        var guests: [String] = []

        private static let links = ["zoom.us", "meet.google.com", "teams.microsoft", "teams.live", "webex.com", "facetime.apple.com", "whereby.com", "around.co"]

        static func hasCallLink(_ texts: [String?]) -> Bool {
            texts.compactMap { $0?.lowercased() }.contains { text in links.contains { text.contains($0) } }
        }

        /// The event under way at `date`, or starting within five minutes:
        /// one with a call link first, then the one that started last. All-day
        /// events don't count.
        static func pick(_ events: [Event], at date: Date) -> Event? {
            let now = events.filter {
                !$0.allDay && !$0.title.trimmingCharacters(in: .whitespaces).isEmpty
                    && $0.start <= date.addingTimeInterval(5 * 60) && $0.end > date
            }
            return now.max { a, b in (a.call ? 1 : 0, a.start) < (b.call ? 1 : 0, b.start) }
        }
    }
}
