import Foundation
import SystemPackage

extension Verilator {

  public struct Simulation {

    public struct ReadPort {
      public func read() -> Int {
        getter()
      }
      fileprivate let portDefinition: Verilator.ModuleDefinition.Port
      fileprivate let getter: () -> Int
    }

    public struct WritePort {
      public func write(_ value: Int) {
        setter(value)
      }
      fileprivate let portDefinition: Verilator.ModuleDefinition.Port
      fileprivate let setter: (Int) -> Void
    }

    private var verilatedModule: OpaquePointer!
    private var evaluateFunctionPointer: (@convention(c) (OpaquePointer) -> Void)!
    private var stepTraceFunctionPointer: Result<(@convention(c) (OpaquePointer) -> Void), Error>!
    private let dsoHandle: UnsafeMutableRawPointer
  }

}

extension Verilator.ModuleDefinition {

  func cppSupportHarnessSource(waveformDirectory: FilePath?) -> String {
    let className = "V\(self.name)"
    let moduleName = "\(className)Module"
    let waveformPath = waveformDirectory?.appending("\(name).vcd") ?? "/dev/null"
    return """
      #include <assert.h>
      #include <string>
      #include <\(className).h>

      #if VM_TRACE
      #include "verilated_vcd_c.h"
      #endif

      #define EXPORT  __attribute__((visibility("default")))

      extern "C" {

      struct \(moduleName) {
        \(className) instance;
        #if VM_TRACE
          VerilatedVcdC *vcd;
          vluint64_t timeStamp;
        #endif
      };

      /// Module
      EXPORT \(moduleName) *\(createSymbolName)() {
        auto module = new \(moduleName)();

        #if VM_TRACE
          // Safe to call multiple times
          Verilated::traceEverOn(true);
          module->vcd = new VerilatedVcdC();
          // Associate the tracer with the module, tracing up to 99 levels of hierarchy
          module->instance.trace(module->vcd, 99);
          module->vcd->open("\(waveformPath)");
        #endif

        return module;
      }
      EXPORT void \(destroySymbolName)(\(moduleName) *module) {
        #if VM_TRACE
          delete module->vcd;
        #endif

        delete module;
      }
      EXPORT void \(evaluateSymbolName)(\(moduleName) *module) {
        module->instance.eval();
      }

      #if VM_TRACE
        EXPORT void \(stepTraceSymbolName)(\(moduleName) *module) {
          ++module->timeStamp;
          module->vcd->dump(module->timeStamp);
        }
      #endif

      /// Input Ports
      \(readPorts.map { input in
          """
          EXPORT void \(setterName(for: input.name))(\(moduleName) *module, unsigned char *value, size_t size) {
            assert(size == \(input.byteCount));
            decltype(&module->instance.\(input.name)) typedRef = value;
            module->instance.\(input.name) = *typedRef;
          }
          """ 
        }.joined(separator: "\n\n"))

      // Output Ports
      \(writePorts.map { output in
          """
          EXPORT void \(getterName(for: output.name))(\(moduleName) *module, unsigned char *out_value, size_t size) {
            assert(size == \(output.byteCount));
            decltype(&module->instance.\(output.name)) typedRef = out_value;
            *typedRef = module->instance.\(output.name);
          }
          """ 
        }.joined(separator: "\n\n"))

      } // extern "C"

      """
  }

}

extension Verilator.Simulation {

  public func readPort(for portDefinition: Verilator.ModuleDefinition.Port) throws -> ReadPort {
    let getter = try resolveSymbol(
      getterName(for: portDefinition.name),
      as: (@convention(c) (OpaquePointer, UnsafeMutableRawPointer, Int) -> Void).self)
    return ReadPort(portDefinition: portDefinition) {
      var value: Int = .zero
      withUnsafeMutableBytes(of: &value) { buffer in
        precondition(buffer.count >= portDefinition.byteCount)
        getter(verilatedModule, buffer.baseAddress!, portDefinition.byteCount)
      }
      return value
    }
  }

  public func writePort(for portDefinition: Verilator.ModuleDefinition.Port) throws -> WritePort {
    let setter = try resolveSymbol(
      setterName(for: portDefinition.name),
      as: (@convention(c) (OpaquePointer, UnsafeMutableRawPointer, Int) -> Void).self)
    return WritePort(portDefinition: portDefinition) { value in
      var mutableValue = value
      withUnsafeMutableBytes(of: &mutableValue) { buffer in
        precondition(buffer.count >= portDefinition.byteCount)
        setter(verilatedModule, buffer.baseAddress!, portDefinition.byteCount)
      }
    }
  }

  public func evaluate() {
    evaluateFunctionPointer(verilatedModule)
  }

  /// Increments the timestep and dumps the module trace into a waveform file if one has been configured.
  /// - throws: if the simulation has not been configured for waveform generation
  public func stepTrace() throws {
    try stepTraceFunctionPointer.get()(verilatedModule)
  }

  public func terminate() throws {
    let destroy = try resolveSymbol(
      destroySymbolName,
      as: (@convention(c) (OpaquePointer) -> Void).self)
    destroy(verilatedModule)
    guard dlclose(dsoHandle) == 0 else {
      // TODO: Throw dlerror
      fatalError()
    }
  }

  init(verilatedModulePath: FilePath) throws {
    guard
      let dsoHandle =
        verilatedModulePath
        .withCString({ dlopen($0, RTLD_NOW | RTLD_LOCAL) })
    else {
      // TODO: Throw dlerror
      fatalError()
    }
    self.dsoHandle = dsoHandle

    verilatedModule = try resolveSymbol(
      createSymbolName,
      as: (@convention(c) () -> OpaquePointer?).self)()!

    evaluateFunctionPointer = try resolveSymbol(
      evaluateSymbolName,
      as: (@convention(c) (OpaquePointer) -> Void).self)

    // The step trace symbol is optional depending wether the simulation has
    // been configured for waveform generation
    stepTraceFunctionPointer = Result {
      try resolveSymbol(stepTraceSymbolName, as: (@convention(c) (OpaquePointer) -> Void).self)
    }
  }

  public struct UnresolvedSymbolError: Error {
    public let symbol: String
  }

  private func resolveSymbol<T>(_ name: String, as type: T.Type) throws -> T {
    let symbol = name.withCString {
      dlsym(dsoHandle, $0)
    }
    guard let symbol = symbol else {
      throw UnresolvedSymbolError(symbol: name)
    }
    return unsafeBitCast(symbol, to: type)
  }

}

// MARK: - Support

private let createSymbolName: String = "VerilatedModuleCreate"
private let destroySymbolName: String = "VerilatedModuleDestroy"
private let evaluateSymbolName: String = "VerilatedModuleEvaluate"
private let stepTraceSymbolName: String = "VerilatedModulateStepTrace"
private func setterName(for portName: String) -> String {
  "set_\(portName)"
}
private func getterName(for portName: String) -> String {
  "get_\(portName)"
}
