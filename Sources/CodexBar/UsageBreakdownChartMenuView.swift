import Charts
import CodexBarCore
import SwiftUI

@MainActor
struct UsageBreakdownChartMenuView: View {
    private struct Point: Identifiable {
        let id: String
        let date: Date
        let service: String
        let creditsUsed: Double

        init(date: Date, service: String, creditsUsed: Double) {
            self.date = date
            self.service = service
            self.creditsUsed = creditsUsed
            self.id = "\(service)-\(Int(date.timeIntervalSince1970))- \(creditsUsed)"
        }
    }

    private let breakdown: [OpenAIDashboardDailyBreakdown]
    private let width: CGFloat
    @State private var selectedDayKey: String?

    init(breakdown: [OpenAIDashboardDailyBreakdown], width: CGFloat) {
        self.breakdown = breakdown
        self.width = width
    }

    var body: some View {
        let model = Self.makeModel(from: self.breakdown)
        VStack(alignment: .leading, spacing: 10) {
            if model.points.isEmpty {
                Text("No usage breakdown data.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(model.points) { point in
                        BarMark(
                            x: .value("Day", point.date, unit: .day),
                            y: .value("Credits used", point.creditsUsed))
                            .foregroundStyle(by: .value("Service", point.service))
                    }
                }
                .chartForegroundStyleScale(domain: model.services, range: model.serviceColors)
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks(values: model.axisDates) { _ in
                        AxisGridLine().foregroundStyle(Color.clear)
                        AxisTick().foregroundStyle(Color.clear)
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                            .font(.caption2)
                            .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    }
                }
                .chartLegend(.hidden)
                .frame(height: 130)
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        ZStack(alignment: .topLeading) {
                            if let rect = self.selectionBandRect(model: model, proxy: proxy, geo: geo) {
                                Rectangle()
                                    .fill(Self.selectionBandColor)
                                    .frame(width: rect.width, height: rect.height)
                                    .position(x: rect.midX, y: rect.midY)
                                    .allowsHitTesting(false)
                            }
                            MouseLocationReader { location in
                                self.updateSelection(location: location, model: model, proxy: proxy, geo: geo)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                        }
                    }
                }

                let detail = self.detailLines(model: model)
                VStack(alignment: .leading, spacing: 0) {
                    Text(detail.primary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(height: 16, alignment: .leading)
                    Text(detail.secondary ?? " ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(height: 16, alignment: .leading)
                        .opacity(detail.secondary == nil ? 0 : 1)
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 110), alignment: .leading)],
                    alignment: .leading,
                    spacing: 6)
                {
                    ForEach(model.services, id: \.self) { service in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(model.color(for: service))
                                .frame(width: 7, height: 7)
                            Text(service)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minWidth: self.width, maxWidth: .infinity, alignment: .leading)
    }

    private struct Model {
        let points: [Point]
        let breakdownByDayKey: [String: OpenAIDashboardDailyBreakdown]
        let dayDates: [(dayKey: String, date: Date)]
        let selectableDayDates: [(dayKey: String, date: Date)]
        let services: [String]
        let serviceColors: [Color]
        let axisDates: [Date]

        func color(for service: String) -> Color {
            guard let idx = self.services.firstIndex(of: service), idx < self.serviceColors.count else {
                return .secondary
            }
            return self.serviceColors[idx]
        }
    }

    private static let selectionBandColor = Color(nsColor: .labelColor).opacity(0.1)

    private static func makeModel(from breakdown: [OpenAIDashboardDailyBreakdown]) -> Model {
        let sorted = breakdown
            .sorted { lhs, rhs in lhs.day < rhs.day }

        var points: [Point] = []
        points.reserveCapacity(sorted.count * 2)

        var breakdownByDayKey: [String: OpenAIDashboardDailyBreakdown] = [:]
        breakdownByDayKey.reserveCapacity(sorted.count)

        var dayDates: [(dayKey: String, date: Date)] = []
        dayDates.reserveCapacity(sorted.count)

        var selectableDayDates: [(dayKey: String, date: Date)] = []
        selectableDayDates.reserveCapacity(sorted.count)

        for day in sorted {
            guard let date = self.dateFromDayKey(day.day) else { continue }
            breakdownByDayKey[day.day] = day
            dayDates.append((dayKey: day.day, date: date))
            let serviceTotals = Self.normalizedServiceTotals(for: day)
            let totalCreditsUsed = serviceTotals.values.reduce(0, +)
            guard totalCreditsUsed > 0 else { continue }
            selectableDayDates.append((dayKey: day.day, date: date))
            for serviceTotal in serviceTotals.sorted(by: { $0.key < $1.key }) where serviceTotal.value > 0 {
                points.append(Point(
                    date: date,
                    service: serviceTotal.key,
                    creditsUsed: serviceTotal.value))
            }
        }

        let services = Self.serviceOrder(from: sorted)
        let colors = services.map { Self.colorForService($0) }
        let axisDates = Self.axisDates(fromSortedDays: sorted)

        return Model(
            points: points,
            breakdownByDayKey: breakdownByDayKey,
            dayDates: dayDates,
            selectableDayDates: selectableDayDates,
            services: services,
            serviceColors: colors,
            axisDates: axisDates)
    }

    private static func serviceOrder(from breakdown: [OpenAIDashboardDailyBreakdown]) -> [String] {
        var totals: [String: Double] = [:]
        for day in breakdown {
            for serviceTotal in self.normalizedServiceTotals(for: day) {
                totals[serviceTotal.key, default: 0] += serviceTotal.value
            }
        }

        return totals
            .sorted { lhs, rhs in
                if lhs.value == rhs.value { return lhs.key < rhs.key }
                return lhs.value > rhs.value
            }
            .map(\.key)
    }

    nonisolated static func displayServiceName(_ rawService: String) -> String {
        let trimmed = rawService.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Other" }
        let lower = trimmed.lowercased()

        if lower == "unknown" || lower == "other" || lower.contains("unknown") {
            return "Other"
        }
        if lower == "cli" {
            return "CLI"
        }
        if lower == "sdk" {
            return "SDK"
        }
        if lower.contains("desktop"), lower.contains("app") {
            return "Desktop App"
        }
        return trimmed
    }

    nonisolated static func serviceRGB(for service: String) -> (red: Double, green: Double, blue: Double)? {
        let display = self.displayServiceName(service)
        let lower = display.lowercased()
        if lower == "desktop app" {
            return (red: 0.88, green: 0.24, blue: 0.22)
        }
        if lower == "sdk" {
            return (red: 0.35, green: 0.43, blue: 0.27)
        }
        if lower == "cli" {
            return (red: 0.92, green: 0.40, blue: 0.69)
        }
        if lower == "other" {
            return (red: 0.57, green: 0.57, blue: 0.60)
        }
        if lower.contains("github"), lower.contains("review") {
            return (red: 0.94, green: 0.53, blue: 0.18)
        }
        return nil
    }

    nonisolated static func normalizedServiceShares(
        for day: OpenAIDashboardDailyBreakdown) -> [(service: String, percent: Double)]
    {
        let totals = self.normalizedServiceTotals(for: day)
        let totalUsed = totals.values.reduce(0, +)
        guard totalUsed > 0 else { return [] }
        return totals
            .map { key, value in
                (service: key, percent: (value / totalUsed) * 100)
            }
            .sorted { lhs, rhs in
                if lhs.percent == rhs.percent { return lhs.service < rhs.service }
                return lhs.percent > rhs.percent
            }
    }

    private nonisolated static func normalizedServiceTotals(
        for day: OpenAIDashboardDailyBreakdown) -> [String: Double]
    {
        var totals: [String: Double] = [:]
        for service in day.services where service.creditsUsed > 0 {
            totals[self.displayServiceName(service.service), default: 0] += service.creditsUsed
        }
        return totals
    }

    private static func colorForService(_ service: String) -> Color {
        if let rgb = self.serviceRGB(for: service) {
            return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
        }
        let palette: [Color] = [
            Color(red: 0.46, green: 0.75, blue: 0.36),
            Color(red: 0.80, green: 0.45, blue: 0.92),
            Color(red: 0.26, green: 0.78, blue: 0.86),
            Color(red: 0.94, green: 0.74, blue: 0.26),
        ]
        let idx = abs(service.hashValue) % palette.count
        return palette[idx]
    }

    private static func axisDates(fromSortedDays sortedDays: [OpenAIDashboardDailyBreakdown]) -> [Date] {
        guard let first = sortedDays.first, let last = sortedDays.last else { return [] }
        guard let firstDate = self.dateFromDayKey(first.day),
              let lastDate = self.dateFromDayKey(last.day)
        else {
            return []
        }
        if Calendar.current.isDate(firstDate, inSameDayAs: lastDate) {
            return [firstDate]
        }
        return [firstDate, lastDate]
    }

    private static func dateFromDayKey(_ key: String) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2])
        else {
            return nil
        }

        var comps = DateComponents()
        comps.calendar = Calendar.current
        comps.timeZone = TimeZone.current
        comps.year = year
        comps.month = month
        comps.day = day
        // Noon avoids off-by-one-day shifts if anything ends up interpreted in UTC.
        comps.hour = 12
        return comps.date
    }

    private func selectionBandRect(model: Model, proxy: ChartProxy, geo: GeometryProxy) -> CGRect? {
        guard let key = self.selectedDayKey else { return nil }
        guard let plotAnchor = proxy.plotFrame else { return nil }
        let plotFrame = geo[plotAnchor]
        guard let index = model.dayDates.firstIndex(where: { $0.dayKey == key }) else { return nil }
        let date = model.dayDates[index].date
        guard let x = proxy.position(forX: date) else { return nil }

        func xForIndex(_ idx: Int) -> CGFloat? {
            guard idx >= 0, idx < model.dayDates.count else { return nil }
            return proxy.position(forX: model.dayDates[idx].date)
        }

        let xPrev = xForIndex(index - 1)
        let xNext = xForIndex(index + 1)

        if model.dayDates.count <= 1 {
            return CGRect(
                x: plotFrame.origin.x,
                y: plotFrame.origin.y,
                width: plotFrame.width,
                height: plotFrame.height)
        }

        let leftInPlot: CGFloat = if let xPrev {
            (xPrev + x) / 2
        } else if let xNext {
            x - (xNext - x) / 2
        } else {
            x - 8
        }

        let rightInPlot: CGFloat = if let xNext {
            (xNext + x) / 2
        } else if let xPrev {
            x + (x - xPrev) / 2
        } else {
            x + 8
        }

        let left = plotFrame.origin.x + min(leftInPlot, rightInPlot)
        let right = plotFrame.origin.x + max(leftInPlot, rightInPlot)
        return CGRect(x: left, y: plotFrame.origin.y, width: right - left, height: plotFrame.height)
    }

    private func updateSelection(
        location: CGPoint?,
        model: Model,
        proxy: ChartProxy,
        geo: GeometryProxy)
    {
        guard let location else {
            if self.selectedDayKey != nil { self.selectedDayKey = nil }
            return
        }

        guard let plotAnchor = proxy.plotFrame else { return }
        let plotFrame = geo[plotAnchor]
        guard plotFrame.contains(location) else { return }

        let xInPlot = location.x - plotFrame.origin.x
        guard let date: Date = proxy.value(atX: xInPlot) else { return }
        guard let nearest = self.nearestDayKey(to: date, model: model) else { return }

        if self.selectedDayKey != nearest {
            self.selectedDayKey = nearest
        }
    }

    private func nearestDayKey(to date: Date, model: Model) -> String? {
        guard !model.selectableDayDates.isEmpty else { return nil }
        var best: (key: String, distance: TimeInterval)?
        for entry in model.selectableDayDates {
            let dist = abs(entry.date.timeIntervalSince(date))
            if let cur = best {
                if dist < cur.distance { best = (entry.dayKey, dist) }
            } else {
                best = (entry.dayKey, dist)
            }
        }
        return best?.key
    }

    private func detailLines(model: Model) -> (primary: String, secondary: String?) {
        guard let key = self.selectedDayKey,
              let day = model.breakdownByDayKey[key],
              let date = Self.dateFromDayKey(key)
        else {
            return ("Hover a bar for details", nil)
        }

        let dayLabel = date.formatted(.dateTime.month(.abbreviated).day())
        let shares = Self.normalizedServiceShares(for: day)
        if shares.isEmpty {
            return ("\(dayLabel): 0%", nil)
        }
        if shares.count == 1, let first = shares.first {
            return ("\(dayLabel): \(Self.percentString(first.percent))", first.service)
        }

        let services = shares
            .prefix(3)
            .map { "\($0.service) \(Self.percentString($0.percent))" }
            .joined(separator: " · ")
        let totalPercent = shares.reduce(0.0) { $0 + $1.percent }
        return ("\(dayLabel): \(Self.percentString(totalPercent))", services)
    }

    private nonisolated static func percentString(_ percent: Double) -> String {
        let clamped = max(0, min(100, percent))
        return (clamped / 100).formatted(.percent.precision(.fractionLength(0...1)))
    }
}
