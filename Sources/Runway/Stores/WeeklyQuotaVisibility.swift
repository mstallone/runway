/// Temporary dashboard filtering; saved layout and On Demand rows are never mutated.
enum WeeklyQuotaVisibility {
    /// A shared weekly limit blocks the account. Separate pools only dim the icon when every
    /// pinned metric belongs to an exhausted pool, leaving other usable pools visible.
    static func menuBarIsExhausted(
        descriptors: [WidgetDescriptor],
        pinned: [WidgetDescriptor],
        data: (WidgetDescriptor) -> WidgetData
    ) -> Bool {
        let exhausted = Set(descriptors.flatMap { descriptor -> [String] in
            let value = data(descriptor)
            guard value.hasData, let limit = value.limit, limit > 0,
                  value.used.isFinite, limit.isFinite, value.used >= limit else { return [] }
            return descriptor.limitResources.map(\.key)
        })
        if exhausted.contains("weekly") { return true }
        let pools = ["geminiSession": "geminiWeekly", "geminiWeekly": "geminiWeekly",
                     "nonGeminiSession": "nonGeminiWeekly", "nonGeminiWeekly": "nonGeminiWeekly",
                     "spark": "sparkWeekly", "sparkWeekly": "sparkWeekly"]
        return !pinned.isEmpty && pinned.allSatisfy { metric in
            metric.limitResources.contains { resource in
                pools[resource.key].map { exhausted.contains($0) } ?? false
            }
        }
    }

    /// Presentation copy only: preserve raw quota values for filtering, pins, and the local API.
    static func presentation(_ data: WidgetData, descriptor: WidgetDescriptor) -> WidgetData {
        guard data.hasData, let limit = data.limit, limit > 0,
              data.used.isFinite, limit.isFinite, data.used >= limit,
              let key = descriptor.limitResources.first(where: {
                  ["weekly", "geminiWeekly", "nonGeminiWeekly", "sparkWeekly"].contains($0.key)
              })?.key else { return data }
        var result = data
        switch key {
        case "geminiWeekly": result.exhaustedWeeklyTitle = "Gemini Usage Exhausted"
        case "nonGeminiWeekly": result.exhaustedWeeklyTitle = "Claude Usage Exhausted"
        case "sparkWeekly": result.exhaustedWeeklyTitle = "Spark Usage Exhausted"
        default: result.exhaustedWeeklyTitle = "Usage Exhausted"
        }
        return result
    }

    static func filter(
        _ group: ProviderGroup,
        descriptor: (PlacedWidget) -> WidgetDescriptor?,
        data: (WidgetDescriptor) -> WidgetData
    ) -> ProviderGroup {
        // Require the blocking weekly row above the caret so the reason and reset stay visible.
        let exhaustedKeys = Set(group.alwaysShownWidgets.compactMap { widget -> String? in
            guard let metric = descriptor(widget),
                  let key = metric.limitResources.first(where: {
                      ["weekly", "geminiWeekly", "nonGeminiWeekly", "sparkWeekly"].contains($0.key)
                  })?.key else { return nil }
            let value = data(metric)
            guard value.hasData, let limit = value.limit, limit > 0,
                  value.used.isFinite, limit.isFinite, value.used >= limit else { return nil }
            return key
        })
        guard !exhaustedKeys.isEmpty else { return group }
        let visible = group.alwaysShownWidgets.filter { widget in
            guard let metric = descriptor(widget) else { return true }
            let keys = Set(metric.limitResources.map(\.key))
            // Keep the main weekly row, rendered as an exhaustion summary, and all non-bar rows.
            guard !keys.contains("weekly"), data(metric).isBounded else { return true }
            if exhaustedKeys.contains("weekly") { return false }
            // Independent model pools only suppress their own session window.
            return !(exhaustedKeys.contains("geminiWeekly") && keys.contains("geminiSession"))
                && !(exhaustedKeys.contains("nonGeminiWeekly") && keys.contains("nonGeminiSession"))
                && !(exhaustedKeys.contains("sparkWeekly") && keys.contains("spark"))
        }
        return ProviderGroup(
            provider: group.provider,
            alwaysShownWidgets: visible,
            expandedWidgets: group.expandedWidgets
        )
    }
}

extension LayoutStore {
    /// Account applicability first, followed by reversible filtering of exhausted quota bars.
    func dashboardGroups(dataStore: WidgetDataStore) -> [ProviderGroup] {
        displayGroups(matching: dataStore.isMetricApplicable).map {
            WeeklyQuotaVisibility.filter($0, descriptor: descriptor(for:), data: dataStore.data(for:))
        }
    }
}
