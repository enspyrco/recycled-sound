// Apple Vision OCR baseline — mirrors the iOS app's VisionOcrPlugin config.
// Loads via CGImageSource so EXIF orientation is honored (phone photos are rotated).
// Usage: vision_ocr <image1> [image2 ...]
import Foundation
import Vision
import ImageIO
import CoreGraphics

let brandWords = ["ReSound","Oticon","Phonak","Unitron","Signia","Widex","Beltone",
                  "GN","Starkey","Bernafon","Hansaton","Rexton","Sonic","Audeo","Nera","Moxi"]

func loadCG(_ path: String) -> (CGImage, CGImagePropertyOrientation)? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    var orient: CGImagePropertyOrientation = .up
    if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
       let o = props[kCGImagePropertyOrientation] as? UInt32,
       let oo = CGImagePropertyOrientation(rawValue: o) {
        orient = oo
    }
    return (cg, orient)
}

func ocr(_ cg: CGImage, _ orient: CGImagePropertyOrientation, accurate: Bool) -> ([(String, Float)], String) {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = accurate ? .accurate : .fast
    req.usesLanguageCorrection = false
    req.minimumTextHeight = 0.01
    req.customWords = brandWords
    let handler = VNImageRequestHandler(cgImage: cg, orientation: orient, options: [:])
    var err = "ok"
    do { try handler.perform([req]) } catch { err = "\(error)" }
    var out: [(String, Float)] = []
    for obs in (req.results ?? []) {
        if let top = obs.topCandidates(1).first { out.append((top.string, top.confidence)) }
    }
    return (out, err)
}

for path in Array(CommandLine.arguments.dropFirst()) {
    let name = (path as NSString).lastPathComponent
    guard let (cg, orient) = loadCG(path) else { print("\(name): LOAD FAILED"); continue }
    print("\(name)  \(cg.width)x\(cg.height)  exif-orient=\(orient.rawValue)")
    for accurate in [false, true] {
        let (toks, err) = ocr(cg, orient, accurate: accurate)
        let hits = toks.filter { t in brandWords.contains { t.0.lowercased().contains($0.lowercased()) } }
        let hitStr = hits.map { "\($0.0)[\(String(format: "%.2f", $0.1))]" }.joined(separator: ", ")
        print("  \(accurate ? "accurate" : "fast    ")  err=\(err)  toks=\(toks.count)  BRAND: \(hits.isEmpty ? "—" : hitStr)")
    }
    let (all, _) = ocr(cg, orient, accurate: true)
    print("    all: \(all.map { $0.0 }.joined(separator: " | "))")
}
