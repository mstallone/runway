import Foundation

extension WidgetData {
    var exhaustedWeeklyResetText: String { exhaustedWeeklyResetText(now: Date()) }

    func exhaustedWeeklyResetText(now: Date) -> String {
        guard let resetsAt else { return "Reset Time Unavailable" }
        let countdown = Formatters.resetRelativeLabel(until: resetsAt, now: now) ?? "Resets soon"
        let date = resetsAt.formatted(.dateTime.month(.abbreviated).day())
        let time = TimeFormatSetting.current.shortTime(resetsAt)
        return "\(countdown) · \(date) at \(time)"
    }
}
