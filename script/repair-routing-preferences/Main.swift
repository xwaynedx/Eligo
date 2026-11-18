import Foundation

@main
enum RepairRoutingPreferences {
    static func main() {
        do {
            try run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("Repair failed: \(error.localizedDescription)\nThe source and live preferences were not changed. Do not use incomplete output.\n".utf8))
            exit(1)
        }
    }

    private static func run(_ args: [String]) throws {
        let allowedOptions: Set<String> = ["--keep", "--discard-rules", "--keep-scope", "--discard-scope", "--output"]
        guard (args.count == 2 && args[0] == "inspect")
                || (args.count >= 4 && args.count.isMultiple(of: 2) && args[0] == "prepare")
        else {
            print("""
            Usage:
              repair-routing-preferences inspect EXPORTED.plist
              repair-routing-preferences prepare EXPORTED.plist --output NEW_DIRECTORY [choices]

            Choices (comma-separated entry numbers, only when reported):
              --keep 2,5          Retain one rule from EACH rule conflict.
              --discard-rules 3   Explicitly discard EVERY invalid rule.
              --keep-scope 1      Retain one Scope entry from EACH Scope conflict.
              --discard-scope 4   Explicitly discard EVERY invalid Scope entry.

            Rule and Scope numbering is separate. Unrelated entries are always retained.
            This tool only reads the supplied export and creates backup/candidate files.
            See docs/routing-preferences-recovery.md for the separate installation steps.
            """)
            exit(args.isEmpty ? 0 : 1)
        }
        var options: [String: String] = [:]
        for index in stride(from: 2, to: args.count, by: 2) {
            guard allowedOptions.contains(args[index]), options[args[index]] == nil else {
                throw RoutingPreferencesRecoveryError.unresolvedConflicts
            }
            options[args[index]] = args[index + 1]
        }
        let source = URL(fileURLWithPath: args[1])
        let export = try RoutingRecoveryExport(data: Data(contentsOf: source))
        try report(export.recovery)
        guard args[0] == "prepare" else { return }
        guard let outputPath = options["--output"], !outputPath.isEmpty else {
            throw RoutingPreferencesRecoveryError.invalidExport
        }
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try export.writeCandidate(
            keepingRuleNumbers: numbers(options["--keep"]),
            discardingRuleNumbers: numbers(options["--discard-rules"]),
            keepingScopeNumbers: numbers(options["--keep-scope"]),
            discardingScopeNumbers: numbers(options["--discard-scope"]),
            to: output
        )
        print("\nValidated candidate and original backups saved in \(output.path)")
        print("Live preferences have not been changed. Review the candidate before installation.")
    }

    private static func numbers(_ input: String?) throws -> Set<Int> {
        guard let input else { return [] }
        let parts = input.split(separator: ",", omittingEmptySubsequences: false)
        let values = parts.compactMap { Int($0) }
        guard values.count == parts.count, Set(values).count == values.count,
              values.allSatisfy({ $0 > 0 })
        else { throw RoutingPreferencesRecoveryError.unresolvedConflicts }
        return Set(values)
    }

    private static func report(_ recovery: RoutingPreferencesRecovery) throws {
        if !recovery.needsRepair { print("No host-normalization repairs found.") }
        for conflict in recovery.conflicts {
            print("\nRule conflict: \(conflict.matcher.normalizedHost), includes subdomains: \(conflict.matcher.includesSubdomains)")
            for entry in conflict.entries {
                try printRecord([
                    "ruleNumber": entry.number, "id": entry.rule.id.uuidString,
                    "originalHost": entry.originalHost, "browserID": entry.rule.destinationID.browserID,
                    "mode": entry.rule.destinationID.mode.rawValue
                ])
            }
        }
        for entry in recovery.invalidRules {
            try printRecord([
                "invalidRuleNumber": entry.number, "id": entry.id.uuidString,
                "originalHost": entry.originalHost, "includesSubdomains": entry.includesSubdomains,
                "browserID": entry.destinationID.browserID, "mode": entry.destinationID.mode.rawValue,
                "reason": String(describing: entry.reason)
            ])
        }
        for conflict in recovery.scopeConflicts {
            print("\nScope conflict: \(conflict.matcher.normalizedHost), includes subdomains: \(conflict.matcher.includesSubdomains)")
            for entry in conflict.entries {
                try printRecord(["scopeNumber": entry.number, "originalHost": entry.originalHost])
            }
        }
        for entry in recovery.invalidScopeEntries {
            try printRecord([
                "invalidScopeNumber": entry.number, "originalHost": entry.originalHost,
                "includesSubdomains": entry.includesSubdomains, "reason": String(describing: entry.reason)
            ])
        }
    }

    private static func printRecord(_ record: [String: Any]) throws {
        // JSON escaping makes malformed historical hosts safe and unambiguous in a terminal.
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
