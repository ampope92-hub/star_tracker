// Star tracker attitude from the camera head's frame stream. Reference solution.
//
// Reads every frame of the pass from the camera head (CAMERA_HOST, CAMERA_PORT), resuming after
// each link drop, and the star catalogue at STAR_CATALOG. Then:
//   1. spots that sit on the same pixel in a large share of frames, before and after a slew, are
//      the detector's hot pixels;
//   2. a lost-in-space solve (triangles of bright spots against a sorted pair-angle index of the
//      brightest catalogue stars, each hypothesis verified against the whole field) starts every
//      tracking arc; tracking carries the attitude from frame to frame and falls back to a
//      lost-in-space solve after a slew or an eclipse;
//   3. the unit's focal length and radial distortion are fitted to every matched star, jointly
//      with the attitudes, and the pass is solved again with the fitted optics;
//   4. every catalogue direction is aberrated by the frame's velocity before it is compared with
//      what the camera saw, so the attitude reported is the geometric one.
// Prints one line per frame received: counter w x y z.
import Glibc

// ---------------------------------------------------------------- small vector algebra
struct V3 {
    var x: Double, y: Double, z: Double
    init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }
    static func + (a: V3, b: V3) -> V3 { V3(a.x + b.x, a.y + b.y, a.z + b.z) }
    static func - (a: V3, b: V3) -> V3 { V3(a.x - b.x, a.y - b.y, a.z - b.z) }
    static func * (s: Double, a: V3) -> V3 { V3(s * a.x, s * a.y, s * a.z) }
    func dot(_ b: V3) -> Double { x * b.x + y * b.y + z * b.z }
    func cross(_ b: V3) -> V3 { V3(y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x) }
    var norm: Double { (x * x + y * y + z * z).squareRoot() }
    var unit: V3 { let n = norm; return V3(x / n, y / n, z / n) }
}

// Attitude matrix: rows r0, r1, r2; v_cam = A v_icrs.
struct M3 {
    var r0: V3, r1: V3, r2: V3
    func apply(_ v: V3) -> V3 { V3(r0.dot(v), r1.dot(v), r2.dot(v)) }
    var transposed: M3 {
        M3(r0: V3(r0.x, r1.x, r2.x), r1: V3(r0.y, r1.y, r2.y), r2: V3(r0.z, r1.z, r2.z))
    }
    static func * (a: M3, b: M3) -> M3 {
        let bt = b.transposed
        return M3(r0: V3(a.r0.dot(bt.r0), a.r0.dot(bt.r1), a.r0.dot(bt.r2)),
                  r1: V3(a.r1.dot(bt.r0), a.r1.dot(bt.r1), a.r1.dot(bt.r2)),
                  r2: V3(a.r2.dot(bt.r0), a.r2.dot(bt.r1), a.r2.dot(bt.r2)))
    }
}

func matFromQ(_ q: [Double]) -> M3 {   // q = (w, x, y, z)
    let w = q[0], x = q[1], y = q[2], z = q[3]
    return M3(r0: V3(w * w + x * x - y * y - z * z, 2 * (x * y + w * z), 2 * (x * z - w * y)),
              r1: V3(2 * (x * y - w * z), w * w - x * x + y * y - z * z, 2 * (y * z + w * x)),
              r2: V3(2 * (x * z + w * y), 2 * (y * z - w * x), w * w - x * x - y * y + z * z))
}

func qFromMat(_ a: M3) -> [Double] {
    let m = [[a.r0.x, a.r0.y, a.r0.z], [a.r1.x, a.r1.y, a.r1.z], [a.r2.x, a.r2.y, a.r2.z]]
    let tr = m[0][0] + m[1][1] + m[2][2]
    let c: [(Double, [Double])] = [
        (1 + tr, [1 + tr, m[1][2] - m[2][1], m[2][0] - m[0][2], m[0][1] - m[1][0]]),
        (1 + 2 * m[0][0] - tr, [m[1][2] - m[2][1], 1 + 2 * m[0][0] - tr, m[0][1] + m[1][0], m[0][2] + m[2][0]]),
        (1 + 2 * m[1][1] - tr, [m[2][0] - m[0][2], m[0][1] + m[1][0], 1 + 2 * m[1][1] - tr, m[1][2] + m[2][1]]),
        (1 + 2 * m[2][2] - tr, [m[0][1] - m[1][0], m[0][2] + m[2][0], m[1][2] + m[2][1], 1 + 2 * m[2][2] - tr]),
    ]
    var best = c[0]
    for e in c where e.0 > best.0 { best = e }
    var q = best.1
    let n = (q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]).squareRoot()
    for i in 0..<4 { q[i] /= n }
    if q[0] < 0 { for i in 0..<4 { q[i] = -q[i] } }
    return q
}

// Davenport's q-method: the rotation A maximising sum w b.(A r) over pairs (b observed in the
// camera, r reference in ICRS). Largest eigenvector of the 4x4 K matrix by Jacobi rotations.
func solveAttitude(_ obs: [V3], _ ref: [V3], _ wts: [Double]? = nil) -> M3 {
    var b = [[Double]](repeating: [0, 0, 0], count: 3)
    for i in 0..<obs.count {
        let o = obs[i], r = ref[i]
        let w = wts?[i] ?? 1
        let ov = [o.x, o.y, o.z], rv = [r.x, r.y, r.z]
        for p in 0..<3 { for q in 0..<3 { b[p][q] += w * ov[p] * rv[q] } }
    }
    let sigma = b[0][0] + b[1][1] + b[2][2]
    let z = [b[1][2] - b[2][1], b[2][0] - b[0][2], b[0][1] - b[1][0]]
    var k = [[Double]](repeating: [0, 0, 0, 0], count: 4)
    for p in 0..<3 { for q in 0..<3 { k[p][q] = b[p][q] + b[q][p] - (p == q ? sigma : 0) } }
    for p in 0..<3 { k[p][3] = z[p]; k[3][p] = z[p] }
    k[3][3] = sigma
    var v = [[Double]](repeating: [0, 0, 0, 0], count: 4)
    for i in 0..<4 { v[i][i] = 1 }
    for _ in 0..<60 {
        var off = 0.0
        for p in 0..<4 { for q in (p + 1)..<4 { off += k[p][q] * k[p][q] } }
        if off < 1e-30 { break }
        for p in 0..<4 {
            for q in (p + 1)..<4 {
                if abs(k[p][q]) < 1e-300 { continue }
                let theta = (k[q][q] - k[p][p]) / (2 * k[p][q])
                let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
                let c = 1 / (t * t + 1).squareRoot(), s = t * c
                for r in 0..<4 {
                    let kp = k[r][p], kq = k[r][q]
                    k[r][p] = c * kp - s * kq; k[r][q] = s * kp + c * kq
                }
                for r in 0..<4 {
                    let kp = k[p][r], kq = k[q][r]
                    k[p][r] = c * kp - s * kq; k[q][r] = s * kp + c * kq
                }
                for r in 0..<4 {
                    let vp = v[r][p], vq = v[r][q]
                    v[r][p] = c * vp - s * vq; v[r][q] = s * vp + c * vq
                }
            }
        }
    }
    var best = 0
    for i in 1..<4 where k[i][i] > k[best][best] { best = i }
    // eigenvector (q1, q2, q3, q4) with q4 the scalar part
    return matFromQ([v[3][best], v[0][best], v[1][best], v[2][best]])
}

// ---------------------------------------------------------------- aberration
let cKmS = 299792.458
func aberrate(_ u: V3, _ beta: V3) -> V3 {
    let b2 = beta.dot(beta)
    let g = 1 / (1 - b2).squareRoot()
    let ub = u.dot(beta)
    let f = g * g / (1 + g)
    let num = u + (g + f * ub) * beta
    return ((1 / (g * (1 + ub))) * num).unit
}

// ---------------------------------------------------------------- optics
// Detector side and centre, from the camera head's greeting.
var size = 1024.0
var cx = 511.5, cy = 511.5
struct Optics { var f: Double; var k: Double }

func toVector(_ x: Double, _ y: Double, _ o: Optics) -> V3 {
    let a = (x - cx) / o.f, b = (y - cy) / o.f
    let rd = (a * a + b * b).squareRoot()
    var r = rd
    if rd > 0 && o.k != 0 {
        for _ in 0..<6 { r -= (r * (1 + o.k * r * r) - rd) / (1 + 3 * o.k * r * r) }
    }
    let s = rd > 0 ? r / rd : 1
    return V3(a * s, b * s, 1).unit
}

func toPixel(_ c: V3, _ o: Optics) -> (Double, Double)? {
    if c.z <= 0 { return nil }
    let u = c.x / c.z, v = c.y / c.z
    let s = o.f * (1 + o.k * (u * u + v * v))
    return (cx + s * u, cy + s * v)
}

// ---------------------------------------------------------------- input
func fail(_ msg: String) -> Never {
    fputs("tracker: \(msg)\n", stderr)
    exit(1)
}

func env(_ k: String) -> String? {
    guard let p = getenv(k) else { return nil }
    return String(cString: p)
}

final class Link {
    let fd: Int32
    var buf = [UInt8](repeating: 0, count: 1 << 16)
    var start = 0, end = 0
    init(fd: Int32) { self.fd = fd }
    deinit { close(fd) }

    func readLine() -> String? {
        var line = [UInt8]()
        while true {
            if start == end {
                let n = buf.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
                if n <= 0 { return line.isEmpty ? nil : String(decoding: line, as: UTF8.self) }
                start = 0; end = n
            }
            var i = start
            while i < end && buf[i] != 10 { i += 1 }
            line.append(contentsOf: buf[start..<i])
            if i < end {
                start = i + 1
                if let last = line.last, last == 13 { line.removeLast() }
                return String(decoding: line, as: UTF8.self)
            }
            start = end
        }
    }

    func send(_ s: String) -> Bool {
        var bytes = Array(s.utf8)
        var off = 0
        while off < bytes.count {
            let n = bytes.withUnsafeMutableBytes { Glibc.send(fd, $0.baseAddress! + off, $0.count - off, Int32(MSG_NOSIGNAL)) }
            if n <= 0 { return false }
            off += n
        }
        return true
    }
}

func dial(_ host: String, _ port: String) -> Link? {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC   // a name or an address, IPv4 or IPv6: try every address returned
    hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
    var res: UnsafeMutablePointer<addrinfo>? = nil
    guard getaddrinfo(host, port, &hints, &res) == 0, let first = res else { return nil }
    defer { freeaddrinfo(res) }
    var p: UnsafeMutablePointer<addrinfo>? = first
    while let ai = p {
        let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
        if fd >= 0 {
            if connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 { return Link(fd: fd) }
            close(fd)
        }
        p = ai.pointee.ai_next
    }
    return nil
}

struct Spot { var x: Double; var y: Double; var c: Double; var hot = false }
struct Frame {
    var counter: Int
    var exposure: Double
    var vel: V3
    var spots: [Spot]
}

func fields(_ s: String) -> [Substring] { s.split(separator: " ", omittingEmptySubsequences: true) }

func fetchPass(_ host: String, _ port: String) -> (Double, [Frame]) {
    var frames = [Frame]()
    var next = 0
    var f0 = 0.0
    var attempts = 0
    while true {
        guard let link = dial(host, port) else {
            attempts += 1
            if attempts > 50 { fail("cannot reach the camera head at \(host):\(port)") }
            usleep(200_000)
            continue
        }
        guard let greet = link.readLine(), greet.hasPrefix("STC1 ") else { attempts += 1; usleep(100_000); continue }
        for f in fields(greet) {
            if f.hasPrefix("f=") { f0 = Double(f.dropFirst(2)) ?? f0 }
            if f.hasPrefix("size="), let n = Double(f.dropFirst(5)) { size = n; cx = (n - 1) / 2; cy = cx }
        }
        if !link.send("START \(next)\n") { continue }
        var done = false
        while let line = link.readLine() {
            if line.hasPrefix("FRAME ") {
                let f = fields(line)
                guard f.count == 7, let c = Int(f[1]), let e = Double(f[2]), let vx = Double(f[3]),
                      let vy = Double(f[4]), let vz = Double(f[5]), let n = Int(f[6]) else { break }
                var spots = [Spot]()
                spots.reserveCapacity(n)
                var ok = true
                for _ in 0..<n {
                    guard let s = link.readLine() else { ok = false; break }
                    let g = fields(s)
                    guard g.count == 3, let x = Double(g[0]), let y = Double(g[1]), let cc = Double(g[2]) else { ok = false; break }
                    spots.append(Spot(x: x, y: y, c: cc))
                }
                if !ok { break }   // a frame cut short is asked for again
                frames.append(Frame(counter: c, exposure: e, vel: V3(vx, vy, vz), spots: spots))
                next = c + 1
            } else if line == "EOS" {
                done = true
                break
            } else {
                break   // LINK DOWN, or anything else: reconnect and resume
            }
        }
        if done { break }
    }
    if f0 <= 0 { fail("the camera head never gave a focal length") }
    return (f0, frames)
}

struct Star { var id: Int; var u: V3; var m: Double }

func loadCatalogue(_ path: String) -> [Star] {
    guard let fp = fopen(path, "r") else { fail("cannot open the catalogue \(path)") }
    defer { fclose(fp) }
    var stars = [Star]()
    var linePtr: UnsafeMutablePointer<CChar>? = nil
    var cap = 0
    while getline(&linePtr, &cap, fp) > 0 {
        let s = String(cString: linePtr!)
        if s.hasPrefix("#") { continue }
        let f = s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
        guard f.count >= 4, let id = Int(f[0]), let ra = Double(f[1]), let de = Double(f[2]), let m = Double(f[3]) else { continue }
        let r = ra * .pi / 180, d = de * .pi / 180
        stars.append(Star(id: id, u: V3(cos(d) * cos(r), cos(d) * sin(r), sin(d)), m: m))
    }
    free(linePtr)
    return stars
}

// ---------------------------------------------------------------- the catalogue, indexed
final class Sky {
    let stars: [Star]
    let byDec: [Int32]          // star indices sorted by z (sine of declination)
    let zs: [Double]
    // lost-in-space index over the brightest stars: pairs sorted by separation
    let bright: [Int32]
    let pairs: PairIndex
    let maxSep: Double
    let byMag: [Int]
    // a second index over every star the camera can report, built the first time a frame
    // with enough spots is not solved through the bright one
    var deep: PairIndex? = nil

    init(_ stars: [Star], maxSep: Double, brightCount: Int) {
        self.stars = stars
        self.maxSep = maxSep
        let order = (0..<stars.count).sorted { stars[$0].u.z < stars[$1].u.z }
        byDec = order.map { Int32($0) }
        zs = order.map { stars[$0].u.z }
        let byMag = (0..<stars.count).sorted { stars[$0].m < stars[$1].m }
        self.byMag = byMag
        bright = byMag.prefix(min(brightCount, stars.count)).map { Int32($0) }
        pairs = PairIndex(stars, bright, maxSep: maxSep)
    }

    // Every star down to magnitude `faintest`, none left out. Pairs are packed in eight bytes,
    // so even a whole 60,000-star flight catalogue (about 58 million pairs) stays near 460 MB.
    func deepIndex(faintest: Double) -> PairIndex {
        if let d = deep { return d }
        let members = byMag.prefix { stars[$0].m <= faintest }.map { Int32($0) }
        let d = PairIndex(stars, members, maxSep: maxSep)
        fputs("tracker: deep index over \(members.count) stars, \(d.count) pairs\n", stderr)
        deep = d
        return d
    }

    // indices of stars within `radius` (radians) of `dir`
    func near(_ dir: V3, _ radius: Double) -> [Int] {
        let cmin = cos(radius)
        let dec = asin(max(-1, min(1, dir.z)))
        let z0 = sin(max(-.pi / 2, dec - radius)), z1 = sin(min(.pi / 2, dec + radius))
        var lo = 0, hi = zs.count
        while lo < hi { let m = (lo + hi) / 2; if zs[m] < z0 { lo = m + 1 } else { hi = m } }
        var out = [Int]()
        var i = lo
        while i < zs.count && zs[i] <= z1 {
            let s = Int(byDec[i])
            if stars[s].u.dot(dir) >= cmin { out.append(s) }
            i += 1
        }
        return out
    }

}

// Pairs of catalogue stars closer than the field's diagonal, sorted by separation. Each pair is
// one key: the separation in the top 32 bits (in units of maxSep / 2^32), then the two star
// indices in 16 bits each, which holds any catalogue up to 65,536 stars.
struct PairIndex {
    var keys = [UInt64]()
    let scale: Double

    init(_ stars: [Star], _ members: [Int32], maxSep: Double) {
        if stars.count > 65536 { fail("the catalogue holds \(stars.count) stars, more than the pair index can address") }
        let cmin = cos(maxSep)
        scale = 4294967295 / maxSep
        let n = members.count
        keys.reserveCapacity(Int(Double(n) * Double(n) * (1 - cmin) / 4 * 1.1) + 1024)
        for i in 0..<n {
            let ui = stars[Int(members[i])].u
            let hi = UInt64(UInt16(members[i])) << 16
            for j in (i + 1)..<n {
                let d = ui.dot(stars[Int(members[j])].u)
                if d >= cmin {
                    let q = UInt64(min(acos(min(1, d)) * scale, 4294967295))
                    keys.append(q << 32 | hi | UInt64(UInt16(members[j])))
                }
            }
        }
        keys.sort()
    }

    var count: Int { keys.count }
    func a(_ p: Int) -> Int32 { Int32((keys[p] >> 16) & 0xFFFF) }
    func b(_ p: Int) -> Int32 { Int32(keys[p] & 0xFFFF) }
    func ang(_ p: Int) -> Double { Double(keys[p] >> 32) / scale }

    func range(_ lo: Double, _ hi: Double) -> Range<Int> {
        var x = 0, y = keys.count
        while x < y { let m = (x + y) / 2; if ang(m) < lo { x = m + 1 } else { y = m } }
        var c = x, d = keys.count
        while c < d { let m = (c + d) / 2; if ang(m) <= hi { c = m + 1 } else { d = m } }
        return x..<c
    }
}

// ---------------------------------------------------------------- matching
struct Solution {
    var att: M3
    var matches: [(Int, Int)]   // (spot index, star index)
    var rms: Double             // pixels
}

final class Tracker {
    let sky: Sky
    var optics: Optics
    let fovRadius: Double
    var zp = 0.0, zpKnown = false, minCounts = 1e9

    init(sky: Sky, optics: Optics, fovRadius: Double) {
        self.sky = sky; self.optics = optics; self.fovRadius = fovRadius
    }

    func instMag(_ s: Spot, _ e: Double) -> Double { -2.5 * log10(max(s.c, 1) / e) }

    // Match predicted catalogue positions to spots, solve, rematch; nil if it does not hold together.
    func refine(_ fr: Frame, _ guess: M3, tol: Double, minMatches: Int, iterations: Int = 3) -> Solution? {
        let beta = (1 / cKmS) * fr.vel
        var att = guess
        var matches = [(Int, Int)]()
        var rms = 0.0
        let cand = sky.near(att.r2, fovRadius + 0.02)
        var app = [Int: V3]()
        for s in cand { app[s] = aberrate(sky.stars[s].u, beta) }
        let obsVec = fr.spots.map { toVector($0.x, $0.y, optics) }
        for it in 0..<iterations {
            matches.removeAll(keepingCapacity: true)
            var used = [Int: (Int, Double)]()   // spot -> (star, d2)
            for s in cand {
                let m = sky.stars[s].m
                if zpKnown {
                    let pred = fr.exposure * pow(10, -0.4 * (m - zp))
                    if pred < 0.45 * minCounts { continue }
                }
                guard let (px, py) = toPixel(att.apply(app[s]!), optics) else { continue }
                if px < -tol || py < -tol || px > size - 1 + tol || py > size - 1 + tol { continue }
                var bestJ = -1, bestD = tol * tol
                for (j, sp) in fr.spots.enumerated() where !sp.hot {
                    let dx = sp.x - px, dy = sp.y - py
                    let d2 = dx * dx + dy * dy
                    if d2 < bestD { bestD = d2; bestJ = j }
                }
                if bestJ < 0 { continue }
                if zpKnown {
                    let dm = instMag(fr.spots[bestJ], fr.exposure) + zp - m
                    if abs(dm) > 1.5 { continue }
                }
                if let (_, d0) = used[bestJ], d0 <= bestD { continue }
                used[bestJ] = (s, bestD)
            }
            for (j, v) in used { matches.append((j, v.0)) }
            if matches.count < minMatches { return nil }
            var res = [Double]()
            for pass in 0..<2 {
                // centroid scatter grows for faint spots: weight each star by its signal
                att = solveAttitude(matches.map { obsVec[$0.0] }, matches.map { app[$0.1]! },
                                    matches.map { let c = min(fr.spots[$0.0].c, 60000); let sg = 0.01 + 1.2 / c.squareRoot(); return 1 / (sg * sg) })
                res = matches.map { (j, s) -> Double in
                    guard let (px, py) = toPixel(att.apply(app[s]!), optics) else { return 1e9 }
                    return ((fr.spots[j].x - px) * (fr.spots[j].x - px) + (fr.spots[j].y - py) * (fr.spots[j].y - py)).squareRoot()
                }
                if pass == 1 { break }
                // a blended spot or a stray match sits well off the rest: drop it and solve again
                let med = res.sorted()[res.count / 2]
                let cut = max(0.3, 4 * med)
                let keep = (0..<matches.count).filter { res[$0] <= cut }
                if keep.count == matches.count || keep.count < minMatches { break }
                matches = keep.map { matches[$0] }
            }
            rms = (res.reduce(0) { $0 + $1 * $1 } / Double(res.count)).squareRoot()
            _ = it
        }
        return Solution(att: att, matches: matches, rms: rms)
    }

    // Lost in space: triangles of bright spots against a pair index, each verified on the field.
    func lostInSpace(_ fr: Frame, _ index: PairIndex, tolFrac: Double, tolAbs: Double, verifyTol: Double) -> Solution? {
        var order = [Int]()
        for (j, s) in fr.spots.enumerated() where !s.hot { order.append(j) }
        if order.count < 4 { return nil }
        order.sort { fr.spots[$0].c > fr.spots[$1].c }
        let top = Array(order.prefix(9))
        let vec = top.map { toVector(fr.spots[$0].x, fr.spots[$0].y, optics) }
        var triples = [(Int, Int, Int)]()
        for a in 0..<top.count { for b in (a + 1)..<top.count { for c in (b + 1)..<top.count { triples.append((a, b, c)) } } }
        triples.sort { ($0.0 + $0.1 + $0.2) < ($1.0 + $1.1 + $1.2) }
        let stars = sky.stars
        var tried = 0
        for (a, b, c) in triples {
            let dab = acos(min(1, vec[a].dot(vec[b]))), dac = acos(min(1, vec[a].dot(vec[c]))), dbc = acos(min(1, vec[b].dot(vec[c])))
            if dab < 0.004 || dac < 0.004 || dbc < 0.004 { continue }
            let tab = tolFrac * dab + tolAbs, tac = tolFrac * dac + tolAbs, tbc = tolFrac * dbc + tolAbs
            let rab = index.range(dab - tab, dab + tab)
            let rac = index.range(dac - tac, dac + tac)
            if rab.isEmpty || rac.isEmpty { continue }
            // partners of each star across the a-c candidates
            var acMap = [Int32: [Int32]]()
            for p in rac {
                acMap[index.a(p), default: []].append(index.b(p))
                acMap[index.b(p), default: []].append(index.a(p))
            }
            let handed = vec[a].dot(vec[b].cross(vec[c])) > 0
            let cbcLo = cos(dbc + tbc), cbcHi = cos(max(0, dbc - tbc))
            for p in rab {
                for (sa, sb) in [(index.a(p), index.b(p)), (index.b(p), index.a(p))] {
                    guard let cs = acMap[sa] else { continue }
                    let ub = stars[Int(sb)].u, ua = stars[Int(sa)].u
                    for sc in cs where sc != sb {
                        let uc = stars[Int(sc)].u
                        let d = ub.dot(uc)
                        if d < cbcLo || d > cbcHi { continue }
                        if (ua.dot(ub.cross(uc)) > 0) != handed { continue }
                        tried += 1
                        let att = solveAttitude([vec[a], vec[b], vec[c]], [ua, ub, uc])
                        if let sol = refine(fr, att, tol: verifyTol, minMatches: 6, iterations: 2),
                           sol.matches.count >= max(6, order.count / 3) {
                            return sol
                        }
                        if tried > 4000 { return nil }
                    }
                }
            }
        }
        return nil
    }
}

// ---------------------------------------------------------------- main
// Tracking carries the attitude from one frame to the next; the fit of the optics runs this
// many rounds, each re-solving every attitude.
let tracking = true
let opticsRounds = 4

func main() {
    guard let host = env("CAMERA_HOST"), let port = env("CAMERA_PORT") else { fail("CAMERA_HOST and CAMERA_PORT are not set") }
    guard let catPath = env("STAR_CATALOG") else { fail("STAR_CATALOG is not set") }
    let t0 = clockSeconds()
    let (f0, fetched) = fetchPass(host, port)
    var frames = fetched
    let t1 = clockSeconds()
    let stars = loadCatalogue(catPath)
    if stars.count < 10 { fail("the catalogue at \(catPath) holds \(stars.count) stars") }

    // Hot pixels: a spot on the same spot of the detector in a large share of the frames, and on
    // both sides of a counter jump. The sky moves across a slew; a detector defect does not.
    var seen = [Int: (n: Int, first: Int, last: Int)]()
    var arc = 0
    for (i, fr) in frames.enumerated() {
        if i > 0 && fr.counter - frames[i - 1].counter > 1 { arc += 1 }
        for s in fr.spots {
            let key = Int((s.x * 4).rounded()) * 8192 + Int((s.y * 4).rounded())
            let e = seen[key] ?? (0, arc, arc)
            seen[key] = (e.n + 1, e.first, arc)
        }
    }
    var hotKeys = Set<Int>()
    for (key, e) in seen where e.n * 5 > frames.count && e.last > e.first { hotKeys.insert(key) }
    var minCounts = 1e9
    let maxExposure = frames.map { $0.exposure }.max() ?? 1
    for i in 0..<frames.count {
        for j in 0..<frames[i].spots.count {
            let s = frames[i].spots[j]
            let key = Int((s.x * 4).rounded()) * 8192 + Int((s.y * 4).rounded())
            if hotKeys.contains(key) { frames[i].spots[j].hot = true } else { minCounts = min(minCounts, s.c) }
        }
    }

    let halfDiag = atan(size / 2 * 2.0.squareRoot() / f0) * 1.03
    let fovSolid = 4 * pow(sin(atan(size / 2 / f0)), 2)   // the square field's solid angle, near enough
    let brightCount = Int(14 * 4 * Double.pi / fovSolid)
    let sky = Sky(stars, maxSep: 2 * halfDiag, brightCount: brightCount)
    let t2 = clockSeconds()
    let tracker = Tracker(sky: sky, optics: Optics(f: f0, k: 0), fovRadius: halfDiag)
    tracker.minCounts = minCounts

    // Pass 1: nominal optics, loose tolerances.
    var sols = [Int: Solution]()
    func runPass(tolTrack: Double, lisFrac: Double, lisAbs: Double, lisVerify: Double, deep: Bool, prior: [Int: Solution]?) -> [Int: Solution] {
        var out = [Int: Solution]()
        var prev: (Int, M3)? = nil, prev2: (Int, M3)? = nil
        var lisCalls = 0
        for fr in frames {
            var sol: Solution? = nil
            if let p = prior?[fr.counter] {
                sol = tracker.refine(fr, p.att, tol: tolTrack, minMatches: 6)
            } else {
                if tracking, let (pc, pa) = prev, fr.counter - pc <= 3 {
                    var guess = pa
                    if let (pc2, pa2) = prev2, pc - pc2 <= 3 {
                        // constant-rate extrapolation: delta = pa * pa2^T, applied again
                        let delta = pa * pa2.transposed
                        let steps = Double(fr.counter - pc) / Double(pc - pc2)
                        if steps == 1 { guess = delta * pa }
                    }
                    sol = tracker.refine(fr, guess, tol: tolTrack, minMatches: 6)
                    if let s = sol, s.matches.count < 6 || s.rms > tolTrack / 2 { sol = nil }
                }
                if sol == nil {
                    lisCalls += 1
                    sol = tracker.lostInSpace(fr, sky.pairs, tolFrac: lisFrac, tolAbs: lisAbs, verifyTol: lisVerify)
                }
                // Six or more usable spots and no answer through the bright stars: try every star the
                // camera can report, down to the faintest magnitude its weakest spot at the longest
                // exposure stands for (the whole catalogue until the photometry is known). First pass
                // only: what it finds is refined with the fitted optics like every other solution.
                if deep && sol == nil && fr.spots.filter({ !$0.hot }).count >= 6 {
                    let faintest = tracker.zpKnown ? tracker.zp - 2.5 * log10(minCounts / maxExposure) + 0.3 : 99
                    sol = tracker.lostInSpace(fr, sky.deepIndex(faintest: faintest), tolFrac: lisFrac, tolAbs: lisAbs, verifyTol: lisVerify)
                }
            }
            if let s = sol {
                out[fr.counter] = s
                if !tracker.zpKnown && s.matches.count >= 8 {
                    var d = s.matches.map { sky.stars[$0.1].m - tracker.instMag(fr.spots[$0.0], fr.exposure) }
                    d.sort()
                    tracker.zp = d[d.count / 2]
                    tracker.zpKnown = true
                }
                prev2 = prev; prev = (fr.counter, s.att)
            } else {
                prev = nil; prev2 = nil
            }
        }
        fputs("tracker: \(out.count) frames solved, \(lisCalls) lost-in-space solves\n", stderr)
        return out
    }

    sols = runPass(tolTrack: 9, lisFrac: 0.012, lisAbs: 0.0012, lisVerify: 9, deep: true, prior: nil)
    let t3 = clockSeconds()

    // Fit the unit's focal length and distortion to every matched star, jointly with the attitudes.
    let frameAt = Dictionary(uniqueKeysWithValues: frames.enumerated().map { ($0.element.counter, $0.offset) })
    for round in 0..<opticsRounds {
        var s11 = 0.0, s12 = 0.0, s22 = 0.0, r1 = 0.0, r2 = 0.0
        for (c, sol) in sols {
            let fr = frames[frameAt[c]!]
            let beta = (1 / cKmS) * fr.vel
            for (j, s) in sol.matches {
                let v = sol.att.apply(aberrate(sky.stars[s].u, beta))
                let u = v.x / v.z, w = v.y / v.z
                let rho2 = u * u + w * w
                let dx = fr.spots[j].x - cx, dy = fr.spots[j].y - cy
                // dx = a u + b u rho2 ; dy = a w + b w rho2
                s11 += u * u + w * w
                s12 += (u * u + w * w) * rho2
                s22 += (u * u + w * w) * rho2 * rho2
                r1 += dx * u + dy * w
                r2 += (dx * u + dy * w) * rho2
            }
        }
        let det = s11 * s22 - s12 * s12
        let (a, b) = ((r1 * s22 - r2 * s12) / det, (s11 * r2 - s12 * r1) / det)
        tracker.optics = Optics(f: a, k: b / a)
        fputs("tracker: optics round \(round): f \(a) k \(b / a)\n", stderr)
        var next = [Int: Solution]()
        for (c, sol) in sols {
            let fr = frames[frameAt[c]!]
            if let s = tracker.refine(fr, sol.att, tol: round < 2 ? 6 : 3, minMatches: 6) { next[c] = s }
        }
        sols = next
    }
    // Pass 2 with the fitted optics: frames lost in pass 1 get another chance.
    let calibrated = runPass(tolTrack: 3, lisFrac: 0.002, lisAbs: 0.0004, lisVerify: 3, deep: false, prior: nil)
    for (c, s) in calibrated where sols[c] == nil { sols[c] = s }
    let t4 = clockSeconds()

    // One line for every frame received. A frame with no solution (the Earth in the field, too few
    // stars) repeats the last solved attitude, or the identity before the first one.
    var out = ""
    out.reserveCapacity(frames.count * 80)
    var att = M3(r0: V3(1, 0, 0), r1: V3(0, 1, 0), r2: V3(0, 0, 1))
    for fr in frames {
        if let s = sols[fr.counter] { att = s.att }
        let q = qFromMat(att)
        out += "\(fr.counter) \(q[0]) \(q[1]) \(q[2]) \(q[3])\n"
    }
    fputs(out, stdout)
    fflush(stdout)
    fputs("tracker: fetch \(fmt(t1 - t0)) s, index \(fmt(t2 - t1)) s, pass 1 \(fmt(t3 - t2)) s, optics and pass 2 \(fmt(t4 - t3)) s; \(frames.count) frames, \(sols.count) solved\n", stderr)
}

func clockSeconds() -> Double {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return Double(ts.tv_sec) + Double(ts.tv_nsec) * 1e-9
}

func fmt(_ x: Double) -> String { String(Double(Int((x * 100).rounded())) / 100) }

main()
