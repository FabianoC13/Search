@_exported import Foundation

// SHA-1, for the WebSocket handshake.
public enum Insecure {
    public enum SHA1 {
        public static func hash(data: Data) -> [UInt8] {
            var h: [UInt32] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
            var bytes = [UInt8](data)
            let bits = UInt64(bytes.count) * 8
            bytes.append(0x80)
            while bytes.count % 64 != 56 { bytes.append(0) }
            for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8((bits >> UInt64(shift)) & 0xFF)) }
            func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }
            for chunk in stride(from: 0, to: bytes.count, by: 64) {
                var w = [UInt32](repeating: 0, count: 80)
                for i in 0..<16 {
                    w[i] = bytes[chunk + i * 4 ..< chunk + i * 4 + 4].reduce(0) { $0 << 8 | UInt32($1) }
                }
                for i in 16..<80 { w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1) }
                var (a, b, c, d, e) = (h[0], h[1], h[2], h[3], h[4])
                for i in 0..<80 {
                    let (f, k): (UInt32, UInt32)
                    switch i {
                    case 0..<20: (f, k) = ((b & c) | (~b & d), 0x5A827999)
                    case 20..<40: (f, k) = (b ^ c ^ d, 0x6ED9EBA1)
                    case 40..<60: (f, k) = ((b & c) | (b & d) | (c & d), 0x8F1BBCDC)
                    default: (f, k) = (b ^ c ^ d, 0xCA62C1D6)
                    }
                    let t = rotl(a, 5) &+ f &+ e &+ k &+ w[i]
                    (e, d, c, b, a) = (d, c, rotl(b, 30), a, t)
                }
                h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d; h[4] = h[4] &+ e
            }
            return h.flatMap { v in [24, 16, 8, 0].map { UInt8((v >> UInt32($0)) & 0xFF) } }
        }
    }
}
