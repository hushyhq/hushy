import Darwin
import Foundation

// coldcopy copy <src> <dst>   copies with F_NOCACHE on both ends, so dst's pages are not left in the file cache
// coldcopy resident <file>    prints the share of <file>'s pages in the file cache (mincore)
let args = CommandLine.arguments
func fail(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(1) }

func copy(_ src: String, _ dst: String) {
    let i = open(src, O_RDONLY), o = open(dst, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard i >= 0, o >= 0 else { fail("open failed") }
    _ = fcntl(i, F_NOCACHE, 1); _ = fcntl(o, F_NOCACHE, 1)
    let size = 8 << 20
    let buf = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16384)
    while true {
        let n = read(i, buf, size)
        if n < 0 { fail("read failed") }
        if n == 0 { break }
        var off = 0
        while off < n { let w = write(o, buf + off, n - off); if w <= 0 { fail("write failed") }; off += w }
    }
    _ = fsync(o); close(i); close(o)
}

func resident(_ path: String) -> Double {
    let fd = open(path, O_RDONLY)
    var st = stat(); fstat(fd, &st)
    let len = Int(st.st_size)
    guard len > 0, let p = mmap(nil, len, PROT_READ, MAP_SHARED, fd, 0), p != MAP_FAILED else { fail("mmap failed") }
    let page = Int(getpagesize()), pages = (len + page - 1) / page
    var vec = [CChar](repeating: 0, count: pages)
    guard mincore(p, len, &vec) == 0 else { fail("mincore failed") }
    munmap(p, len); close(fd)
    return Double(vec.filter { $0 & 1 != 0 }.count) / Double(pages)
}

switch args.count > 1 ? args[1] : "" {
case "copy": copy(args[2], args[3])
case "resident": print(String(format: "%.4f", resident(args[2])))
default: fail("usage: coldcopy copy <src> <dst> | resident <file>")
}
