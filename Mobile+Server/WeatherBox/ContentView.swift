import Charts
import Observation
import SwiftUI

private enum WeatherBoxConfig {
    static let refreshInterval: Duration = .seconds(5)
    static let accentOption: AccentOption = .sky
}

struct SensorSample: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let temperature: Double
    let humidity: Double
    let atmosphericPressure: Double?
    let sourceTimestamp: String?
}

private struct HistoryPoint: Identifiable, Equatable {
    let date: Date
    let value: Double

    var id: Date { date }
}

enum ConnectionState {
    case unknown
    case online
    case offline
}

enum ComfortStatus: Equatable {
    case unavailable
    case dry
    case normal
    case comfortable
    case humid
    case stuffy

    init(temperature: Double, humidity: Double) {
        if humidity < 35 {
            self = .dry
        } else if temperature >= 26, humidity >= 60 {
            self = .stuffy
        } else if humidity > 60 {
            self = .humid
        } else if (20 ... 25).contains(temperature), (40 ... 60).contains(humidity) {
            self = .comfortable
        } else {
            self = .normal
        }
    }

    var title: String {
        switch self {
        case .unavailable:
            return "Нет данных"
        case .dry:
            return "Сухо"
        case .normal:
            return "Нормально"
        case .comfortable:
            return "Комфортно"
        case .humid:
            return "Влажно"
        case .stuffy:
            return "Душно"
        }
    }

    var subtitle: String {
        switch self {
        case .unavailable:
            return "Ждём свежие показания"
        case .dry:
            return "Влажность ниже комфортной"
        case .normal:
            return "Параметры в допустимой зоне"
        case .comfortable:
            return "Оптимально для комнаты"
        case .humid:
            return "Влажность повышена"
        case .stuffy:
            return "Тепло и тяжёлый воздух"
        }
    }

    var icon: String {
        switch self {
        case .unavailable:
            return "questionmark.circle"
        case .dry:
            return "drop.circle"
        case .normal:
            return "gauge.medium"
        case .comfortable:
            return "checkmark.circle"
        case .humid:
            return "humidity.fill"
        case .stuffy:
            return "sun.max.fill"
        }
    }

    func accentColor(default defaultColor: Color) -> Color {
        switch self {
        case .unavailable:
            return .secondary
        case .dry:
            return .orange
        case .normal:
            return defaultColor
        case .comfortable:
            return .mint
        case .humid:
            return .blue
        case .stuffy:
            return .red
        }
    }
}

@MainActor
@Observable
final class WeatherBoxViewModel {
    private let api = WeatherBoxAPI()
    private let maxHistoryCount = 720
    private var lastSampleTimestamp: String?
    private var hasLoadedHistory = false

    private static let fractionalTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let fallbackTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    var status: DeviceStatus?
    var sensor: SensorReading?
    var history: [SensorSample] = []
    var isRefreshing = false
    var hasAttemptedInitialLoad = false
    var infoMessage = "Читаем данные с удалённого сервера."
    var errorMessage: String?
    var lastUpdated: Date?
    var connectionState: ConnectionState = .unknown

    func refresh(force: Bool = false) async {
        guard force || !isRefreshing else {
            return
        }

        isRefreshing = true
        hasAttemptedInitialLoad = true
        defer {
            isRefreshing = false
        }

        var historyError: Error?
        var statusError: Error?
        var sensorError: Error?

        if !hasLoadedHistory {
            do {
                let historyResponse = try await api.fetchHistory()
                applyHistory(historyResponse.history)
                hasLoadedHistory = true
            } catch {
                historyError = error
            }
        }

        do {
            let newStatus = try await api.fetchStatus()
            status = newStatus
            connectionState = newStatus.connected ? .online : .offline
        } catch {
            statusError = error
        }

        do {
            let newSensor = try await api.fetchSensor()
            sensor = newSensor
            appendSample(from: newSensor)
            lastUpdated = Date()
        } catch {
            sensorError = error
        }

        if status != nil || sensor != nil {
            errorMessage = nil
            if status?.stale == true || status?.connected == false {
                connectionState = .offline
                infoMessage = "Сервер отвечает, но свежих данных от устройства пока нет."
            } else {
                connectionState = .online
                infoMessage = "Данные обновлены."
            }
            return
        }

        connectionState = .offline
        handle(sensorError ?? statusError ?? historyError)
    }

    private func appendSample(from sensor: SensorReading) {
        if let lastSeen = sensor.lastSeen, lastSeen == lastSampleTimestamp {
            return
        }

        lastSampleTimestamp = sensor.lastSeen
        let sample = SensorSample(
            date: Self.parseServerDate(sensor.lastSeen) ?? Date(),
            temperature: sensor.temperature,
            humidity: sensor.humidity,
            atmosphericPressure: sensor.atmosphericPressure,
            sourceTimestamp: sensor.lastSeen
        )

        history.append(sample)
        if history.count > maxHistoryCount {
            history.removeFirst(history.count - maxHistoryCount)
        }
    }

    private func applyHistory(_ entries: [SensorHistoryEntry]) {
        let restoredSamples = entries.compactMap { entry -> SensorSample? in
            guard let date = Self.parseServerDate(entry.recordedAt) else {
                return nil
            }

            return SensorSample(
                date: date,
                temperature: entry.temperature,
                humidity: entry.humidity,
                atmosphericPressure: entry.atmosphericPressure,
                sourceTimestamp: entry.recordedAt
            )
        }

        history = reducedHistory(restoredSamples)
        lastSampleTimestamp = restoredSamples.last?.sourceTimestamp
    }

    private func reducedHistory(_ samples: [SensorSample]) -> [SensorSample] {
        guard samples.count > maxHistoryCount, maxHistoryCount > 1 else {
            return samples
        }

        let step = Double(samples.count - 1) / Double(maxHistoryCount - 1)
        return (0 ..< maxHistoryCount).map { index in
            let sourceIndex = Int((Double(index) * step).rounded())
            return samples[sourceIndex]
        }
    }

    private static func parseServerDate(_ value: String?) -> Date? {
        guard let value else {
            return nil
        }

        if let date = fractionalTimestampFormatter.date(from: value) {
            return date
        }

        return fallbackTimestampFormatter.date(from: value)
    }

    private func handle(_ error: Error?) {
        guard let error else {
            errorMessage = "Сервер пока не вернул данные."
            return
        }

        if let localizedError = error as? LocalizedError, let description = localizedError.errorDescription {
            errorMessage = description
        } else {
            errorMessage = error.localizedDescription
        }
    }
}

struct ContentView: View {
    @State private var viewModel = WeatherBoxViewModel()
    @State private var minimumSplashElapsed = false
    @State private var isHistoryPresented = false

    private var accentOption: AccentOption {
        WeatherBoxConfig.accentOption
    }

    private var shouldShowSplash: Bool {
        !minimumSplashElapsed || (!viewModel.hasAttemptedInitialLoad && viewModel.isRefreshing)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                backgroundView

                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 16) {
                        heroCard
                        summaryGrid
                        chartsSection
                        diagnosticsCard
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 16)
                    .padding(.bottom, 28)
                }
                .transaction { transaction in
                    transaction.animation = nil
                }
            }
            .navigationTitle("WeatherBox")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isHistoryPresented = true
                    } label: {
                        Label("История", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            await viewModel.refresh(force: true)
                        }
                    } label: {
                        Label("Обновить", systemImage: "arrow.clockwise")
                    }
                    .disabled(viewModel.isRefreshing)
                }
            }
        }
        .fontDesign(.rounded)
        .sheet(isPresented: $isHistoryPresented) {
            HistorySheet(
                samples: Array(viewModel.history.reversed()),
                accentColor: accentOption.color
            )
        }
        .task {
            await runAutoRefreshLoop()
        }
        .task {
            try? await Task.sleep(for: .seconds(1.1))
            withAnimation(.easeOut(duration: 0.25)) {
                minimumSplashElapsed = true
            }
        }
        .overlay {
            if shouldShowSplash {
                SplashScreen(accentOption: accentOption, isLoading: viewModel.isRefreshing)
                    .transition(.opacity)
            }
        }
    }

    private var backgroundView: some View {
        LinearGradient(
            colors: [
                accentOption.color.opacity(0.13),
                accentOption.secondaryColor.opacity(0.08),
                Color(.systemGroupedBackground)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private var heroCard: some View {
        CardView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("WeatherBox")
                            .font(.title2.weight(.bold))

                        Text(WeatherBoxAPI.defaultBaseAddress)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)

                        statusBadge
                    }

                    Spacer(minLength: 8)

                    WeatherBoxLogoView(accentOption: accentOption)
                        .frame(width: 92, height: 92)
                }

                HStack(alignment: .lastTextBaseline, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(sensorTemperature)
                            .font(.system(size: 46, weight: .bold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .monospacedDigit()
                        Text("Температура")
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    VStack(alignment: .leading, spacing: 8) {
                        MeasurementPill(title: "Влажность", value: sensorHumidity)
                        MeasurementPill(title: "Давление", value: sensorPressure)
                        MeasurementPill(title: "Комфорт", value: comfortStatus.title)
                    }
                }

                messageBanner
                vpnHintBanner
            }
        }
    }

    private var summaryGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            MetricCard(
                title: "Сервер",
                value: serverHost,
                subtitle: "Источник данных",
                icon: "server.rack",
                accentColor: accentOption.color
            )

            MetricCard(
                title: "Устройство",
                value: statusBadgeTitle,
                subtitle: statusSubtitle,
                icon: "antenna.radiowaves.left.and.right",
                accentColor: statusBadgeColor
            )

            MetricCard(
                title: "Комфорт",
                value: comfortStatus.title,
                subtitle: comfortStatus.subtitle,
                icon: comfortStatus.icon,
                accentColor: comfortStatus.accentColor(default: accentOption.secondaryColor)
            )

            MetricCard(
                title: "Обновление",
                value: refreshStamp,
                subtitle: "Каждые 5 секунд",
                icon: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                accentColor: accentOption.color
            )
        }
    }

    private var chartsSection: some View {
        VStack(spacing: 12) {
            HistoryChartCard(
                title: "Температура",
                subtitle: "Последние измерения",
                icon: "thermometer.medium",
                valueLabel: sensorTemperature,
                lineColor: accentOption.color,
                fillColor: accentOption.color.opacity(0.12),
                points: measurementHistory(\.temperature),
                unit: "°C"
            )

            HistoryChartCard(
                title: "Влажность",
                subtitle: "Последние измерения",
                icon: "humidity.fill",
                valueLabel: sensorHumidity,
                lineColor: accentOption.secondaryColor,
                fillColor: accentOption.secondaryColor.opacity(0.14),
                points: measurementHistory(\.humidity),
                unit: "%"
            )

            HistoryChartCard(
                title: "Давление",
                subtitle: "Последние измерения",
                icon: "barometer",
                valueLabel: sensorPressure,
                lineColor: .teal,
                fillColor: Color.teal.opacity(0.14),
                points: measurementHistory(\.atmosphericPressure),
                unit: viewModel.sensor?.unitAtmosphericPressure ?? "hPa",
                emptyStateText: "График появится, когда сервер начнёт отдавать давление."
            )
        }
    }

    private var diagnosticsCard: some View {
        CardView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Диагностика")
                    .font(.headline.weight(.semibold))

                DetailRow(title: "Backend", value: WeatherBoxAPI.defaultBaseAddress)
                DetailRow(title: "Режим", value: viewModel.status?.mode.capitalized ?? "—")
                DetailRow(title: "IP устройства", value: readableValue(viewModel.status?.ip))
                DetailRow(title: "Текущая сеть", value: readableValue(viewModel.status?.currentSSID))
                DetailRow(title: "Последняя связь", value: readableValue(viewModel.status?.lastSeen ?? viewModel.sensor?.lastSeen))
            }
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusBadgeColor)
                .frame(width: 9, height: 9)
            Text(statusBadgeTitle)
                .font(.caption.weight(.bold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }

    private var statusBadgeTitle: String {
        switch viewModel.connectionState {
        case .online:
            return "Online"
        case .offline:
            return "Offline"
        case .unknown:
            return "Checking"
        }
    }

    private var statusSubtitle: String {
        if viewModel.status?.stale == true {
            return "Данные устарели"
        }

        switch viewModel.connectionState {
        case .online:
            return "Данные свежие"
        case .offline:
            return "Нет свежей связи"
        case .unknown:
            return "Проверяем сервер"
        }
    }

    private var statusBadgeColor: Color {
        switch viewModel.connectionState {
        case .online:
            return accentOption.color
        case .offline:
            return .red
        case .unknown:
            return .orange
        }
    }

    @ViewBuilder
    private var messageBanner: some View {
        if let errorMessage = viewModel.errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(.red)
        } else {
            Label(viewModel.infoMessage, systemImage: "waveform.path.ecg")
                .font(.subheadline)
                .foregroundStyle(accentOption.color)
        }
    }

    @ViewBuilder
    private var vpnHintBanner: some View {
        if viewModel.connectionState != .online {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "network.slash")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)

                Text("Если данные не загружаются, отключите VPN и обновите экран.")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.orange.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.orange.opacity(0.18))
            )
        }
    }

    private var sensorTemperature: String {
        guard let sensor = viewModel.sensor else {
            return "--.-°"
        }

        return "\(sensor.temperature.formatted(.number.precision(.fractionLength(1))))°\(sensor.unitTemperature)"
    }

    private var sensorHumidity: String {
        guard let sensor = viewModel.sensor else {
            return "--.-%"
        }

        return "\(sensor.humidity.formatted(.number.precision(.fractionLength(1))))\(sensor.unitHumidity)"
    }

    private var sensorPressure: String {
        guard let pressure = viewModel.sensor?.atmosphericPressure else {
            return "—"
        }

        let unit = viewModel.sensor?.unitAtmosphericPressure ?? "hPa"
        return "\(pressure.formatted(.number.precision(.fractionLength(1)))) \(unit)"
    }

    private var comfortStatus: ComfortStatus {
        guard let sensor = viewModel.sensor else {
            return .unavailable
        }

        return ComfortStatus(temperature: sensor.temperature, humidity: sensor.humidity)
    }

    private var refreshStamp: String {
        guard let lastUpdated = viewModel.lastUpdated else {
            return "—"
        }

        return lastUpdated.formatted(date: .omitted, time: .standard)
    }

    private var serverHost: String {
        URL(string: WeatherBoxAPI.defaultBaseAddress)?.host ?? "server"
    }

    private func readableValue(_ value: String?) -> String {
        guard let value, !value.isEmpty else {
            return "—"
        }

        return value
    }

    private func measurementHistory(_ keyPath: KeyPath<SensorSample, Double>) -> [HistoryPoint] {
        viewModel.history.map { sample in
            HistoryPoint(date: sample.date, value: sample[keyPath: keyPath])
        }
    }

    private func measurementHistory(_ keyPath: KeyPath<SensorSample, Double?>) -> [HistoryPoint] {
        viewModel.history.compactMap { sample in
            guard let value = sample[keyPath: keyPath] else {
                return nil
            }

            return HistoryPoint(date: sample.date, value: value)
        }
    }

    private func runAutoRefreshLoop() async {
        while !Task.isCancelled {
            await viewModel.refresh()

            do {
                try await Task.sleep(for: WeatherBoxConfig.refreshInterval)
            } catch {
                return
            }
        }
    }
}

private struct CardView<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground).opacity(0.88))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06))
            )
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    let accentColor: Color

    var body: some View {
        CardView {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(accentColor)
                    .frame(width: 30, height: 30, alignment: .leading)

                Text(value)
                    .font(.headline.weight(.bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.68)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct MeasurementPill: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.headline.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 100, alignment: .leading)
    }
}

private struct HistoryChartCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let valueLabel: String
    let lineColor: Color
    let fillColor: Color
    let points: [HistoryPoint]
    let unit: String
    var emptyStateText = "График появится после нескольких обновлений."

    private var yDomain: ClosedRange<Double> {
        let values = points.map(\.value)
        guard let minValue = values.min(), let maxValue = values.max() else {
            return 0 ... 100
        }

        let padding = max((maxValue - minValue) * 0.25, 1)
        return (minValue - padding) ... (maxValue + padding)
    }

    var body: some View {
        CardView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(title, systemImage: icon)
                            .font(.headline.weight(.semibold))
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(valueLabel)
                        .font(.headline.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)
                }

                if points.count >= 2 {
                    Chart(points) { point in
                        AreaMark(
                            x: .value("Time", point.date),
                            y: .value(title, point.value)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [fillColor, .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                        LineMark(
                            x: .value("Time", point.date),
                            y: .value(title, point.value)
                        )
                        .interpolationMethod(.catmullRom)
                        .lineStyle(.init(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(lineColor)
                    }
                    .chartYScale(domain: yDomain)
                    .chartLegend(.hidden)
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 3)) { value in
                            AxisGridLine(stroke: .init(lineWidth: 0.5, dash: [4, 4]))
                                .foregroundStyle(.secondary.opacity(0.18))
                            AxisValueLabel {
                                if let date = value.as(Date.self) {
                                    Text(date, format: .dateTime.hour().minute())
                                }
                            }
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                            AxisGridLine(stroke: .init(lineWidth: 0.5, dash: [4, 4]))
                                .foregroundStyle(.secondary.opacity(0.18))
                            AxisValueLabel {
                                if let amount = value.as(Double.self) {
                                    Text("\(amount.formatted(.number.precision(.fractionLength(0))))\(unit)")
                                }
                            }
                        }
                    }
                    .chartPlotStyle { plot in
                        plot
                            .background(Color.primary.opacity(0.025))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .frame(height: 196)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(lineColor)
                        Text(emptyStateText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                    .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
    }
}

private struct DetailRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .fontWeight(.semibold)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
        }
        .font(.subheadline)
    }
}

// MARK: - History filter

private enum HistoryMetricFilter: String, CaseIterable {
    case all = "Все"
    case temperature = "Темп."
    case humidity = "Влажн."
    case pressure = "Давл."

    var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .temperature: return "thermometer.medium"
        case .humidity: return "humidity.fill"
        case .pressure: return "barometer"
        }
    }

    var color: Color {
        switch self {
        case .all: return .primary
        case .temperature: return .orange
        case .humidity: return .blue
        case .pressure: return .teal
        }
    }
}

// MARK: - HistorySheet

private struct HistorySheet: View {
    let samples: [SensorSample]
    let accentColor: Color

    @Environment(\.dismiss) private var dismiss
    @State private var filter: HistoryMetricFilter = .all

    // ── Stats ──────────────────────────────────────────────────
    private var tempValues: [Double] { samples.map(\.temperature) }
    private var humValues: [Double] { samples.map(\.humidity) }
    private var pressValues: [Double] { samples.compactMap(\.atmosphericPressure) }

    private func avg(_ arr: [Double]) -> Double? {
        guard !arr.isEmpty else { return nil }
        return arr.reduce(0, +) / Double(arr.count)
    }

    var body: some View {
        NavigationStack {
            Group {
                if samples.isEmpty {
                    ContentUnavailableView(
                        "История пока пуста",
                        systemImage: "clock.badge.questionmark",
                        description: Text("Первые измерения появятся после того, как сервер накопит несколько обновлений.")
                    )
                } else {
                    VStack(spacing: 0) {
                        // ── Segmented filter ──
                        Picker("Метрика", selection: $filter) {
                            ForEach(HistoryMetricFilter.allCases, id: \.self) { f in
                                Label(f.rawValue, systemImage: f.icon).tag(f)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 10)

                        // ── Stats summary ──
                        statsBar
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)

                        Divider()

                        // ── List ──
                        List {
                            ForEach(Array(samples.enumerated()), id: \.element.id) { index, sample in
                                let prev = index + 1 < samples.count ? samples[index + 1] : nil
                                HistoryRow(sample: sample, previous: prev, filter: filter)
                                    .listRowBackground(Color.clear)
                                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                    .listRowSeparatorTint(accentColor.opacity(0.12))
                            }
                        }
                        .listStyle(.plain)
                    }
                }
            }
            .navigationTitle("История")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
    }

    // ── Stats bar ──────────────────────────────────────────────

    @ViewBuilder
    private var statsBar: some View {
        switch filter {
        case .all:
            HStack(spacing: 8) {
                miniStatCard(
                    title: "Температура", unit: "°C", color: .orange,
                    icon: "thermometer.medium",
                    min: tempValues.min(), max: tempValues.max(), avg: avg(tempValues)
                )
                miniStatCard(
                    title: "Влажность", unit: "%", color: .blue,
                    icon: "humidity.fill",
                    min: humValues.min(), max: humValues.max(), avg: avg(humValues)
                )
                if !pressValues.isEmpty {
                    miniStatCard(
                        title: "Давление", unit: " hPa", color: .teal,
                        icon: "barometer",
                        min: pressValues.min(), max: pressValues.max(), avg: avg(pressValues)
                    )
                }
            }
        case .temperature:
            fullStatCard(title: "Температура", unit: "°C", color: .orange, icon: "thermometer.medium",
                         min: tempValues.min(), max: tempValues.max(), avg: avg(tempValues))
        case .humidity:
            fullStatCard(title: "Влажность", unit: "%", color: .blue, icon: "humidity.fill",
                         min: humValues.min(), max: humValues.max(), avg: avg(humValues))
        case .pressure:
            fullStatCard(title: "Давление", unit: " hPa", color: .teal, icon: "barometer",
                         min: pressValues.min(), max: pressValues.max(), avg: avg(pressValues))
        }
    }

    private func miniStatCard(title: String, unit: String, color: Color, icon: String,
                               min: Double?, max: Double?, avg: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2.weight(.bold))
                Text(title)
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(color)

            if let avg {
                Text("\(avg.formatted(.number.precision(.fractionLength(1))))\(unit)")
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            if let lo = min, let hi = max {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down").font(.caption2)
                    Text(lo.formatted(.number.precision(.fractionLength(0))))
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up").font(.caption2)
                    Text(hi.formatted(.number.precision(.fractionLength(0))))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func fullStatCard(title: String, unit: String, color: Color, icon: String,
                               min: Double?, max: Double?, avg: Double?) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(color.opacity(0.14))
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(color)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let avg {
                    Text("Среднее: \(avg.formatted(.number.precision(.fractionLength(1))))\(unit)")
                        .font(.headline.weight(.bold))
                }
            }

            Spacer()

            if let lo = min, let hi = max {
                VStack(alignment: .trailing, spacing: 5) {
                    Label("\(hi.formatted(.number.precision(.fractionLength(1))))\(unit)", systemImage: "arrow.up")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(color)
                    Label("\(lo.formatted(.number.precision(.fractionLength(1))))\(unit)", systemImage: "arrow.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - HistoryRow

private struct HistoryRow: View {
    let sample: SensorSample
    let previous: SensorSample?
    let filter: HistoryMetricFilter

    // ── Trend helpers ──────────────────────────────────────────

    enum ValueTrend: Equatable {
        case up, down, stable, none
        var icon: String {
            switch self { case .up: "arrow.up"; case .down: "arrow.down"; case .stable: "minus"; case .none: "" }
        }
        var color: Color {
            switch self { case .up: .orange; case .down: .blue; case .stable: .secondary; case .none: .clear }
        }
    }

    private func trend(_ current: Double, _ prev: Double?) -> ValueTrend {
        guard let p = prev else { return .none }
        let d = current - p
        if abs(d) < 0.1 { return .stable }
        return d > 0 ? .up : .down
    }

    private var tempTrend: ValueTrend { trend(sample.temperature, previous?.temperature) }
    private var humTrend: ValueTrend { trend(sample.humidity, previous?.humidity) }
    private var pressTrend: ValueTrend {
        guard let cur = sample.atmosphericPressure else { return .none }
        return trend(cur, previous?.atmosphericPressure)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Timestamp row
            HStack(spacing: 5) {
                Image(systemName: "clock")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(sample.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(relativeTime(sample.date))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // Metric badges
            HStack(spacing: 8) {
                if filter == .all || filter == .temperature {
                    metricBadge(
                        icon: "thermometer.medium",
                        value: "\(sample.temperature.formatted(.number.precision(.fractionLength(1))))°C",
                        trend: tempTrend,
                        color: .orange
                    )
                }
                if filter == .all || filter == .humidity {
                    metricBadge(
                        icon: "humidity.fill",
                        value: "\(sample.humidity.formatted(.number.precision(.fractionLength(1))))%",
                        trend: humTrend,
                        color: .blue
                    )
                }
                if (filter == .all || filter == .pressure), let p = sample.atmosphericPressure {
                    metricBadge(
                        icon: "barometer",
                        value: "\(p.formatted(.number.precision(.fractionLength(1)))) hPa",
                        trend: pressTrend,
                        color: .teal
                    )
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func metricBadge(icon: String, value: String, trend: ValueTrend, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
            Text(value)
                .font(.subheadline.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if trend != .none {
                Image(systemName: trend.icon)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(trend.color)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func relativeTime(_ date: Date) -> String {
        let diff = Date().timeIntervalSince(date)
        switch diff {
        case ..<60:        return "только что"
        case ..<3600:      return "\(Int(diff / 60)) мин. назад"
        case ..<86400:     return "\(Int(diff / 3600)) ч. назад"
        default:           return "\(Int(diff / 86400)) д. назад"
        }
    }
}

private struct SplashScreen: View {
    let accentOption: AccentOption
    let isLoading: Bool

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    accentOption.color.opacity(0.92),
                    accentOption.secondaryColor.opacity(0.82),
                    Color(.systemBackground)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 22) {
                Spacer()

                WeatherBoxLogoView(accentOption: accentOption, isLarge: true)
                    .frame(width: 148, height: 148)

                VStack(spacing: 8) {
                    Text("WeatherBox")
                        .font(.system(size: 36, weight: .bold, design: .rounded))

                    Text("Клиент для удалённого сервера погодной станции")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Spacer()

                HStack(spacing: 10) {
                    if isLoading {
                        ProgressView()
                    }
                    Text(isLoading ? "Подключаемся к серверу..." : "Запускаем интерфейс...")
                        .font(.subheadline.weight(.semibold))
                }
                .padding(.bottom, 36)
            }
        }
    }
}

private struct WeatherBoxLogoView: View {
    let accentOption: AccentOption
    var isLarge = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: isLarge ? 34 : 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [accentOption.color, accentOption.secondaryColor],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Image("WeatherBoxLogo")
                .resizable()
                .scaledToFit()
                .padding(isLarge ? 20 : 14)
        }
    }
}

#Preview {
    ContentView()
}
