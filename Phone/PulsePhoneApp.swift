import SwiftUI
import Charts

@main
struct PulsePhoneApp: App {
    @StateObject private var store = ConnectivityStore.shared
    var body: some Scene {
        WindowGroup { PhoneHome().environmentObject(store).tint(.mint).preferredColorScheme(.dark) }
    }
}

struct PhoneHome: View {
    @EnvironmentObject private var store: ConnectivityStore
    @State private var days = 7
    @State private var modeFilter = "all"
    private var filteredRecords: [SessionRecord] {
        store.records.filter { modeFilter == "all" || $0.mode.rawValue == modeFilter }
    }
    @State private var export: URL?
    private var recent: [SessionRecord] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -(days - 1), to: Calendar.current.startOfDay(for: Date()))!
        return filteredRecords.filter { !$0.isDemo && $0.startedAt >= cutoff }
    }
    private var trend: [DailyValue] {
        let calendar = Calendar.current
        return (0..<days).reversed().map { offset in
            let day = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: Date()))!
            let records = recent.filter { calendar.isDate($0.startedAt, inSameDayAs: day) }
            return DailyValue(day: day, count: records.reduce(0) { $0 + $1.count }, minutes: records.reduce(0) { $0 + $1.duration } / 60)
        }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "applewatch.radiowaves.left.and.right").font(.title).foregroundStyle(.mint)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(store.status).font(.subheadline)
                            if let date = store.lastReceived { Text(date, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.secondary) }
                            else { Text("手表结束并保存后自动同步").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button { store.requestSync() } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                            .accessibilityLabel("同步手表记录")
                    }
                }
                Section {
                    Picker("记录模式", selection: $modeFilter) {
                        Text("全部").tag("all")
                        Text("单人").tag("solo")
                        Text("双人").tag("partner")
                    }.pickerStyle(.segmented)
                }
                Section("趋势 · 不含演示记录") {
                    Picker("时间范围", selection: $days) { Text("近 7 天").tag(7); Text("近 30 天").tag(30) }.pickerStyle(.segmented)
                    HStack {
                        stat("记录", "\(recent.count) 次")
                        Spacer()
                        stat("运动次数", "\(recent.reduce(0) { $0 + $1.count })")
                        Spacer()
                        stat("时长", String(format: "%.1f 分钟", recent.reduce(0) { $0 + $1.duration } / 60))
                    }.padding(.vertical, 8)
                    Text("每日运动次数").font(.caption).foregroundStyle(.secondary)
                    Chart(trend) { day in
                        BarMark(x: .value("日期", day.day, unit: .day), y: .value("次数", day.count)).foregroundStyle(.mint.gradient)
                    }.frame(height: 150)
                    Text("每日记录时长（分钟）").font(.caption).foregroundStyle(.secondary)
                    Chart(trend) { day in
                        LineMark(x: .value("日期", day.day, unit: .day), y: .value("分钟", day.minutes)).foregroundStyle(.cyan)
                    }.frame(height: 100)
                }
                Section("历史记录") {
                    if filteredRecords.isEmpty {
                        ContentUnavailableView("等待第一条记录", systemImage: "applewatch", description: Text("在手表打开隐记并完成一次记录。两端首次安装后各打开一次。"))
                    }
                    ForEach(filteredRecords) { record in
                        NavigationLink { PhoneRecordDetail(id: record.id).environmentObject(store) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(record.startedAt, format: .dateTime.month().day().hour().minute()).font(.headline)
                                    Spacer()
                                    if record.isDemo { Text("演示").font(.caption).foregroundStyle(.orange) }
                                }
                                Label(record.mode.title, systemImage: record.mode.symbol).font(.caption).foregroundStyle(.mint)
                                Text("\(record.count) 次  ·  \(String(format: "%.1f", record.duration / 60)) 分钟  ·  \(String(format: "%.0f", record.averageRPM)) 次/分")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                if let bpm = record.averageHeartRate { Label(String(format: "平均 %.0f 次/分", bpm), systemImage: "heart.fill").font(.caption).foregroundStyle(.pink) }
                            }.padding(.vertical, 6)
                        }
                    }
                }
                Section {
                    Button("导出当前筛选记录 CSV") { prepareExport(filteredRecords) }
                    if let export { ShareLink("分享 / 存储 CSV", item: export) }
                    Text("记录保存在手表和本机。苹果健康同步独立进行；手机历史保留副本，不随手表删除而删除。CSV 为明文文件，仅分享给你信任的对象。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("隐记")
            .onChange(of: modeFilter) { _, _ in export = nil }
            .alert("提示", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
                Button("知道了") { store.errorMessage = nil }
            } message: { Text(store.errorMessage ?? "") }
        }
    }
    private func stat(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(value).font(.headline).monospacedDigit(); Text(name).font(.caption).foregroundStyle(.secondary) }
    }
    private func prepareExport(_ records: [SessionRecord]) {
        do { export = try store.summaryExport(records) } catch { store.errorMessage = error.localizedDescription }
    }
}
struct DailyValue: Identifiable {
    let day: Date
    let count: Int
    let minutes: Double
    var id: Date { day }
}
struct PhoneRecordDetail: View {
    let id: UUID
    @EnvironmentObject private var store: ConnectivityStore
    @State private var export: URL?
    @State private var timelineExport: URL?
    private var record: SessionRecord? { store.records.first { $0.id == id } }
    var body: some View {
        List {
            if let record {
                Section("记录详情") {
                    Text(record.startedAt, format: .dateTime.year().month().day().hour().minute())
                    LabeledContent("模式", value: record.mode.title)
                    LabeledContent("计数方式", value: record.detectorMethod == "three-axis-v1" ? "三轴自动" : (record.detectorMethod?.replacingOccurrences(of: "single-", with: "单轴 ") ?? "旧版单轴"))
                    if record.mode == .partner { Text("仅记录佩戴者；运动次数为手腕运动峰值，不能等同于双方动作次数。").font(.caption).foregroundStyle(.secondary) }
                    LabeledContent("运动次数", value: "\(record.count)")
                    LabeledContent("有效时长", value: String(format: "%.1f 分钟", record.duration / 60))
                    LabeledContent("平均节奏", value: String(format: "%.1f 次/分", record.averageRPM))
                    if record.isDemo { Text("演示记录，不写入健康").foregroundStyle(.orange) }
                }
                Section("心率") {
                    LabeledContent("平均", value: record.averageHeartRate.map { String(format: "%.0f 次/分", $0) } ?? "无数据")
                    LabeledContent("最高", value: record.maximumHeartRate.map { String(format: "%.0f 次/分", $0) } ?? "无数据")
                    Text("心率曲线与摘要保留在 App。手动同步健康时，会尝试关联健康中同时间段的真实心率样本；无权限或尚未同步到手机时不补造样本。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let summary = record.motionSummary {
                    MotionAnalysisView(summary: summary, duration: record.duration)
                } else {
                    Section("运动分析") { Text("旧记录未采集过程数据，更新后新记录将显示曲线与详细统计。").font(.caption).foregroundStyle(.secondary) }
                }
                Section("苹果健康") {
                    Text(store.healthStatus(record)).font(.subheadline)
                    if !record.isDemo && !store.healthIsSaved(record) {
                        Button(store.healthSaving.contains(record.id) ? "正在同步…" : "同步到苹果健康") { store.saveToHealth(record) }
                            .disabled(store.healthSaving.contains(record.id))
                    }
                    Text(record.isDemo ? "演示记录不写入健康" : "仅点击后同步这一次记录，不影响其他记录。保存为“其他”训练，次数和节奏为附加数据；已写入的训练需到健康 App 删除。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("导出") {
                    Button("生成本次摘要 CSV") {
                        do { export = try store.summaryExport([record]) } catch { store.errorMessage = error.localizedDescription }
                    }
                    if let export { ShareLink("分享摘要 CSV", item: export) }
                    if record.motionSummary != nil {
                        Button("生成过程曲线 CSV") {
                            do { timelineExport = try store.timelineExport(record) } catch { store.errorMessage = error.localizedDescription }
                        }
                        if let timelineExport { ShareLink("分享过程曲线 CSV", item: timelineExport) }
                    }
                    if let raw = store.rawURL(record) { ShareLink("分享原始运动 CSV", item: raw) }
                    else if record.csvFilename != nil { Text("原始 CSV 等待传输").foregroundStyle(.secondary) }
                    else { Text("本次未开启原始 CSV 采集").foregroundStyle(.secondary) }
                }
            }
        }.navigationTitle("记录详情").navigationBarTitleDisplayMode(.inline)
    }
}

private struct HeartCurvePoint: Identifiable {
    let seconds: Double
    let value: Double
    let run: Int
    var id: Double { seconds }
}

private struct MotionAnalysisView: View {
    let summary: MotionSummary
    let duration: Double
    private var heartPoints: [HeartCurvePoint] {
        var result: [HeartCurvePoint] = []
        var run = 0
        var previousSegment: Int?
        for point in summary.timeline {
            if previousSegment != point.segment { run += 1 }
            previousSegment = point.segment
            guard let heart = point.heartRate else { run += 1; continue }
            result.append(HeartCurvePoint(seconds: point.seconds, value: heart, run: run))
        }
        return result
    }
    var body: some View {
        Section("运动 / 静止") {
            LabeledContent("运动时长（估计）", value: seconds(summary.movementSeconds))
            LabeledContent("静止时长（估计）", value: seconds(summary.stillSeconds))
            LabeledContent("未观测", value: seconds(summary.unobservedSeconds))
            Text("仅统计佩戴者手腕；静止不会自动暂停。手动暂停已排除，传感器断流不算静止。")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("运动强度与节奏") {
            LabeledContent("平均强度 · RMS", value: intensity(summary.rmsAccelerationG))
            LabeledContent("最高瞬时强度", value: intensity(summary.peakAccelerationG))
            LabeledContent("最快节奏", value: summary.fastestCadence.map { String(format: "%.0f 次/分", $0) } ?? "无数据")
            LabeledContent("节奏稳定性", value: summary.rhythmStability.map { String(format: "%.0f%%", $0) } ?? "动作不足")
            Text("强度为去重力加速度，单位 g，不是力量或位移。每秒 RMS ≥ \(String(format: "%.2f", summary.movementThresholdG)) g 暂判为运动，需真机校准。稳定性根据连续动作间隔波动计算，越高越均匀；至少需要 4 个有效间隔，不是健康或表现评分。")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("过程对照") {
            if summary.timeline.isEmpty {
                Text("未采集到足够的过程数据").foregroundStyle(.secondary)
            } else {
                Text("心率 · 次/分").font(.caption).foregroundStyle(.pink)
                if heartPoints.isEmpty {
                    Text("未采集到心率").font(.caption).foregroundStyle(.secondary)
                } else {
                    Chart(heartPoints) { point in
                        LineMark(x: .value("记录秒数", point.seconds), y: .value("心率", point.value), series: .value("连续段", point.run)).foregroundStyle(.pink)
                        PointMark(x: .value("记录秒数", point.seconds), y: .value("心率", point.value)).foregroundStyle(.pink).symbolSize(6)
                    }.chartXScale(domain: 0...max(1, duration)).frame(height: 140)
                }
                Text("运动节奏 · 次/分").font(.caption).foregroundStyle(.mint)
                Chart(summary.timeline) { point in
                    LineMark(x: .value("记录秒数", point.seconds), y: .value("节奏", point.cadence), series: .value("连续段", point.segment)).foregroundStyle(.mint)
                }.chartXScale(domain: 0...max(1, duration)).frame(height: 140)
                Text("运动强度 · g").font(.caption).foregroundStyle(.cyan)
                Chart(summary.timeline) { point in
                    LineMark(x: .value("记录秒数", point.seconds), y: .value("强度", point.intensityG), series: .value("连续段", point.segment)).foregroundStyle(.cyan)
                }.chartXScale(domain: 0...max(1, duration)).frame(height: 110)
                Text("三图共用记录秒数，排除手动暂停。心率取最近 30 秒内的可用值，缺失处留空；节奏和强度按秒汇总。长记录会抽稀曲线（当前约 \(summary.timelineStrideSeconds) 秒/点），汇总统计仍保留。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func seconds(_ value: Double) -> String { String(format: "%.1f 秒", value) }
    private func intensity(_ value: Double?) -> String { value.map { String(format: "%.3f g", $0) } ?? "无数据" }
}
