//
//  SpeedTestView.swift
//  Unspoken
//
//  The Speed Test sheet: a progress ring while the run happens, then a plain-language
//  verdict. Numbers are kept in a collapsed "Details" section so the conclusion — the part
//  a non-technical user needs — is never buried under them.
//

import SwiftUI

extension SpeedTestReport.Grade {
    var color: Color {
        switch self {
        case .excellent: return Color(red: 0.20, green: 0.85, blue: 0.45)
        case .good:      return Color(red: 0.45, green: 0.85, blue: 0.95)
        case .fair:      return Color(red: 1.00, green: 0.78, blue: 0.30)
        case .poor:      return Color(red: 1.00, green: 0.45, blue: 0.45)
        }
    }

    var symbol: String {
        switch self {
        case .excellent: return "checkmark.circle.fill"
        case .good:      return "checkmark.circle"
        case .fair:      return "exclamationmark.circle"
        case .poor:      return "exclamationmark.triangle.fill"
        }
    }
}

struct SpeedTestView: View {
    let host: String
    let port: String
    let useSSL: Bool
    let userId: String
    let publicKeyBase64: String?

    @Environment(\.presentationMode) private var presentationMode
    @StateObject private var runner = SpeedTestRunner()
    @State private var showDetails = false

    var body: some View {
        ZStack {
            LinearGradient(gradient: Gradient(colors: [Color.blue.opacity(0.75), Color.purple.opacity(0.75)]),
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .edgesIgnoringSafeArea(.all)

            ScrollView {
                VStack(spacing: 22) {
                    header

                    if let report = runner.report {
                        resultCard(report)
                        detailsCard(report)
                    } else if runner.phase == .failed {
                        failureCard
                    } else {
                        progressRing
                    }

                    buttons
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 28)
            }
        }
        .onAppear { runTest() }
        .onDisappear { runner.cancel() }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(spacing: 6) {
            Text("Connection Check")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Text("\(host):\(port)")
                .font(.footnote)
                .foregroundColor(.white.opacity(0.65))
            Text("We send a few test messages, a test photo and a short voice burst — nothing is stored, and no room is created.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundColor(.white.opacity(0.55))
                .padding(.top, 2)
        }
    }

    private var progressRing: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.2), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: max(0.02, runner.progress))
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.3), value: runner.progress)
                Text("\(Int(runner.progress * 100))%")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
            }
            .frame(width: 150, height: 150)

            Text(runner.phase.caption)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.85))
        }
        .padding(.vertical, 20)
    }

    private func resultCard(_ report: SpeedTestReport) -> some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: report.grade.symbol)
                    .font(.system(size: 30))
                    .foregroundColor(report.grade.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(report.grade.title)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(report.grade.color)
                    Text(report.headline)
                        .font(.subheadline)
                        .foregroundColor(.white)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            Divider().background(Color.white.opacity(0.25))

            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(report.plainFindings.enumerated()), id: \.offset) { _, finding in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: finding.icon)
                            .font(.system(size: 15))
                            .foregroundColor(finding.grade.color)
                            .frame(width: 22)
                        Text(finding.text)
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.95))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(18)
        .background(Color.white.opacity(0.18))
        .cornerRadius(16)
    }

    private func detailsCard(_ report: SpeedTestReport) -> some View {
        VStack(spacing: 0) {
            Button(action: { withAnimation { showDetails.toggle() } }) {
                HStack {
                    Text("Details")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white.opacity(0.9))
                    Spacer()
                    Image(systemName: showDetails ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }

            if showDetails {
                VStack(spacing: 8) {
                    ForEach(Array(report.detailRows.enumerated()), id: \.offset) { _, row in
                        HStack {
                            Text(row.0)
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.6))
                            Spacer()
                            Text(row.1)
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.white)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 16)
            }
        }
        .background(Color.white.opacity(0.12))
        .cornerRadius(14)
    }

    private var failureCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 34))
                .foregroundColor(Color(red: 1.0, green: 0.6, blue: 0.4))
            Text("The test couldn't finish")
                .font(.headline)
                .foregroundColor(.white)
            Text(runner.errorMessage ?? "Something went wrong.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundColor(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .background(Color.white.opacity(0.18))
        .cornerRadius(16)
    }

    private var buttons: some View {
        VStack(spacing: 12) {
            if !runner.isRunning {
                Button(action: runTest) {
                    Text(runner.report == nil ? "Try Again" : "Test Again")
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(Color.white.opacity(0.22))
                        .cornerRadius(12)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.4), lineWidth: 1))
                }
            }
            Button(action: {
                runner.cancel()
                presentationMode.wrappedValue.dismiss()
            }) {
                Text(runner.isRunning ? "Cancel" : "Done")
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(Color.black.opacity(0.18))
                    .cornerRadius(12)
            }
        }
    }

    private func runTest() {
        showDetails = false
        runner.start(host: host.trimmingCharacters(in: .whitespaces),
                     port: port.trimmingCharacters(in: .whitespaces),
                     useSSL: useSSL,
                     userId: userId,
                     publicKeyBase64: publicKeyBase64)
    }
}
