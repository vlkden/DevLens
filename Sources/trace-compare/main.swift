//
//  main.swift
//  DevLens / trace-compare
//
//  Created by Denys Volkov.
//  MIT License.
//
//  Usage: swift run trace-compare before.records.json after.records.json
//  Both files come from APITrace.shared.exportJSON() (or the Share sheet).
//

import Foundation
import APITrace

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: trace-compare <before.records.json> <after.records.json>\n".data(using: .utf8)!)
    exit(2)
}

func load(_ path: String) -> APITrace.TraceFile {
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try APITrace.TraceFile.decode(data)
    } catch {
        FileHandle.standardError.write("trace-compare: cannot read \(path): \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

let before = load(args[1])
let after = load(args[2])
print(TraceCompare.render(TraceCompare.compare(before: before, after: after)))
