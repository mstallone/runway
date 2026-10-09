import Foundation

extension WidgetData {
    /// The reset beside the exhausted message, short enough for the message's own line: the
    /// countdown and the exact time ("Resets in 1d 14h · Sat 2:59 AM"), or the countdown alone
    /// when the line has no room for both.
    func exhaustedWeeklyResetNote(
        now: Date = Date(),
        calendar: Calendar = .current,
        countdownOnly: Bool = false
    ) -> String {
        guard let resetsAt else { return "Reset Time Unavailable" }
        guard let countdown = Formatters.compactWhenLabel(at: resetsAt, mode: .relative, now: now, calendar: calendar),
              let exact = Formatters.compactWhenLabel(at: resetsAt, mode: .absolute, now: now, calendar: calendar),
              countdown != Formatters.imminent
        else { return "Resets \(Formatters.imminent)" }
        return countdownOnly ? "Resets in \(countdown)" : "Resets in \(countdown) · \(exact)"
    }
}
