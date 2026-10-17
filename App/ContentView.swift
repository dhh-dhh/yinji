import SwiftUI

private let mint = Color(red: 0.43, green: 0.95, blue: 0.77)

struct ContentView: View {
    @EnvironmentObject private var model: SessionModel
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                VStack(spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: "waveform.path").foregroundStyle(mint)
                        Text(model.running ? "隐记 · \(model.activeMode.title)" : "隐记").fontWeight(.semibold)
                        Spacer(minLength: 2)
                        Text(status).foregroundStyle(model.paused ? .orange : mint)
                    }
                    .font(.system(size: 12))
                    .lineLimit(1).minimumScaleFactor(0.8)

                    if model.running {
                        Spacer(minLength: 0)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("\(model.count)")
                                .font(.system(size: min(60, geometry.size.height * 0.29), weight: .semibold, design: .rounded))
                                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.45)
                            Text("次").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        HStack(spacing: 4) {
                            metric("时长", duration)
                            metric("节奏 /分", String(format: "%.0f", model.cadence))
                            metric("心率 /分", model.heartRate.map { String(format: "%.0f", $0) } ?? "—", color: .pink)
                        }
                        Spacer(minLength: 0)
                        HStack(spacing: 8) {
                            Button { model.togglePause() } label: {
                                Label(model.paused ? "继续" : "暂停", systemImage: model.paused ? "play.fill" : "pause.fill")
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .background(mint.opacity(0.18), in: Capsule()).foregroundStyle(mint)
                            }
                            .accessibilityLabel(model.paused ? "继续记录" : "暂停记录")
                            Button { model.finish() } label: {
                                Label("结束", systemImage: "stop.fill")
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .background(Color.red.opacity(0.22), in: Capsule()).foregroundStyle(.red)
                            }.accessibilityLabel("结束并保存记录")
                        }.font(.system(size: 13, weight: .semibold)).buttonStyle(.plain)
                    } else {
                        Spacer(minLength: 0)
                        HStack(spacing: 6) {
                            ForEach(RecordingMode.allCases, id: \.self) { mode in
                                Button { model.selectedMode = mode } label: {
                                    Label(mode.title, systemImage: mode.symbol)
                                        .font(.system(size: 13, weight: .semibold))
                                        .frame(maxWidth: .infinity, minHeight: 44)
                                        .background(model.selectedMode == mode ? mint.opacity(0.22) : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                                        .foregroundStyle(model.selectedMode == mode ? mint : .secondary)
                                }
                                .accessibilityLabel("\(mode.title)模式")
                                .accessibilityAddTraits(model.selectedMode == mode ? .isSelected : [])
                            }
                        }.buttonStyle(.plain).disabled(model.starting || model.needsSave)
                        Text(model.selectedMode == .partner ? "仅记录佩戴者的数据" : "手动开启 · 私密记录")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button {
                            if model.needsSave { model.retrySave() } else { model.start() }
                        } label: {
                            Label(startTitle, systemImage: model.needsSave ? "arrow.clockwise" : "play.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(mint, in: Capsule()).foregroundStyle(.black)
                        }.buttonStyle(.plain).disabled(model.starting)
                        HStack(spacing: 8) {
                            NavigationLink { HistoryView() } label: {
                                Label("历史", systemImage: "clock.arrow.circlepath")
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            NavigationLink { SettingsView() } label: {
                                Label("设置", systemImage: "slider.horizontal.3")
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                        }.font(.system(size: 12)).buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 5).padding(.vertical, 3)
                .frame(width: geometry.size.width, height: geometry.size.height)
            }.toolbar(.hidden, for: .navigationBar)
        }
        .tint(mint)
        .alert("提示", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("知道了") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
    private var status: String {
        if !model.running { return model.starting ? "等待授权" : "就绪" }
        if model.paused { return "已暂停" }
        if model.demo { return "演示" }
        if model.warmup > 0 { return "准备 \(Int(ceil(model.warmup))) 秒" }
        return "记录中"
    }
    private var startTitle: String {
        if model.needsSave { return "重试保存" }
        if model.starting { return "等待授权…" }
        return model.demo ? "开始演示" : "开始\(model.selectedMode.title)记录"
    }
    private var duration: String {
        let seconds = Int(model.elapsed)
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
    private func metric(_ title: String, _ value: String, color: Color = .primary) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.system(size: 18, weight: .medium, design: .rounded))
                .monospacedDigit().foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.65)
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }.frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct HistoryView: View {
    @EnvironmentObject private var model: SessionModel
    var body: some View {
        List {
            if model.records.isEmpty {
                Text("还没有记录\n完成一次后会显示在这里。")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.records) { record in
                NavigationLink {
                    RecordDetail(record: record)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(record.startedAt, format: .dateTime.month().day().hour().minute()).font(.caption)
                        Text("\(record.count) 次 · \(Int(record.duration)) 秒").font(.headline)
                        Label(record.mode.title, systemImage: record.mode.symbol).font(.caption2).foregroundStyle(mint)
                        if record.isDemo { Text("演示").font(.caption2).foregroundStyle(.orange) }
                    }
                }
            }
        }.navigationTitle("历史记录")
    }
}

struct RecordDetail: View {
    let record: SessionRecord
    @EnvironmentObject private var model: SessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    private var currentRecord: SessionRecord {
        model.records.first(where: { $0.id == record.id }) ?? record
    }
    var body: some View {
        List {
            Text(record.startedAt, format: .dateTime.month().day().hour().minute())
            LabeledContent("模式", value: record.mode.title)
            if record.mode == .partner { Text("仅记录佩戴者的心率与手腕运动；次数为检测到的运动峰值。").font(.caption2).foregroundStyle(.secondary) }
            LabeledContent("运动次数", value: "\(record.count)")
            LabeledContent("时长", value: "\(Int(record.duration)) 秒")
            LabeledContent("平均节奏", value: String(format: "%.0f 次/分", record.averageRPM))
            if record.isDemo { Text("这是一条演示记录").foregroundStyle(.orange) }
            if record.csvFilename != nil { Text("已保存原始运动数据").font(.caption) }
            if let bpm = currentRecord.averageHeartRate {
                LabeledContent("平均心率", value: String(format: "%.0f 次/分", bpm))
            }
            if let bpm = currentRecord.maximumHeartRate {
                LabeledContent("最高心率", value: String(format: "%.0f 次/分", bpm))
            }
            if let status = currentRecord.healthStatus {
                Text(status).font(.caption2)
                Text("默认不写入健康，请到 iPhone 本条记录选择同步。已写入的旧训练不会自动删除。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Button("删除记录", role: .destructive) { confirmDelete = true }
        }.navigationTitle("记录详情")
        .confirmationDialog("删除手表记录及运动数据？健康中的训练需在健康 App 单独删除。", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) { model.delete(record); dismiss() }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: SessionModel
    var body: some View {
        Form {
            Section("检测") {
                Picker("计数方式", selection: $model.axis) {
                    Text("三轴自动").tag("AUTO")
                    ForEach(["X", "Y", "Z"], id: \.self) { Text($0).tag($0) }
                }
                Picker("灵敏度", selection: $model.sensitivity) {
                    Text("高").tag(0.7)
                    Text("中").tag(1.0)
                    Text("低").tag(1.4)
                }
                Text("默认 Y 轴计数。漏计可提高灵敏度或尝试 X/Z 轴。三轴自动为实验选项，部分动作可能漏计。").font(.caption2)
            }
            Section("数据") {
                Toggle("保存原始 CSV", isOn: $model.saveRaw)
                Toggle("演示模式", isOn: $model.demo)
                Text("数据保存在此手表。真机记录使用体能训练会话，落腕、熄屏后继续，手动暂停或结束。授权后采集心率；若持续没有数据，请检查心率权限与佩戴。结束后仅保存到 App；可在 iPhone 每条记录中手动同步到苹果健康。可能影响活动圆环，不能与其他训练同时运行。演示模式仅供前台测试。CSV 可通过 Xcode 下载 App 容器提取。").font(.caption2)
            }
            Section("关于隐记") {
                Text("计数表示检测到的运动峰值，需真机校准；不判断行为类型或高潮状态。").font(.caption2)
                Text("运动检测：RepMotion\nMIT · Fernando B").font(.caption2)
            }
        }.navigationTitle("设置")
    }
}
