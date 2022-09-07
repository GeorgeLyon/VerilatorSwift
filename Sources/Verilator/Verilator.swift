import Foundation
import Shwift
import SystemPackage

public struct Verilator {
  public struct Configuration {

    public static var inferFromProcessEnvironment: Configuration {
      var environment: Environment = .process

      // Xcode doesn't inherit user environment variables,
      // so make sure the local bin path is searched
      // (which is where Homebrew installs it)
      let localBinPath = FilePath("/usr/local/bin")
      if !environment.searchPaths.contains(localBinPath) {
        environment["PATH"]!.append(":\(localBinPath)")
      }

      func findExecutable(named name: String) -> FilePath? {
        environment
          .searchForExecutables(named: name)
          .matches
          .first
      }
      return Configuration(
        verilator: Verilator(
          executablePath: findExecutable(named: "verilator")!),
        make: Make(
          executablePath: findExecutable(named: "make")!,
          tools: Make.Tools(
            cxxCompiler: findExecutable(named: "clang++")!,
            ld: findExecutable(named: "ld")!,
            ar: findExecutable(named: "ar")!,
            ccache: findExecutable(named: "ccache")),
          verilatorRoot: environment["VERILATOR_ROOT"].map(FilePath.init(_:))))
    }

    public struct Verilator {
      /**
       Path to the `verilator` executable
       */
      public let executablePath: FilePath
    }
    public let verilator: Verilator

    public struct Make {
      /**
       Path to the `make` executable
       */
      public var executablePath: FilePath

      /**
       We run `make` with no environment, and pass the necessary tools as arguments so that we may have fine-grained control over which tools are used (and potentially check for compatibility ahead of time). This also allows us to replace incompatible tools on certain platforms (for instance, using `llvm-ar` on macOS).
       */
      public struct Tools {
        /**
        Specifies the C++ compiler to use via the `CXX=<value>` argument to `make`
        */
        public var cxxCompiler: FilePath

        /**
        Path to the `ld` tool, passed via the `LD=<value>` argument to `make`
        */
        public var ld: FilePath

        /**
         Path to the `ar` tool, passed via the `AR=<value>` argument to `make`
         */
        public var ar: FilePath

        /**
         Path to the `ccache` tool, passed via the `OBJCACHE=<value>` argument to `make`
         */
        public var ccache: FilePath?
      }
      public var tools: Tools

      /**
       If non-`nil`, passes an additional `VERILATOR_ROOT=<value>` argument to `make`
       */
      public var verilatorRoot: FilePath?
    }
    public var make: Make

    fileprivate let outputLibraryName = "verilated"
  }

  public init(configuration: Configuration) {
    self.verilatorExecutablePath = configuration.verilator.executablePath
    self.makeExecutablePath = configuration.make.executablePath

    // swift-format-ignore
    self.verilatorSharedArguments = [
      /// Emit a C++ Executable
      "--cc", "--exe",

      "-LDFLAGS",
      [
        /// Link into a shared library
        "-shared", "-dynamic",

        /// Symbols are hidden by default
        "-fvisibility=hidden",
      ].joined(separator: " "),

      "-CFLAGS",
      [
        /// Compile shared objects
        "-fPIC",

        /// Symbols are hidden by default
        "-fvisibility=hidden",

        /// Avoid a spurious log
        "-Wno-unknown-warning-option",
      ].joined(separator: " "),

      "-o", configuration.outputLibraryName,
    ]

    // swift-format-ignore
    let tools = configuration.make.tools
    self.makeSharedArguments = [
      "AR=\(tools.ar.string(escapingSpaces: true))",
      "CXX=\(tools.cxxCompiler.string(escapingSpaces: true))",
      "LD=\(tools.ld.string(escapingSpaces: true))",
      "OBJCACHE=\(tools.ccache?.string(escapingSpaces: true) ?? "")",

      configuration.make.verilatorRoot.map { "VERILATOR_ROOT=\($0)" },
    ].compactMap { $0 }

    outputLibraryName = configuration.outputLibraryName
  }

  private let verilatorExecutablePath: FilePath
  private let verilatorSharedArguments: [String]
  private let makeExecutablePath: FilePath
  private let makeSharedArguments: [String]
  private let outputLibraryName: String
  private let shwiftContext = Shwift.Context()

  /// - parameter waveformDirectory: If supplied, tracing will be enabled
  ///   and a waveform file will be written at `waveformDirectory/<module-name>.vcd`
  public func verilate(
    topModule: ModuleDefinition,
    sourceFiles: [FilePath],
    in sourceDirectory: FilePath,
    waveformDirectory: FilePath? = nil
  ) async throws -> Simulation {
    let recorder = Shwift.Output.Recorder()
    let simulation: Simulation
    do {
      simulation = try await Shwift.Input.nullDevice.withFileDescriptor(
        in: shwiftContext
      ) { input in
        try await Shwift.Output.record(to: recorder.output).withFileDescriptor(in: shwiftContext) {
          output in
          try await Shwift.Output.record(to: recorder.error).withFileDescriptor(in: shwiftContext) {
            error in
            let fileDescriptors = Shwift.Process.FileDescriptorMapping(
              standardInput: input,
              standardOutput: output,
              standardError: error)

            let outputDirectory: FilePath
            do {
              let fileManager = FileManager.default
              let temporaryDirectory = FilePath(fileManager.temporaryDirectory.path)
              outputDirectory =
                temporaryDirectory
                .appending(ProcessInfo.processInfo.globallyUniqueString)
                .appending("\(await TemporaryIdentifierGenerator.shared.next())")
              try fileManager.createDirectory(
                atPath: outputDirectory.string,
                withIntermediateDirectories: true)
            }

            defer {
              try? FileManager.default.removeItem(atPath: outputDirectory.string)
            }
            let supportHarnessPath = "CVerilatorSupport.cpp"
            try await Process.run(
              executablePath: verilatorExecutablePath,
              arguments: [
                verilatorSharedArguments,
                sourceFiles.map(\.string),
                [supportHarnessPath],
                ["--top-module", topModule.name],
                ["-Mdir", outputDirectory.string],
                waveformDirectory != nil ? ["--trace"] : [],
              ].flatMap { $0 },
              environment: [:],
              workingDirectory: sourceDirectory,
              fileDescriptors: fileDescriptors,
              in: shwiftContext)
            try topModule
              .cppSupportHarnessSource(waveformDirectory: waveformDirectory)
              .write(
                toFile: outputDirectory.appending(supportHarnessPath).string,
                atomically: true,
                encoding: .utf8)
            let makeEnvironment: Environment
            #if os(macOS)
              makeEnvironment = [:]
            #else
              /**
              On Linux, clearing the make environment causes a failure with the following error:
              ```
              g++: fatal error: '-fuse-linker-plugin', but liblto_plugin.so not found
              ```
              We want to keep these things as isolated as possible, but adding "/usr/bin" to the PATH fixes the issue.
              */
              makeEnvironment = ["PATH": "/usr/bin"]
            #endif
            let arguments =
              makeSharedArguments + [
                "-C", outputDirectory.string,
                "-f", "V\(topModule.name).mk",
              ]
            try await Process.run(
              executablePath: makeExecutablePath,
              arguments: arguments,
              environment: makeEnvironment,
              workingDirectory: sourceDirectory,
              fileDescriptors: fileDescriptors,
              in: shwiftContext)
            return try Simulation(
              verilatedModulePath:
                outputDirectory
                .appending(outputLibraryName))
          }
        }
      }
    } catch {
      var recordedOutput = ""
      await recorder.write(to: &recordedOutput)
      struct VerilationError: LocalizedError {
        let recordedOutput: String
        let underlyingError: Error

        var errorDescription: String? {
          """

          \(recordedOutput)
          \(underlyingError)
          """
        }
      }
      throw VerilationError(recordedOutput: recordedOutput, underlyingError: error)
    }
    return simulation
  }

}

// MARK: - Support

extension FilePath {
  fileprivate func string(escapingSpaces: Bool) -> String {
    if escapingSpaces {
      return string.replacingOccurrences(of: " ", with: "\\ ")
    } else {
      return string
    }
  }
}

private actor TemporaryIdentifierGenerator {
  static let shared = TemporaryIdentifierGenerator()

  func next() -> Int {
    defer { count += 1 }
    return count
  }
  private var count = 0
}
