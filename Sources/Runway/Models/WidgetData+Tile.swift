import Foundation

/// What a card tile shows. A tile is always the same four lines — name, reading, bar, time — so
/// every account of a provider has one shape and only the values differ.
extension WidgetData {
    /// A limit: drawn as a tile with a bar. Not the exhausted-week message or a chart.
    var isLimitTile: Bool {
        isBounded && exhaustedWeeklyTitle == nil && !(isChart && hasData)
    }

    /// A plain value that can sit in the grid beside a limit, as a tile with no bar: its first
    /// value as the reading, the rest as the line under it ("$2.3K" over "56.3K credits"). `nil`
    /// for rows that need their own line: badges and sentences, charts, and rows whose value opens
    /// a popover (model breakdowns, reset credits).
    var valueTile: (value: String, detail: String?)? {
        guard !isBounded, !isChart, hasData, valueTextOverride == nil,
              !hasModelBreakdown, !showsResetExpiries,
              let first = selectedValues.first
        else { return nil }
        let rest = selectedValues.dropFirst()
        if rest.isEmpty, first.kind == .dollars, let word = unboundedValueWord {
            return (MetricFormatter.number(first.number, kind: .dollars, style: .row), word)
        }
        let detail = rest.map { MetricFormatter.string(for: $0, style: .row) }.joined(separator: " · ")
        return (MetricFormatter.string(for: first, style: .row), detail.isEmpty ? unboundedSubtitle : detail)
    }

    /// The limit's reading split for a tile: the number, and its Used/Left word small beside it.
    /// An overridden or missing value has no mode word and is shown whole.
    var limitReading: (value: String, word: String?) {
        guard hasData, valueTextOverride == nil else { return (headline, nil) }
        return (valueText, displayMode.label.lowercased())
    }

    /// The one time a limit tile prints under its bar.
    struct TileTime: Equatable {
        let text: String
        /// When the limit is projected to run out rather than when it resets; the tile marks it
        /// with a flame.
        let isRunOut: Bool
    }

    /// Normally the reset, in short form ("2h 15m", or "Sat 3:00 AM" in exact-time mode). On a
    /// limit on course to run out, the run-out time instead: that is the one that matters, and the
    /// reset moves to its tooltip. Anything else a limit has to say there ("Not started", "$20
    /// limit", "No data") prints as is.
    func tileTime(for state: MeterState, now: Date = Date(), calendar: Calendar = .current) -> TileTime? {
        // A run-out that lands right at the reset has no time of its own: the tile keeps the reset
        // and the red bar carries the verdict, rather than a flame beside a time the limit refills.
        if case .runningOut = state, let date = runOutDate(now: now),
           let when = Formatters.compactWhenLabel(at: date, mode: resetDisplayMode, now: now, calendar: calendar) {
            return TileTime(text: when, isRunOut: true)
        }
        let text: String?
        if hasResetLabel(now: now), let resetsAt {
            text = Formatters.compactWhenLabel(at: resetsAt, mode: resetDisplayMode, now: now, calendar: calendar)
        } else {
            text = boundedTrailingText(now: now)
        }
        return text.map { TileTime(text: $0, isRunOut: false) }
    }
}

extension WidgetData {
    /// What hovering a tile adds: only what its four lines do not already say.
    struct TileDetail: Equatable {
        struct Row: Equatable {
            let label: String
            let value: String
        }

        var rows: [Row] = []
        /// A sentence that is not a label-and-value pair.
        var note: String?
    }

    /// - A limit on course to run out: when, in the format its time line is not using.
    /// - A limit being paced: where it lands at reset.
    /// - Any limit with a reset: the reset in the format its time line is not using (the exact
    ///   time under a countdown, and the other way round) — and on a run-out, where the time line
    ///   gave the reset up entirely, this is the only place it appears.
    /// - A session that has not started: why there is no countdown.
    /// - A plain value: the exact figures behind an abbreviated amount.
    /// `nil` when the tile already says everything (a level bar with no reset, no data).
    func tileDetail(for state: MeterState, now: Date = Date(), calendar: Calendar = .current) -> TileDetail? {
        guard isLimitTile else { return unboundedValueTooltip.map { TileDetail(note: $0) } }
        let other: ResetDisplayMode = resetDisplayMode == .relative ? .absolute : .relative
        func when(_ date: Date) -> String? {
            Formatters.whenLabel(at: date, mode: other, now: now, calendar: calendar).map {
                other == .relative && $0 != Formatters.imminent ? "in \($0)" : $0
            }
        }
        var detail = TileDetail(note: notStartedTooltip(now: now))
        if case .runningOut = state, let runsOut = runOutDate(now: now).flatMap(when) {
            detail.rows.append(.init(label: "Runs Out", value: runsOut))
        }
        if let projection = state.projection {
            detail.rows.append(.init(label: "At Reset", value: projection))
        }
        if hasResetLabel(now: now), let resets = resetsAt.flatMap(when) {
            detail.rows.append(.init(label: "Resets", value: resets))
        }
        return detail.rows.isEmpty && detail.note == nil ? nil : detail
    }
}

extension Formatters {
    /// `whenLabel` cut down to fit a tile. `.relative` is unchanged ("2d 6h"). `.absolute` keeps
    /// only what the distance needs: the time today ("6:38 PM"), weekday and time within the week
    /// ("Sat 3:00 AM"), and the date beyond that ("Feb 15").
    static func compactWhenLabel(
        at date: Date,
        mode: ResetDisplayMode,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        guard mode == .absolute else { return whenLabel(at: date, mode: mode, now: now, calendar: calendar) }
        guard date.timeIntervalSince(now) > 0 else { return imminent }
        let dayDiff = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: date)
        ).day ?? 0
        let time = TimeFormatSetting.current.shortTime(date)
        if dayDiff <= 0 { return time }
        guard dayDiff < 7 else { return monthDayLabel(date) }
        var weekday = Date.FormatStyle.dateTime.weekday(.abbreviated)
        weekday.calendar = calendar
        weekday.timeZone = calendar.timeZone
        return "\(date.formatted(weekday)) \(time)"
    }
}
