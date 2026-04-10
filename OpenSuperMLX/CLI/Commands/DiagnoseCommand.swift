// DiagnoseCommand.swift
// OpenSuperMLX

import Foundation

import ArgumentParser

struct DiagnoseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diagnose",
        abstract: "Run diagnostic checks"
    )

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
    }
}
