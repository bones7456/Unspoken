//
//  MemeSearchView.swift
//  Unspoken
//
// Uses Baidu Image Search's internal JSON endpoint — no API key or registration required.
//

import SwiftUI
import UIKit

private struct MemeImage: Identifiable {
    let id: String
    let thumbnailURL: String
    let contentURL: String
}

struct MemeSearchView: View {
    let onSend: (UIImage) -> Void
    @Environment(\.dismiss) var dismiss

    @State private var query = ""
    @State private var images: [MemeImage] = []
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var isSending = false
    @State private var errorMessage: String? = nil
    @State private var nextPn = 0
    @State private var hasMore = false

    private let pageSize = 40
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 4)

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    TextField("Search memes, e.g. happy", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.search)
                        .onSubmit { performSearch() }
                    Button(action: performSearch) {
                        Image(systemName: "magnifyingglass").padding(8)
                    }
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)
                }
                .padding()

                if let error = errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundColor(.red)
                        .padding(.horizontal)
                }

                if isLoading {
                    Spacer(); ProgressView(); Spacer()
                } else if images.isEmpty {
                    Spacer()
                    Text("Enter a keyword to search for memes").foregroundColor(.secondary)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 4) {
                            ForEach(images) { item in
                                Color.clear
                                    .aspectRatio(1, contentMode: .fit)
                                    .overlay(
                                        AsyncImage(url: URL(string: item.thumbnailURL)) { phase in
                                            switch phase {
                                            case .success(let image):
                                                image.resizable().scaledToFill()
                                            case .failure:
                                                Color.gray.opacity(0.2)
                                                    .overlay(Image(systemName: "photo").foregroundColor(.gray))
                                            default:
                                                Color.gray.opacity(0.2).overlay(ProgressView().scaleEffect(0.6))
                                            }
                                        }
                                    )
                                    .clipped()
                                    .cornerRadius(8)
                                    .opacity(isSending ? 0.5 : 1.0)
                                    .onTapGesture {
                                        guard !isSending else { return }
                                        downloadAndSend(item)
                                    }
                            }
                        }
                        .padding(8)

                        if hasMore {
                            Color.clear.frame(height: 1).onAppear { loadMore() }
                            if isLoadingMore { ProgressView().padding(.vertical, 8) }
                        }
                    }
                }

                if isSending {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Sending...").font(.footnote).foregroundColor(.secondary)
                    }
                    .padding(.bottom, 8)
                }
            }
            .navigationTitle("Search Memes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func performSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        images = []
        nextPn = 0
        hasMore = false
        fetch(pn: 0, appending: false)
    }

    private func loadMore() {
        guard hasMore, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        fetch(pn: nextPn, appending: true)
    }

    private func fetch(pn: Int, appending: Bool) {
        let q = query.trimmingCharacters(in: .whitespaces)
        let term = q + "表情包"
        let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? term
        let urlStr = "https://image.baidu.com/search/acjson?tn=resultjson_com&ipn=rj&ct=201326592&fp=result&word=\(encoded)&queryWord=\(encoded)&ie=utf-8&oe=utf-8&ic=0&istype=2&pn=\(pn)&rn=\(pageSize)"
        guard let url = URL(string: urlStr) else {
            isLoading = false; isLoadingMore = false; return
        }
        var request = URLRequest(url: url)
        request.setValue("https://image.baidu.com", forHTTPHeaderField: "Referer")

        URLSession.shared.dataTask(with: request) { data, _, _ in
            DispatchQueue.main.async {
                isLoading = false
                isLoadingMore = false
                guard let data,
                      let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let results = json["data"] as? [[String: Any]] else {
                    errorMessage = "Network error"; return
                }
                let newItems = results.compactMap { item -> MemeImage? in
                    guard let thumb = item["thumbURL"] as? String, !thumb.isEmpty else { return nil }
                    let content = (item["middleURL"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? thumb
                    return MemeImage(id: UUID().uuidString, thumbnailURL: thumb, contentURL: content)
                }
                if appending {
                    images.append(contentsOf: newItems)
                } else {
                    images = newItems
                    if images.isEmpty { errorMessage = "No results found"; return }
                }
                hasMore = newItems.count >= pageSize
                nextPn = pn + pageSize
            }
        }.resume()
    }

    private func downloadAndSend(_ item: MemeImage) {
        guard let url = URL(string: item.contentURL) else { return }
        isSending = true
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let image = UIImage(data: data) else {
                DispatchQueue.main.async { isSending = false; errorMessage = "Failed to load image" }
                return
            }
            onSend(image)
            DispatchQueue.main.async { isSending = false; dismiss() }
        }.resume()
    }
}
