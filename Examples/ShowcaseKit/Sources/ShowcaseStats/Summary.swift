import MathUtils

public struct Summary: Sendable, Equatable {
  public init(_ values: [Double]) {
    count = values.count
    mean = Stats.mean(values)
    standardDeviation = Stats.standardDeviation(values)
  }

  public let count: Int
  public let mean: Double
  public let standardDeviation: Double
}
