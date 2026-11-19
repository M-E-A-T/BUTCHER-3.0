// audiorec: record an audio input device to a WAV file without dropouts.
// (ffmpeg's avfoundation audio input keeps a single buffer and loses chunks
// whenever it reads late, which sounded like clicks.)
//
//   audiorec "BlackHole 2ch" out.wav
//
// Stops on SIGINT/SIGTERM. Writes out.wav.start with the capture-clock time
// (seconds) of the first sample: the same clock ffmpeg's avfoundation uses
// for video timestamps, so the two line up exactly.
// Build: swiftc -O audiorec.swift -o audiorec
import AVFoundation
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: audiorec <device name> <out.wav>\n".data(using: .utf8)!)
    exit(2)
}
let deviceName = args[1]
let outURL = URL(fileURLWithPath: args[2])

guard let device = AVCaptureDevice.devices(for: .audio).first(where: { $0.localizedName == deviceName }) else {
    let names = AVCaptureDevice.devices(for: .audio).map { $0.localizedName }.joined(separator: ", ")
    FileHandle.standardError.write("audiorec: no audio device \"\(deviceName)\" (have: \(names))\n".data(using: .utf8)!)
    exit(1)
}

final class Recorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    var file: AVAudioFile?
    var firstPTS: Double?
    var nextPTS: Double = 0
    var frames: Int64 = 0
    var gaps = 0
    let url: URL
    init(url: URL) { self.url = url }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let fd = CMSampleBufferGetFormatDescription(sb) else { return }
        let fmt = AVAudioFormat(cmAudioFormatDescription: fd)
        let n = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb))
        if file == nil {
            do {
                var settings = fmt.settings
                settings[AVFormatIDKey] = kAudioFormatLinearPCM
                file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: fmt.commonFormat, interleaved: fmt.isInterleaved)
            } catch {
                FileHandle.standardError.write("audiorec: can't write \(url.path): \(error)\n".data(using: .utf8)!)
                exit(1)
            }
            firstPTS = pts
            try? String(format: "%.6f\n", pts).write(toFile: url.path + ".start", atomically: true, encoding: .utf8)
        } else if abs(pts - nextPTS) > 0.005 {
            gaps += 1
        }
        nextPTS = pts + Double(n) / fmt.sampleRate
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) else { return }
        buf.frameLength = n
        CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(n), into: buf.mutableAudioBufferList)
        try? file?.write(from: buf)
        frames += Int64(n)
    }
}

let session = AVCaptureSession()
let input = try AVCaptureDeviceInput(device: device)
session.addInput(input)
let output = AVCaptureAudioDataOutput()
let rec = Recorder(url: outURL)
let queue = DispatchQueue(label: "audiorec")
output.setSampleBufferDelegate(rec, queue: queue)
session.addOutput(output)

func finish() {
    session.stopRunning()
    queue.sync {
        let secs = rec.file.map { Double(rec.frames) / $0.processingFormat.sampleRate } ?? 0
        rec.file = nil   // closes the WAV
        print(String(format: "audiorec: %.2f s recorded, %d timing gaps", secs, rec.gaps))
    }
    exit(0)
}
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let sigs = [SIGINT, SIGTERM].map { DispatchSource.makeSignalSource(signal: $0, queue: .main) }
for s in sigs { s.setEventHandler(handler: finish); s.resume() }

session.startRunning()
print("audiorec: recording \"\(deviceName)\" to \(outURL.path)")
dispatchMain()
