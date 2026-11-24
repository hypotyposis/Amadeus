import Foundation
import CoreMedia
import CoreVideo
import CryptoKit
import VideoToolbox

struct WallpaperFailure: LocalizedError {
    let detail: String
    init(_ detail: String) { self.detail = detail }
    var errorDescription: String? { detail }
}

struct VideoMetadata: Decodable {
    struct Layout: Decodable {
        let width: Int
        let height: Int
        let codedWidth: Int
        let codedHeight: Int
    }

    struct Stream: Decodable {
        struct Packet: Decodable {
            let sourceIndex: Int
            let offset: Int
            let size: Int
            let key: Bool
        }
        struct ColorSpace: Decodable {
            let matrix: String
            let fullRange: Bool
        }
        let codec: String
        let videoSha256: String
        let bytes: Int
        let index: [Packet]
        let colorSpace: ColorSpace
    }

    struct Streams: Decodable {
        let color: Stream
        let alpha: Stream
    }

    let schema: String
    let layout: Layout
    let frames: Int
    let frameIntervalMs: Double
    let streams: Streams
}

struct DecodedPair {
    let color: CVPixelBuffer
    let alpha: CVPixelBuffer
}

// The player confines decode and seek mutations to one serial queue.
final class VideoClip: @unchecked Sendable {
    let metadata: VideoMetadata
    private let color: VP9Stream
    private let alpha: VP9Stream
    private var index = -1
    private var current: DecodedPair?

    init(metadataData: Data, colorData: Data, alphaData: Data) throws {
        let metadata = try JSONDecoder().decode(VideoMetadata.self, from: metadataData)
        let layout = metadata.layout
        guard metadata.schema == "amadeus.frame-video-split-experiment.v1",
              (1...8192).contains(layout.codedWidth), (1...8192).contains(layout.codedHeight),
              (1...layout.codedWidth).contains(layout.width), (1...layout.codedHeight).contains(layout.height),
              metadata.frames > 0, metadata.frameIntervalMs > 0,
              metadata.streams.color.index.count == metadata.frames,
              metadata.streams.alpha.index.count == metadata.frames,
              metadata.streams.color.colorSpace.matrix == "bt709",
              metadata.streams.alpha.colorSpace.fullRange else {
            throw WallpaperFailure("Unsupported SpriteForge video layout")
        }
        self.metadata = metadata
        color = try VP9Stream(metadata.streams.color, layout, colorData)
        alpha = try VP9Stream(metadata.streams.alpha, layout, alphaData)
    }

    func frame(at index: Int) throws -> DecodedPair {
        guard (0..<metadata.frames).contains(index) else { throw WallpaperFailure("Video index out of range") }
        if self.index == index, let current { return current }
        let pair = try DecodedPair(color: color.frame(at: index), alpha: alpha.frame(at: index))
        self.index = index
        current = pair
        return pair
    }
}

private final class VP9Stream {
    private let description: VideoMetadata.Stream
    private let data: Data
    private let format: CMVideoFormatDescription
    private var session: VTDecompressionSession?
    private var nextIndex = 0

    init(_ description: VideoMetadata.Stream, _ layout: VideoMetadata.Layout, _ data: Data) throws {
        let codec = description.codec.split(separator: ".")
        guard codec.count == 4, codec[0] == "vp09", codec[1] == "00", codec[3] == "08",
              let level = UInt8(codec[2]), data.count == description.bytes,
              data.starts(with: Data("DKIF".utf8)), description.index.first?.key == true,
              description.index.enumerated().allSatisfy({ offset, packet in
                  packet.sourceIndex == offset && packet.offset >= 44 && packet.offset <= data.count
                      && packet.size > 0 && packet.size <= data.count - packet.offset
              }),
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == description.videoSha256 else {
            throw WallpaperFailure("Invalid or unsupported VP9 stream")
        }
        self.description = description
        self.data = data
        let vpcc = Data([1, 0, 0, 0, 0, level, description.colorSpace.fullRange ? 0x83 : 0x82, 1, 1, 1, 0, 0])
        let extensions = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: ["vpcC": vpcc]]
        var format: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: nil, codecType: kCMVideoCodecType_VP9,
            width: Int32(layout.codedWidth), height: Int32(layout.codedHeight),
            extensions: extensions as CFDictionary, formatDescriptionOut: &format)
        guard status == noErr, let format else { throw WallpaperFailure("VP9 format creation failed (\(status))") }
        self.format = format
    }

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    private func seek(to index: Int) throws {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        nextIndex = description.index[...index].lastIndex(where: \.key) ?? 0
        let pixelFormat = description.colorSpace.fullRange
            ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
        ]
        let status = VTDecompressionSessionCreate(
            allocator: nil, formatDescription: format,
            decoderSpecification: [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary,
            imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
            decompressionSessionOut: &session)
        guard status == noErr, session != nil else { throw WallpaperFailure("VP9 hardware decoder unavailable (\(status))") }
    }

    func frame(at index: Int) throws -> CVPixelBuffer {
        if session == nil || index < nextIndex { try seek(to: index) }
        guard let session else { throw WallpaperFailure("VP9 session unavailable") }
        while nextIndex < index {
            try sample(at: nextIndex, session: session, display: false)
            nextIndex += 1
        }
        let result = try sample(at: index, session: session, display: true)
        nextIndex = index + 1
        guard let result, CVPixelBufferGetPlaneCount(result) == 2 else {
            throw WallpaperFailure("VP9 decoder did not deliver a Metal-compatible frame")
        }
        return result
    }

    @discardableResult
    private func sample(at index: Int, session: VTDecompressionSession, display: Bool) throws -> CVPixelBuffer? {
        let packet = description.index[index]
        var memory: CMBlockBuffer?
        var size = packet.size
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: size, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: size,
            flags: UInt32(kCMBlockBufferAssureMemoryNowFlag), blockBufferOut: &memory)
        guard status == noErr, let memory else { throw WallpaperFailure("Unable to allocate VP9 sample (\(status))") }
        status = data.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress! + packet.offset,
                                          blockBuffer: memory, offsetIntoDestination: 0, dataLength: size)
        }
        guard status == noErr else { throw WallpaperFailure("Unable to copy VP9 sample (\(status))") }
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: memory, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw WallpaperFailure("Unable to create VP9 sample (\(status))") }

        // With neither async nor temporal scheduling enabled, the callback runs
        // synchronously on this serial decode queue.
        var output: CVPixelBuffer?
        var decodeStatus = noErr
        let flags: VTDecodeFrameFlags = display ? [] : [._DoNotOutputFrame]
        status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: flags, infoFlagsOut: nil,
            outputHandler: { error, _, image, _, _ in decodeStatus = error; output = image })
        guard status == noErr, decodeStatus == noErr else {
            throw WallpaperFailure("VP9 decode failed (\(status), \(decodeStatus))")
        }
        return output
    }
}
