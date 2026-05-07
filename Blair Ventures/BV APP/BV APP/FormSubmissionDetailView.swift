// FormSubmissionDetailView.swift
// FieldOS – Read-only submission view with PDF export + legal certification

import SwiftUI

struct FormSubmissionDetailView: View {
    let submission: FormSubmission

    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    @State private var showShareSheet = false
    @State private var shareItems:  [Any] = []
    @State private var isGeneratingPDF = false
    @State private var showAISummary = false

    private var template: FormTemplate? {
        store.formTemplates.first { $0.id == submission.templateID }
    }

    private var responseMap: [UUID: FormFieldResponse] {
        Dictionary(uniqueKeysWithValues: submission.responses.map { ($0.fieldID, $0) })
    }

    private var projectName: String? {
        submission.projectID.flatMap { store.project(id: $0) }?.name
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {

                    headerCard.padding()

                    // AI Summary
                    AISummarizeButton(text: formTextForAI, context: "form submission")
                        .padding(.horizontal)
                        .padding(.bottom, 8)

                    // Legal certification banner (submitted forms only)
                    if !submission.isDraft {
                        certificationBanner
                            .padding(.horizontal)
                            .padding(.bottom, 8)
                    }

                    Divider()

                    // Field responses
                    if let tmpl = template {
                        LazyVStack(spacing: 0) {
                            ForEach(tmpl.orderedFields) { field in
                                fieldRow(field: field)
                                Divider().padding(.leading, 16)
                            }
                        }
                    } else {
                        Text("Form template no longer available.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding()
                    }

                    // Signature block
                    if submission.isSigned {
                        signatureCard.padding()
                    }

                    // Worker sign-offs
                    if !submission.workerSignatures.isEmpty {
                        workerSignaturesCard.padding(.horizontal)
                    }

                    Spacer(minLength: 40)
                }
            }
            .navigationTitle(template?.name ?? "Form Submission")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        Button { showAISummary = true } label: {
                            Image(systemName: "sparkles")
                        }
                        if isGeneratingPDF {
                            ProgressView().tint(.blue)
                        } else {
                            Button { exportPDF() } label: {
                                Image(systemName: "square.and.arrow.up")
                            }
                            .disabled(template == nil)
                        }
                    }
                }
            }
            .sheet(isPresented: $showShareSheet) {
                ShareSheet(items: shareItems)
            }
            .sheet(isPresented: $showAISummary) {
                AISummarySheet(
                    documentText: formTextForAI,
                    contextLabel: "form submission"
                )
            }
        }
    }

    private var formTextForAI: String {
        guard let tmpl = template else { return "No form data available." }
        var parts: [String] = ["Form: \(tmpl.name)"]
        if let proj = projectName { parts.append("Project: \(proj)") }
        parts.append("Submitted by: \(submission.submittedBy)")
        if let date = submission.submittedAt { parts.append("Date: \(date.formatted(date: .long, time: .shortened))") }
        for field in tmpl.orderedFields where !field.type.isLayoutOnly {
            if let r = responseMap[field.id] {
                let value = r.textValue ?? r.numberValue.map { "\($0)" } ?? r.selectedOptions?.joined(separator: ", ") ?? "—"
                parts.append("\(field.label): \(value)")
            }
        }
        return parts.joined(separator: "\n")
    }

    private var workerSignaturesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Worker Sign-offs (\(submission.workerSignatures.count))", systemImage: "person.badge.shield.checkmark.fill")
                .font(.headline)
                .padding(.bottom, 2)
            Divider()
            ForEach(submission.workerSignatures) { ws in
                HStack(spacing: 10) {
                    Image(systemName: ws.isSigned ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(ws.isSigned ? .green : .secondary)
                    Text(ws.employeeName).font(.subheadline)
                    Spacer()
                    if let date = ws.signedAt {
                        Text(date.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: - PDF Export

    private func exportPDF() {
        guard let tmpl = template else { return }
        isGeneratingPDF = true
        Task.detached(priority: .userInitiated) {
            let pdfData = FormPDFRenderer(
                submission:  submission,
                template:    tmpl,
                projectName: projectName,
                company:     "Aski IQ"
            ).render()

            // Write to a named temp file so Mail shows the correct filename
            let safeName = tmpl.name
                .components(separatedBy: .whitespacesAndNewlines)
                .joined(separator: "_")
            let shortID  = submission.id.uuidString.prefix(8).uppercased()
            let fileName = "\(safeName)_\(shortID).pdf"
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(fileName)
            try? pdfData.write(to: url)

            await MainActor.run {
                shareItems       = [url]
                isGeneratingPDF  = false
                showShareSheet   = true
            }
        }
    }

    // MARK: - Header Card

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(template?.name ?? "Unknown Form")
                        .font(.title3).bold()
                    if let cat = template?.category {
                        Text(cat)
                            .font(.caption)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color.blue.opacity(0.1))
                            .foregroundColor(.blue)
                            .cornerRadius(6)
                    }
                }
                Spacer()
                statusBadge
            }

            Divider()

            HStack(spacing: 20) {
                LabeledInfo(label: "Submitted by", value: submission.submittedBy)
                if let date = submission.submittedAt {
                    LabeledInfo(label: "Date", value: date.shortDate)
                }
                if let v = template?.version, v > 1 {
                    LabeledInfo(label: "Template", value: "v\(submission.templateVersion)")
                }
                if let proj = projectName {
                    LabeledInfo(label: "Project", value: proj)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(14)
    }

    private var statusBadge: some View {
        Group {
            if submission.isDraft {
                badgeView("Draft",     color: .orange, icon: "doc.badge.clock")
            } else if submission.isSigned {
                badgeView("Signed",    color: .green,  icon: "checkmark.seal.fill")
            } else {
                badgeView("Submitted", color: .blue,   icon: "doc.text")
            }
        }
    }

    private func badgeView(_ text: String, color: Color, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2)
            Text(text).font(.caption).bold()
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(color.opacity(0.12))
        .foregroundColor(color)
        .cornerRadius(8)
    }

    // MARK: - Legal Certification Banner

    private var certificationBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .foregroundColor(.green)
                    .font(.headline)
                Text("Certified Legal Record")
                    .font(.headline)
                    .foregroundColor(.green)
                Spacer()
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(.green)
                    .font(.title3)
            }

            Divider()

            if let hash = submission.auditHash {
                VStack(alignment: .leading, spacing: 3) {
                    Text("SHA-256 FINGERPRINT")
                        .font(.caption2).bold()
                        .foregroundColor(.secondary)
                    Text(String(hash.prefix(32)) + "…")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            if let submittedAt = submission.submittedAt {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SUBMITTED").font(.caption2).bold().foregroundColor(.secondary)
                        Text(submittedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                    }
                    if let hash = submission.auditHash {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("FORM ID").font(.caption2).bold().foregroundColor(.secondary)
                            Text(submission.id.uuidString.prefix(8).uppercased())
                                .font(.system(.caption, design: .monospaced))
                        }
                        .opacity(hash.isEmpty ? 0 : 1)
                    }
                }
            }

            Text("This document is tamper-evident. Any change to responses after submission invalidates the SHA-256 fingerprint.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.green.opacity(0.05))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.green.opacity(0.30), lineWidth: 1)
        )
        .cornerRadius(12)
    }

    // MARK: - Field Row

    @ViewBuilder
    private func fieldRow(field: FormField) -> some View {
        switch field.type {

        case .sectionHeader:
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Color.blue.opacity(0.6))
                    .frame(width: 3)
                Text(field.label)
                    .font(.headline)
                    .padding(.leading, 10)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.blue.opacity(0.06))

        case .instructions:
            VStack(alignment: .leading, spacing: 4) {
                if !field.label.isEmpty {
                    Text(field.label).font(.subheadline).bold()
                }
                if let body = field.bodyText {
                    Text(body).font(.subheadline).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.yellow.opacity(0.04))

        default:
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(field.label)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        if field.isRequired {
                            Text("*").font(.caption2).foregroundColor(.red)
                        }
                    }
                    responseDisplay(field: field)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Response Display

    @ViewBuilder
    private func responseDisplay(field: FormField) -> some View {
        let response = responseMap[field.id]

        switch field.type {

        case .shortText, .text, .longText:
            Text(response?.textValue ?? "—")
                .font(.body)
                .foregroundColor(response?.textValue == nil ? .secondary : .primary)

        case .number:
            HStack(spacing: 4) {
                Text(response?.numberValue.map { "\($0)" } ?? "—").font(.body)
                if let unit = field.unit {
                    Text(unit).font(.body).foregroundColor(.secondary)
                }
            }

        case .date:
            Text(response?.dateValue
                    .map { $0.formatted(date: .long, time: .omitted) } ?? "—")
                .font(.body)

        case .time:
            Text(response?.dateValue
                    .map { $0.formatted(date: .omitted, time: .shortened) } ?? "—")
                .font(.body)

        case .dateTime:
            Text(response?.dateValue.map { $0.formatted() } ?? "—").font(.body)

        case .yesNo, .passFail:
            if let bv = response?.boolValue {
                let label: String = field.type == .passFail
                    ? (bv ? "Pass" : "Fail")
                    : (bv ? "Yes"  : "No")
                let color: Color  = bv ? .green : .red
                Text(label).font(.body).bold().foregroundColor(color)
            } else {
                Text("—").foregroundColor(.secondary)
            }

        case .yesNoNA, .passFailNA:
            if let tv = response?.threeStateValue {
                let info = threeStateInfo(tv)
                Text(info.label).font(.body).bold().foregroundColor(info.color)
            } else {
                Text("—").foregroundColor(.secondary)
            }

        case .singleChoice, .dropdown:
            Text((response?.selectedOptions ?? []).first ?? "—").font(.body)

        case .multipleChoice:
            if let opts = response?.selectedOptions, !opts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(opts, id: \.self) { opt in
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.blue).font(.caption)
                            Text(opt).font(.body)
                        }
                    }
                }
            } else {
                Text("—").foregroundColor(.secondary)
            }

        case .rating:
            if let rv = response?.ratingValue {
                HStack(spacing: 3) {
                    ForEach(1...max(1, field.ratingMax), id: \.self) { star in
                        Image(systemName: rv >= star ? "star.fill" : "star")
                            .foregroundColor(rv >= star ? .yellow : .secondary)
                            .font(.subheadline)
                    }
                    Text("\(rv)/\(field.ratingMax)")
                        .font(.caption).foregroundColor(.secondary)
                        .padding(.leading, 4)
                }
            } else {
                Text("—").foregroundColor(.secondary)
            }

        case .slider:
            if let sv = response?.sliderValue {
                HStack(spacing: 8) {
                    if let minL = field.sliderMinLabel {
                        Text(minL).font(.caption).foregroundColor(.secondary)
                    }
                    ProgressView(value: (sv - field.sliderMin)
                                      / max(field.sliderMax - field.sliderMin, 1))
                        .frame(width: 120)
                    Text(String(format: sv.truncatingRemainder(dividingBy: 1) == 0
                                    ? "%.0f" : "%.1f", sv))
                        .font(.body).bold()
                    if let maxL = field.sliderMaxLabel {
                        Text(maxL).font(.caption).foregroundColor(.secondary)
                    }
                }
            } else {
                Text("—").foregroundColor(.secondary)
            }

        case .photo:
            if let photos = response?.photoData, !photos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(photos.enumerated()), id: \.offset) { _, data in
                            if let img = UIImage(data: data) {
                                Image(uiImage: img)
                                    .resizable().scaledToFill()
                                    .frame(width: 90, height: 90)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }
            } else {
                Text("No photo").foregroundColor(.secondary).font(.body)
            }

        case .scan:
            VStack(alignment: .leading, spacing: 6) {
                if let photos = response?.photoData, let first = photos.first,
                   let img = UIImage(data: first) {
                    Image(uiImage: img)
                        .resizable().scaledToFit()
                        .frame(maxHeight: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if let text = response?.textValue, !text.isEmpty {
                    Text(text).font(.caption).foregroundColor(.secondary)
                }
            }

        case .signature:
            if let data = response?.signatureData, let img = UIImage(data: data) {
                Image(uiImage: img)
                    .resizable().scaledToFit()
                    .frame(maxHeight: 80)
                    .background(Color.white)
                    .cornerRadius(8)
            } else {
                Text("No signature").foregroundColor(.secondary)
            }

        case .location:
            if let loc = response?.locationValue {
                VStack(alignment: .leading, spacing: 2) {
                    if let addr = loc.address { Text(addr).font(.body) }
                    Text(String(format: "%.5f, %.5f", loc.latitude, loc.longitude))
                        .font(.caption).foregroundColor(.secondary)
                }
            } else {
                Text("—").foregroundColor(.secondary)
            }

        case .sectionHeader, .instructions:
            EmptyView()
        }
    }

    // MARK: - Signature Card

    private var signatureCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Signature", systemImage: "signature").font(.headline)
            Divider()

            if let sigResponse = submission.responses.first(where: { $0.signatureData != nil }),
               let img = UIImage(data: sigResponse.signatureData!) {
                Image(uiImage: img)
                    .resizable().scaledToFit()
                    .frame(maxHeight: 120)
                    .padding(8)
                    .background(Color.white)
                    .cornerRadius(10)
            }

            HStack(spacing: 20) {
                if let signedBy = submission.signedBy {
                    LabeledInfo(label: "Signed by", value: signedBy)
                }
                if let signedAt = submission.signedAt {
                    LabeledInfo(label: "Signed at",
                                value: signedAt.formatted(date: .abbreviated, time: .shortened))
                }
            }
        }
        .padding()
        .background(Color.green.opacity(0.05))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.green.opacity(0.3), lineWidth: 1)
        )
        .cornerRadius(14)
    }
}

// MARK: - Three-State Helper

private func threeStateInfo(_ value: ThreeStateAnswer) -> (label: String, color: Color) {
    switch value {
    case .yes:  return ("Yes",  .green)
    case .no:   return ("No",   .red)
    case .na:   return ("N/A",  .secondary)
    case .pass: return ("Pass", .green)
    case .fail: return ("Fail", .red)
    }
}

// MARK: - Labeled Info

private struct LabeledInfo: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2).foregroundColor(.secondary)
                .textCase(.uppercase)
            Text(value).font(.caption).bold()
        }
    }
}
