extension Verilator {

  public struct ModuleDefinition {
    public init(
      name: String,
      readPorts: [Port],
      writePorts: [Port]
    ) {
      self.name = name
      self.readPorts = readPorts
      self.writePorts = writePorts
    }
    public let name: String

    public struct Port {
      public init(_ name: String, bitWidth: Int) {
        self.name = name
        self.bitWidth = bitWidth
      }
      public let name: String
      public let bitWidth: Int
      var byteCount: Int { (bitWidth + 3) / 4 }
    }
    public let readPorts: [Port]
    public let writePorts: [Port]
  }

}
