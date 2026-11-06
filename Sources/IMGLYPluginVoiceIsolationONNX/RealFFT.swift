import Accelerate

/// A real FFT with the scaling and layout of numpy's `rfft` and `irfft`, for the sizes vDSP's DFT supports
/// (f * 2^n with f in 1, 3, 5, 15), such as 512 and 960.
final class RealFFT {
  let size: Int
  private let forwardSetup: OpaquePointer
  private let inverseSetup: OpaquePointer

  init?(size: Int) {
    guard let forward = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(size), .FORWARD),
          let inverse = vDSP_DFT_zrop_CreateSetup(forward, vDSP_Length(size), .INVERSE) else {
      return nil
    }
    self.size = size
    forwardSetup = forward
    inverseSetup = inverse
  }

  deinit {
    vDSP_DFT_DestroySetup(forwardSetup)
    vDSP_DFT_DestroySetup(inverseSetup)
  }

  /// `size / 2 + 1` bins, like `numpy.fft.rfft`.
  func forward(_ input: [Float]) -> (real: [Float], imaginary: [Float]) {
    precondition(input.count == size)
    let half = size / 2
    var evens = [Float](repeating: 0, count: half)
    var odds = [Float](repeating: 0, count: half)
    for index in 0 ..< half {
      evens[index] = input[2 * index]
      odds[index] = input[2 * index + 1]
    }
    var outReal = [Float](repeating: 0, count: half)
    var outImaginary = [Float](repeating: 0, count: half)
    vDSP_DFT_Execute(forwardSetup, evens, odds, &outReal, &outImaginary)
    // vDSP packs the Nyquist bin into the imaginary part of bin 0 and scales by 2.
    var real = [Float](repeating: 0, count: half + 1)
    var imaginary = [Float](repeating: 0, count: half + 1)
    real[0] = outReal[0] / 2
    real[half] = outImaginary[0] / 2
    for index in 1 ..< half {
      real[index] = outReal[index] / 2
      imaginary[index] = outImaginary[index] / 2
    }
    return (real, imaginary)
  }

  /// `size` samples from `size / 2 + 1` bins, like `numpy.fft.irfft`.
  func inverse(real: [Float], imaginary: [Float]) -> [Float] {
    let half = size / 2
    precondition(real.count == half + 1 && imaginary.count == half + 1)
    var inReal = [Float](repeating: 0, count: half)
    var inImaginary = [Float](repeating: 0, count: half)
    inReal[0] = real[0]
    inImaginary[0] = real[half]
    for index in 1 ..< half {
      inReal[index] = real[index]
      inImaginary[index] = imaginary[index]
    }
    var evens = [Float](repeating: 0, count: half)
    var odds = [Float](repeating: 0, count: half)
    vDSP_DFT_Execute(inverseSetup, inReal, inImaginary, &evens, &odds)
    var output = [Float](repeating: 0, count: size)
    let scale = 1 / Float(size)
    for index in 0 ..< half {
      output[2 * index] = evens[index] * scale
      output[2 * index + 1] = odds[index] * scale
    }
    return output
  }
}
