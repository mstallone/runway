import Foundation

/// Firefox stores cookies in plaintext SQLite rows, independently of its saved-password store.
/// Only Muse opts into these sources; Chromium providers keep their existing discovery behavior.
enum FirefoxBrowserCookies {
    static func discoverSources(homeDirectory: URL) -> [SakanaBrowserCookieSource] {
        let root = homeDirectory.appendingPathComponent("Library/Application Support/Firefox", isDirectory: true)
        let manager = FileManager.default
        var profiles: [(name: String, directory: URL)] = []
        if let registry = try? String(contentsOf: root.appendingPathComponent("profiles.ini"), encoding: .utf8) {
            for section in profileSections(registry) {
                guard let path = section["Path"], !path.isEmpty else { continue }
                let directory: URL
                if section["IsRelative"] == "0" {
                    guard path.hasPrefix("/") else { continue }
                    directory = URL(fileURLWithPath: path, isDirectory: true)
                } else {
                    directory = root.appendingPathComponent(path, isDirectory: true)
                }
                profiles.append((section["Name"] ?? directory.lastPathComponent, directory))
            }
        }
        // Also find profiles created by Firefox's profile manager before profiles.ini is updated.
        let directories = (try? manager.contentsOfDirectory(
            at: root.appendingPathComponent("Profiles", isDirectory: true),
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        profiles += directories.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { ($0.lastPathComponent, $0) }

        var seen = Set<String>()
        return profiles.compactMap { profile in
            let database = profile.directory.appendingPathComponent("cookies.sqlite")
                .standardizedFileURL.resolvingSymlinksInPath()
            guard manager.fileExists(atPath: database.path), seen.insert(database.path).inserted else { return nil }
            return SakanaBrowserCookieSource(
                browserName: "Firefox (\(profile.name))", databasePath: database.path,
                safeStorageService: "", format: .firefox
            )
        }
    }

    static func encodedRows(
        sqlite: any SQLiteAccessing, path: String, name: String, hosts: [String]
    ) throws -> [String] {
        let quotedHosts = hosts.map(quote).joined(separator: ", ")
        // Firefox uses Unix microseconds; Chromium uses microseconds since 1601. Normalize before
        // comparing profiles across browsers. Keep all rows so rejected container sessions can be skipped.
        let sql = """
        SELECT hex(CAST(host AS BLOB)) || '|' ||
               CAST(lastAccessed + 11644473600000000 AS TEXT) || '|plain:' ||
               hex(CAST(value AS BLOB)) AS cookieRow
        FROM moz_cookies
        WHERE name = \(quote(name))
          AND host IN (\(quotedHosts))
          AND expiry > CAST(strftime('%s', 'now') AS INTEGER)
          AND length(value) > 0
        ORDER BY lastAccessed DESC;
        """
        guard let json = try sqlite.queryJSONRows(path: path, sql: sql) else { return [] }
        struct Row: Decodable { var cookieRow: String }
        return try JSONDecoder().decode([Row].self, from: Data(json.utf8)).map(\.cookieRow)
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private static func profileSections(_ text: String) -> [[String: String]] {
        var sections: [[String: String]] = []
        var current: [String: String]?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("["), line.hasSuffix("]") {
                if let current { sections.append(current) }
                current = line.hasPrefix("[Profile") ? [:] : nil
            } else if current != nil, !line.hasPrefix(";"), !line.hasPrefix("#"),
                      let equals = line.firstIndex(of: "=") {
                let key = line[..<equals].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                current?[key] = value
            }
        }
        if let current { sections.append(current) }
        return sections
    }
}
