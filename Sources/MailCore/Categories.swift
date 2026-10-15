import Foundation

/// What a message is for. Most are found by comparing mail against a description; 關係 and part of 工作 come from
/// who sent it. Built-in categories can be reordered and hidden; custom ones (a name and a description) also edited
/// and removed.
public struct MailCategory: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public var name: String
    /// What the embedding compares mail against; empty for categories found by sender.
    public var description: String
    /// Hidden from the chips; mail is still labelled with it.
    public var hidden = false

    public init(id: String, name: String, description: String, hidden: Bool = false) {
        self.id = id; self.name = name; self.description = description; self.hidden = hidden
    }

    /// A new custom category.
    public init(name: String, description: String) {
        self.init(id: "custom-" + UUID().uuidString.lowercased(), name: name, description: description)
    }

    public var isBuiltIn: Bool { Self.builtIn.contains { $0.id == id } }

    public static let work = MailCategory(id: "work", name: "工作",
        description: "同事之間的工作討論、專案進度、會議邀請與紀錄、合作夥伴往來、文件分享與留言、人資薪資 work discussion with colleagues, project, meeting, partner, shared document, comment")
    /// Mail from people she writes to; found by sender, not by embedding.
    public static let people = MailCategory(id: "people", name: "關係", description: "")
    public static let transactions = MailCategory(id: "transactions", name: "交易",
        description: "帳單、收據、發票、付款扣款與轉帳、刷卡交易、入金出金、匯款入帳、對帳單、訂單確認、出貨物流、機票訂房與行程、叫車收據 bill, receipt, invoice, payment, card transaction, deposit, withdrawal, statement, order, shipping, delivery, flight, hotel booking")
    public static let notifications = MailCategory(id: "notifications", name: "通知",
        description: "登入通知、驗證碼、密碼重設、帳號與權限變更、服務條款更新、社群訊息通知、預約與活動提醒 sign-in alert, verification code, password reset, account access notice, terms update, social notification, reminder")
    public static let dev = MailCategory(id: "dev", name: "開發",
        description: "App Store Connect、TestFlight、GitHub、雲端服務、部署、錯誤報告、API 與開發者帳號通知 app review, build, code review, deploy, cloud platform, developer account")
    public static let newsletter = MailCategory(id: "newsletter", name: "電子報",
        description: "訂閱的電子報、文章、部落格、科技與財經新聞摘要 newsletter, article, essay, blog post, weekly digest")
    public static let promo = MailCategory(id: "promo", name: "促銷",
        description: "優惠、折扣、特價、行銷廣告、新產品功能宣傳、課程與活動招生 promotion, sale, discount, coupon, marketing, product announcement, webinar invite")
    /// Mail no category fits well; stored but not offered as a chip.
    public static let other = MailCategory(id: "other", name: "其他", description: "")

    /// The default categories, in the default order.
    public static let builtIn = [work, people, transactions, notifications, dev, newsletter, promo]

    /// The saved list made whole: built-ins keep their code-defined name and description but the saved place and
    /// visibility; built-ins missing from the save are appended.
    static func merged(_ saved: [MailCategory]) -> [MailCategory] {
        var result: [MailCategory] = saved.compactMap { c in
            guard let def = builtIn.first(where: { $0.id == c.id }) else { return c.id.hasPrefix("custom-") ? c : nil }
            var b = def
            b.hidden = c.hidden
            return b
        }
        result += builtIn.filter { b in !result.contains { $0.id == b.id } }
        return result
    }
}

extension MailLibrary {
    static let seedsPerCategory = 200
    static let seedsPerSender = 10
    static let minSeeds = 30
    /// A message needs this lead over its runner-up to be labelled on its own.
    static let categoryMargin: Float = 0.025

    /// The categories in display order, hidden ones included.
    public func categories() -> [MailCategory] {
        MailCategory.merged((try? store.categoryDefinitions()) ?? [])
    }

    /// Saves order, visibility and custom categories. Mail is relabelled on the next index run when what is compared
    /// against changed.
    public func saveCategories(_ categories: [MailCategory]) throws {
        try store.setCategoryDefinitions(MailCategory.merged(categories))
    }

    /// Identifies what labelling depends on, so a change to it relabels everything.
    func categorySignature() -> String {
        categories().filter { !$0.description.isEmpty }.map { $0.id + ":" + $0.description }.joined(separator: "\n")
    }

    /// Messages per category id in `box`.
    public func categoryCounts(_ box: BrowseBox, accounts: [String]? = nil) -> [String: Int] {
        (try? store.categoryCounts(box, accounts: accounts)) ?? [:]
    }

    /// Category id per embedded message.
    func categorize() async throws -> [Int64: String] {
        guard let embedder = locked({ embedder }) else { return [:] }
        let embedded = categories().filter { !$0.description.isEmpty }
        guard embedded.count >= 2 else { return [:] }
        var described: [[Float]] = []
        for c in embedded { described.append(try await embedder.embedQuery(c.description)) }
        let k = described.count
        let senders = try store.senderAddresses()
        let correspondents = (try? source.correspondents()) ?? []
        let workDomains = Set(try store.accountList().compactMap(Self.domain).filter { !Self.publicDomains.contains($0) })

        // Round one: mail against the category descriptions.
        let (ids, byDescription) = try searcher.scores(described)
        let first = Self.ranked(byDescription, k: k)

        // Round two: each category's surest mail (no sender dominating) becomes a mail-to-mail centre, averaged
        // with the description score so a category cannot drift from its definition.
        var centres: [[Float]] = []
        var anchored = Set<Int>()
        for j in 0..<k {
            var perSender: [String: Int] = [:]
            let seeds = first.indices.filter { first[$0].best == j && first[$0].margin >= Self.categoryMargin }
                .sorted { first[$0].margin > first[$1].margin }
                .filter { i in
                    let s = senders[ids[i], default: ""]
                    perSender[s, default: 0] += 1
                    return perSender[s]! <= Self.seedsPerSender
                }
                .prefix(Self.seedsPerCategory)
            if seeds.count >= Self.minSeeds {
                centres.append(try searcher.mean(seeds.map { ids[$0] }))
                anchored.insert(j)
            } else {
                centres.append(described[j])
            }
        }
        let (_, byMail) = try searcher.scores(centres)
        var combined = byDescription
        for i in ids.indices {
            for j in anchored { combined[i * k + j] = (byDescription[i * k + j] + byMail[i * k + j]) / 2 }
        }
        let final = Self.ranked(combined, k: k)

        // Unsure mail takes its sender's usual category, when the sender has one.
        var votes: [String: [Int: Int]] = [:]
        for i in ids.indices where final[i].margin >= Self.categoryMargin {
            votes[senders[ids[i], default: ""], default: [:]][final[i].best, default: 0] += 1
        }
        let workIndex = embedded.firstIndex { $0.id == MailCategory.work.id }
        var labels: [Int64: String] = [:]
        for i in ids.indices {
            let sender = senders[ids[i], default: ""]
            let person = !Self.isAutomated(sender)
            if person, let d = Self.domain(sender), workDomains.contains(d) {
                labels[ids[i]] = MailCategory.work.id
            } else if person, correspondents.contains(sender) {
                labels[ids[i]] = final[i].best == workIndex ? MailCategory.work.id : MailCategory.people.id
            } else if final[i].margin >= Self.categoryMargin {
                labels[ids[i]] = embedded[final[i].best].id
            } else if let tally = votes[senders[ids[i], default: ""]], let top = tally.max(by: { $0.value < $1.value }),
                      top.value >= 3, Double(top.value) >= 0.6 * Double(tally.values.reduce(0, +)) {
                labels[ids[i]] = embedded[top.key].id
            } else {
                labels[ids[i]] = MailCategory.other.id
            }
        }
        return labels
    }

    static let publicDomains: Set<String> = [
        "gmail.com", "googlemail.com", "icloud.com", "me.com", "mac.com", "outlook.com", "hotmail.com", "live.com",
        "yahoo.com", "yahoo.com.tw", "proton.me", "protonmail.com",
    ]

    static func domain(_ address: String) -> String? {
        address.split(separator: "@").last.map { $0.lowercased() }
    }

    /// Addresses machines send from (no-reply, notifications, newsletters…), not people.
    static func isAutomated(_ address: String) -> Bool {
        let local = address.split(separator: "@").first.map(String.init) ?? address
        return local.range(of: #"no-?reply|do-?not-?reply|notif|mailer|news|bounce|^(info|support|service|updates?|hello|team|marketing|alerts?|billing|receipts?|account|security)$"#,
                           options: .regularExpression) != nil
    }

    private static func ranked(_ scores: [Float], k: Int) -> [(best: Int, margin: Float)] {
        stride(from: 0, to: scores.count, by: k).map { base in
            var best = 0, top = -Float.infinity, second = -Float.infinity
            for j in 0..<k {
                let s = scores[base + j]
                if s > top { second = top; top = s; best = j } else if s > second { second = s }
            }
            return (best, top - second)
        }
    }
}
