public enum Stats {
  public static func mean(_ values: [Double]) -> Double {
    values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
  }

  /// Population standard deviation.
  public static func standardDeviation(_ values: [Double]) -> Double {
    let average = mean(values)
    let variance = mean(values.map { ($0 - average) * ($0 - average) })
    return variance.squareRoot()
  }
}
