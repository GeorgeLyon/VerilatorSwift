import XCTest
import SystemPackage
@testable import Verilator

final class VerilatorTests: XCTestCase {
  func testGCD() async throws {
    let bitWidth = 3
    let verilator: Verilator = .shared
    let portDefinitions = (
      a: Verilator.ModuleDefinition.Port("a", bitWidth: bitWidth),
      b: Verilator.ModuleDefinition.Port("b", bitWidth: bitWidth),
      clock: Verilator.ModuleDefinition.Port("clock", bitWidth: 1),
      loadValues: Verilator.ModuleDefinition.Port("loadValues", bitWidth: 1),
      result: Verilator.ModuleDefinition.Port("result", bitWidth: bitWidth),
      isValid: Verilator.ModuleDefinition.Port("isValid", bitWidth: 1)
    )
    let topModule = Verilator.ModuleDefinition(
      name: "GCD",
      readPorts: [
        portDefinitions.a,
        portDefinitions.b,
        portDefinitions.clock,
        portDefinitions.loadValues,
      ],
      writePorts: [
        portDefinitions.result,
        portDefinitions.isValid,
      ])
    let source = Bundle.module.url(
      forResource: "GCD", 
      withExtension: "sv")!
    let basedir = source.deletingLastPathComponent().path
    let simulation =
      try await verilator
      .verilate(
        topModule: topModule,
        sourceFiles: [.init(source.lastPathComponent)],
        in: .init(basedir),
        waveformDirectory: .init(basedir))
    defer { try! simulation.terminate() }

    let ports = try (
      a: simulation.writePort(for: portDefinitions.a),
      b: simulation.writePort(for: portDefinitions.b),
      clock: simulation.writePort(for: portDefinitions.clock),
      loadValues: simulation.writePort(for: portDefinitions.loadValues),
      result: simulation.readPort(for: portDefinitions.result),
      isValid: simulation.readPort(for: portDefinitions.isValid)
    )

    func tick() throws {
      ports.clock.write(0)
      simulation.evaluate()
      try simulation.stepTrace()
      ports.clock.write(1)
      simulation.evaluate()
      try simulation.stepTrace()
    }

    func testGCD(_ a: Int, _ b: Int, equals expectedResult: Int) throws {
      ports.a.write(a)
      ports.b.write(b)
      ports.loadValues.write(1)
      try tick()
      XCTAssertEqual(ports.result.read(), a)
      XCTAssertEqual(ports.isValid.read(), 0)

      ports.loadValues.write(0)

      while ports.isValid.read() == 0 {
        try tick()
      }

      XCTAssertEqual(ports.result.read(), expectedResult)
    }

    try testGCD(15, 10, equals: 5)
    try testGCD(10, 15, equals: 5)
    try testGCD(4, 4, equals: 4)
    try testGCD(3, 1, equals: 1)
  
  }
}

// MARK: - Infrastructure 

private extension Verilator {
  static let shared: Verilator = {
    let platform: FilePath.Component
    #if os(macOS)
      platform = "macos"
    #elseif os(Linux)
      platform = "linux"
    #endif
    let configuration: Verilator.Configuration = .inferFromProcessEnvironment
    return Verilator(configuration: configuration)
  }()
}
