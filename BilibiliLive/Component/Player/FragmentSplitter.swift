//
//  FragmentSplitter.swift
//  BilibiliLive
//
//  「小块播放」：B 站的视频按 5 秒一段（一个 moof + mdat）。系统播放器每段都要整段下完才能用，
//  4K 一段 7～20 MB，起播和跳转都要等。这里把一段按样本切成几小块：每块重写一个只描述自己那几帧的
//  moof（tfdt 接上时间线、trun 列出这几帧），后面跟这几帧原样的数据。画面数据一个字节都不改。
//  除了每段第一块（从关键帧开始），其余小块不能单独解码，播放列表里不声明 INDEPENDENT-SEGMENTS。
//

import Foundation

struct FragmentIndex {
    struct Sample {
        /// 相对这一段开头的字节位置。
        let offset: Int
        let size: Int
        let duration: UInt32
        let flags: UInt32
        let compositionOffset: Int32
    }

    let trackID: UInt32
    let sampleDescriptionIndex: UInt32?
    let baseDecodeTime: UInt64
    let samples: [Sample]
    let hasCompositionOffsets: Bool
    let signedCompositionOffsets: Bool

    enum ParseResult {
        case index(FragmentIndex)
        /// moof 还没读全：需要这一段开头的这么多字节。
        case needBytes(Int)
        case failure(String)
    }

    /// 解析一段开头的字节（可能有 styp 等盒子在 moof 前面）。
    static func parse(_ data: Data, fragmentDuration: Int, fragmentSize: Int) -> ParseResult {
        let bytes = [UInt8](data)
        var cursor = 0
        while cursor + 8 <= bytes.count {
            let size = Int(be32(bytes, cursor))
            let type = fourCC(bytes, cursor + 4)
            guard size >= 8 else { return .failure("bad box size at \(cursor)") }
            if type == "moof" {
                guard cursor + size <= bytes.count else { return .needBytes(cursor + size + 16) }
                return parseMoof(bytes, start: cursor, size: size, fragmentDuration: fragmentDuration, fragmentSize: fragmentSize)
            }
            cursor += size
        }
        return .needBytes(min(fragmentSize, max(bytes.count * 2, 64 * 1024)))
    }

    private static func parseMoof(_ b: [UInt8], start: Int, size: Int, fragmentDuration: Int, fragmentSize: Int) -> ParseResult {
        let end = start + size
        var cursor = start + 8
        var traf: (Int, Int)?
        var trafCount = 0
        while cursor + 8 <= end {
            let boxSize = Int(be32(b, cursor))
            guard boxSize >= 8 else { return .failure("bad moof child") }
            if fourCC(b, cursor + 4) == "traf" {
                traf = (cursor, boxSize)
                trafCount += 1
            }
            cursor += boxSize
        }
        guard let (trafStart, trafSize) = traf, trafCount == 1 else { return .failure("traf count \(trafCount)") }

        var trackID: UInt32 = 0
        var baseDataOffset: Int?
        var sdi: UInt32?
        var defaultDuration: UInt32?
        var defaultSize: UInt32?
        var defaultFlags: UInt32?
        var baseDecodeTime: UInt64 = 0
        var runs: [(dataOffset: Int?, firstFlags: UInt32?, entries: [(UInt32?, UInt32?, UInt32?, Int32?)], version: UInt8)] = []

        cursor = trafStart + 8
        let trafEnd = trafStart + trafSize
        while cursor + 8 <= trafEnd {
            let boxSize = Int(be32(b, cursor))
            guard boxSize >= 8, cursor + boxSize <= trafEnd else { return .failure("bad traf child") }
            let type = fourCC(b, cursor + 4)
            let version = b[cursor + 8]
            let flags = be32(b, cursor + 8) & 0x00FF_FFFF
            var p = cursor + 12
            switch type {
            case "tfhd":
                trackID = be32(b, p); p += 4
                if flags & 0x1 != 0 { baseDataOffset = Int(be64(b, p)); p += 8 }
                if flags & 0x2 != 0 { sdi = be32(b, p); p += 4 }
                if flags & 0x8 != 0 { defaultDuration = be32(b, p); p += 4 }
                if flags & 0x10 != 0 { defaultSize = be32(b, p); p += 4 }
                if flags & 0x20 != 0 { defaultFlags = be32(b, p); p += 4 }
            case "tfdt":
                baseDecodeTime = version == 1 ? be64(b, p) : UInt64(be32(b, p))
            case "trun":
                let count = Int(be32(b, p)); p += 4
                var dataOffset: Int?
                var firstFlags: UInt32?
                if flags & 0x1 != 0 { dataOffset = Int(Int32(bitPattern: be32(b, p))); p += 4 }
                if flags & 0x4 != 0 { firstFlags = be32(b, p); p += 4 }
                var entries = [(UInt32?, UInt32?, UInt32?, Int32?)]()
                entries.reserveCapacity(count)
                for _ in 0..<count {
                    var d: UInt32?, s: UInt32?, f: UInt32?, c: Int32?
                    if flags & 0x100 != 0 { d = be32(b, p); p += 4 }
                    if flags & 0x200 != 0 { s = be32(b, p); p += 4 }
                    if flags & 0x400 != 0 { f = be32(b, p); p += 4 }
                    if flags & 0x800 != 0 { c = Int32(bitPattern: be32(b, p)); p += 4 }
                    guard p <= cursor + boxSize else { return .failure("trun overflow") }
                    entries.append((d, s, f, c))
                }
                runs.append((dataOffset, firstFlags, entries, version))
            default:
                break
            }
            cursor += boxSize
        }
        guard !runs.isEmpty else { return .failure("no trun") }

        // 数据位置以 moof 开头为基准（tfhd 用绝对文件位置的写法不支持，调用方会退回整段播放）。
        guard baseDataOffset == nil else { return .failure("absolute base data offset") }
        let base = start
        let totalCount = runs.reduce(0) { $0 + $1.entries.count }
        let fallbackDuration = UInt32(max(1, fragmentDuration / max(1, totalCount)))
        var samples = [Sample]()
        samples.reserveCapacity(totalCount)
        var hasCTO = false
        var signedCTO = false
        var nextOffset = start + size + 8 // 没写 data_offset 时紧跟在 moof 后面的 mdat 头之后
        for run in runs {
            var offset = run.dataOffset.map { base + $0 } ?? nextOffset
            for (index, entry) in run.entries.enumerated() {
                guard let size = entry.1 ?? defaultSize else { return .failure("no sample size") }
                let flags = entry.2 ?? (index == 0 ? run.firstFlags : nil) ?? defaultFlags
                    ?? (samples.isEmpty ? 0x0200_0000 : 0x0101_0000)
                if let c = entry.3 {
                    hasCTO = true
                    if run.version == 1 { signedCTO = true }
                    _ = c
                }
                samples.append(Sample(offset: offset, size: Int(size), duration: entry.0 ?? defaultDuration ?? fallbackDuration,
                                      flags: flags, compositionOffset: entry.3 ?? 0))
                offset += Int(size)
            }
            nextOffset = offset
        }
        guard let last = samples.last, last.offset + last.size <= fragmentSize else { return .failure("samples beyond fragment") }
        return .index(FragmentIndex(trackID: trackID, sampleDescriptionIndex: sdi, baseDecodeTime: baseDecodeTime, samples: samples,
                                    hasCompositionOffsets: hasCTO, signedCompositionOffsets: signedCTO))
    }

    /// 第 part 块（共 parts 块）包含的样本（按个数平均分，保证每块都有样本）。
    func sampleRange(part: Int, of parts: Int) -> Range<Int> {
        let n = samples.count
        let k = max(1, min(parts, n))
        let p = min(part, k - 1)
        return (p * n / k)..<((p + 1) * n / k)
    }

    /// 这一块的数据在这一段里的字节范围（含头不含尾）。
    func byteRange(of range: Range<Int>) -> Range<Int> {
        samples[range.lowerBound].offset..<(samples[range.upperBound - 1].offset + samples[range.upperBound - 1].size)
    }

    /// 生成一小块：新的 moof + mdat（sampleData 是这几帧原样的数据，按 byteRange 取出）。
    func buildPart(_ range: Range<Int>, sampleData: Data, sequence: UInt32) -> Data {
        let chosen = Array(samples[range])
        let decodeTime = baseDecodeTime + samples[..<range.lowerBound].reduce(UInt64(0)) { $0 + UInt64($1.duration) }

        var trunFlags: UInt32 = 0x1 | 0x100 | 0x200 | 0x400
        if hasCompositionOffsets { trunFlags |= 0x800 }
        let trunVersion: UInt8 = signedCompositionOffsets ? 1 : 0
        var trun = Data()
        trun.appendFull(version: trunVersion, flags: trunFlags)
        trun.append32(UInt32(chosen.count))
        let dataOffsetPosition = trun.count
        trun.append32(0) // 稍后填
        for sample in chosen {
            trun.append32(sample.duration)
            trun.append32(UInt32(sample.size))
            trun.append32(sample.flags)
            if hasCompositionOffsets { trun.append32(UInt32(bitPattern: sample.compositionOffset)) }
        }

        var tfhd = Data()
        tfhd.appendFull(version: 0, flags: 0x020000 | (sampleDescriptionIndex != nil ? 0x2 : 0))
        tfhd.append32(trackID)
        if let sampleDescriptionIndex { tfhd.append32(sampleDescriptionIndex) }

        var tfdt = Data()
        tfdt.appendFull(version: 1, flags: 0)
        tfdt.append64(decodeTime)

        var mfhd = Data()
        mfhd.appendFull(version: 0, flags: 0)
        mfhd.append32(sequence)

        let trunBox = Data.box("trun", trun)
        let traf = Data.box("traf", Data.box("tfhd", tfhd) + Data.box("tfdt", tfdt) + trunBox)
        var moof = Data.box("moof", Data.box("mfhd", mfhd) + traf)
        // data_offset：从 moof 开头到这几帧数据的第一个字节 = moof 长度 + mdat 头 8 字节。
        let trunStartInMoof = moof.count - trunBox.count
        let offsetPosition = trunStartInMoof + 8 + dataOffsetPosition
        let dataOffset = UInt32(moof.count + 8)
        moof.replaceSubrange(offsetPosition..<offsetPosition + 4, with: dataOffset.bigEndianBytes)

        var mdatHeader = Data()
        mdatHeader.append32(UInt32(8 + sampleData.count))
        mdatHeader.append("mdat".data(using: .ascii)!)
        return moof + mdatHeader + sampleData
    }

    private static func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
        guard i + 4 <= b.count else { return 0 }
        return UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }

    private static func be64(_ b: [UInt8], _ i: Int) -> UInt64 {
        UInt64(be32(b, i)) << 32 | UInt64(be32(b, i + 4))
    }

    private static func fourCC(_ b: [UInt8], _ i: Int) -> String {
        guard i + 4 <= b.count else { return "" }
        return String(bytes: b[i..<i + 4], encoding: .ascii) ?? ""
    }
}

private extension UInt32 {
    var bigEndianBytes: Data {
        var value = bigEndian
        return Data(bytes: &value, count: 4)
    }
}

private extension Data {
    mutating func append32(_ value: UInt32) { append(value.bigEndianBytes) }

    mutating func append64(_ value: UInt64) {
        append32(UInt32(value >> 32))
        append32(UInt32(value & 0xFFFF_FFFF))
    }

    mutating func appendFull(version: UInt8, flags: UInt32) {
        append32(UInt32(version) << 24 | (flags & 0x00FF_FFFF))
    }

    static func box(_ type: String, _ payload: Data) -> Data {
        var data = Data()
        data.append32(UInt32(8 + payload.count))
        data.append(type.data(using: .ascii)!)
        data.append(payload)
        return data
    }
}
