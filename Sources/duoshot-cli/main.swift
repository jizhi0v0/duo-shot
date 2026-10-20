
// `duoshot` — the command line's client. A standalone executable, signed with
// its own identifier and kept outside DuoShot.app, so that nothing an agent
// runs through it borrows DuoShot's privacy grants. See `CLIWire`.
CLIClient.main(Array(CommandLine.arguments.dropFirst()))
