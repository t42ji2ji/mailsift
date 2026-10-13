import Foundation

/// Text decoding with IANA charset names and the fallbacks real mail needs.
enum Charsets {
    /// Maps an IANA/MIME charset label to an encoding. Labels that real mailers misuse are widened to supersets.
    static func encoding(for label: String) -> String.Encoding? {
        var name = label.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t")).lowercased()
        if let star = name.firstIndex(of: "*") { name = String(name[..<star]) }   // RFC 2231 language suffix
        switch name {
        case "", "unknown", "unknown-8bit", "x-unknown", "default", "charset": return nil
        case "utf8", "utf-8", "x-utf8": return .utf8
        case "us-ascii", "ascii", "ansi_x3.4-1968": return .ascii
        // gb2312-labelled mail routinely contains GBK characters; GB18030 is a superset of both.
        case "gb2312", "gbk", "x-gbk", "cp936", "euc-cn", "x-euc-cn", "gb_2312-80", "chinese", "csgb2312", "gb18030":
            return cf(.GB_18030_2000)
        case "big5", "x-big5", "csbig5", "cn-big5": return cf(.big5)
        case "big5-hkscs": return cf(.big5_HKSCS_1999)
        case "cp950", "windows-950", "x-windows-950", "ms950": return cf(.dosChineseTrad)
        case "ks_c_5601-1987", "ks_c_5601", "korean", "euc-kr", "cp949", "windows-949": return cf(.dosKorean)
        case "shift_jis", "shift-jis", "sjis", "x-sjis", "ms_kanji", "cp932", "windows-31j": return cf(.dosJapanese)
        case "latin1", "iso-8859-1", "iso8859-1", "iso_8859-1": return .windowsCP1252 // as browsers do
        case "tis-620", "windows-874": return cf(.dosThai)
        default: break
        }
        let cfEnc = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEnc != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEnc))
    }

    private static func cf(_ e: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(e.rawValue)))
    }

    private static let big5 = cf(.big5)
    private static let cp950 = cf(.dosChineseTrad)
    private static let gb18030 = cf(.GB_18030_2000)

    /// Decodes bytes labelled with `charset`. Never fails.
    /// - Declared charset decodes strictly; text that is valid UTF-8 despite another label is taken as UTF-8;
    ///   otherwise the declared charset decodes lossily (one bad byte must not flip a whole part to another charset).
    /// - Undeclared (or us-ascii with 8-bit bytes): utf-8, big5, cp950, gb18030, nearly-valid utf-8, latin1.
    static func decode(_ bytes: some Collection<UInt8>, charset: String?) -> String {
        let data = Data(bytes)
        if data.isEmpty { return "" }
        let label = charset?.lowercased() ?? ""
        if !data.contains(where: { $0 >= 0x80 }), !label.contains("2022"), !label.hasPrefix("utf-7") {
            return String(decoding: data, as: UTF8.self)   // pure ASCII
        }
        if let enc = charset.flatMap({ encoding(for: $0) }), enc != .ascii {
            let family = enc == big5 ? [big5, cp950] : [enc]
            for e in family { if let s = String(data: data, encoding: e) { return s } }
            if enc != .utf8, let s = String(data: data, encoding: .utf8) { return s }
            if enc == .utf8 {
                // Mislabelled big5 is common enough to check; otherwise keep UTF-8 and replace the broken bytes.
                for e in [big5, cp950] { if let s = String(data: data, encoding: e) { return s } }
                return lossy(data)
            } else if let s = lossyDecode(data, family.last!) {
                return s
            }
        }
        for enc in [String.Encoding.utf8, big5, cp950, gb18030] {
            if let s = String(data: data, encoding: enc) { return s }
        }
        let utf8 = lossy(data)
        if replacementRatio(utf8) < 0.05 { return utf8 }
        return String(data: data, encoding: .isoLatin1) ?? utf8
    }

    /// Decodes in `enc`, replacing invalid sequences.
    private static func lossyDecode(_ data: Data, _ enc: String.Encoding) -> String? {
        var converted: NSString?
        var usedLossy = ObjCBool(false)
        let got = NSString.stringEncoding(
            for: data,
            encodingOptions: [.suggestedEncodingsKey: [enc.rawValue], .useOnlySuggestedEncodingsKey: true, .allowLossyKey: true],
            convertedString: &converted, usedLossyConversion: &usedLossy)
        return got == enc.rawValue ? converted as String? : nil
    }

    private static func lossy(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    private static func replacementRatio(_ s: String) -> Double {
        var bad = 0, total = 0
        for u in s.unicodeScalars { total += 1; if u == "\u{FFFD}" { bad += 1 } }
        return Double(bad) / Double(max(total, 1))
    }
}
