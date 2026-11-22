#!/usr/bin/env python3
"""最小 OLE2 + BIFF8 读取器：把一个老式 .xls 里的工作表打印成网格。

为什么自己写：本机没有 xlrd / olefile，而我要先看清学校导出的课表长什么样，
才能决定 App 里怎么解析它。只用标准库，不装任何依赖。

支持范围（够看清课表就行）：
    - OLE2 复合文档（含 mini stream）
    - BIFF8 的 SST / CONTINUE、LABELSST、NUMBER、RK、MULRK、LABEL
"""
import struct
import sys

SECTOR = None  # 运行时按头部填


def read_ole(path):
    """返回 {stream_name: bytes}，只要 Workbook 流。"""
    raw = open(path, 'rb').read()
    assert raw[:8] == bytes.fromhex('d0cf11e0a1b11ae1'), '不是 OLE2 文件'
    sector_shift = struct.unpack_from('<H', raw, 0x1E)[0]
    mini_shift = struct.unpack_from('<H', raw, 0x20)[0]
    sector_size = 1 << sector_shift
    mini_size = 1 << mini_shift
    num_fat = struct.unpack_from('<I', raw, 0x2C)[0]
    dir_start = struct.unpack_from('<I', raw, 0x30)[0]
    mini_cutoff = struct.unpack_from('<I', raw, 0x38)[0]
    mini_fat_start = struct.unpack_from('<I', raw, 0x3C)[0]
    num_mini_fat = struct.unpack_from('<I', raw, 0x40)[0]
    difat_start = struct.unpack_from('<I', raw, 0x44)[0]
    num_difat = struct.unpack_from('<I', raw, 0x48)[0]

    def sector(i):
        off = (i + 1) * sector_size
        return raw[off:off + sector_size]

    # DIFAT：前 109 个在头部，后面串成链
    difat = list(struct.unpack_from('<109I', raw, 0x4C))
    nxt = difat_start
    for _ in range(num_difat):
        if nxt >= 0xFFFFFFFA:
            break
        sec = sector(nxt)
        vals = struct.unpack_from('<%dI' % (sector_size // 4), sec, 0)
        difat.extend(vals[:-1])
        nxt = vals[-1]
    fat_sectors = [x for x in difat if x < 0xFFFFFFFA][:num_fat]

    # FAT
    fat = []
    for fs in fat_sectors:
        fat.extend(struct.unpack_from('<%dI' % (sector_size // 4), sector(fs), 0))

    def chain(start, table, limit=1 << 20):
        out, cur, guard = [], start, 0
        while cur < 0xFFFFFFFA and guard < limit:
            out.append(cur)
            cur = table[cur] if cur < len(table) else 0xFFFFFFFE
            guard += 1
        return out

    def read_chain(start):
        return b''.join(sector(i) for i in chain(start, fat))

    # 目录
    dir_bytes = read_chain(dir_start)
    entries = []
    for off in range(0, len(dir_bytes), 128):
        e = dir_bytes[off:off + 128]
        if len(e) < 128:
            break
        name_len = struct.unpack_from('<H', e, 0x40)[0]
        name = e[:max(0, name_len - 2)].decode('utf-16-le', 'ignore')
        etype = e[0x42]
        start = struct.unpack_from('<I', e, 0x74)[0]
        size = struct.unpack_from('<I', e, 0x78)[0]
        entries.append((name, etype, start, size))

    # 小流（root entry 的 data 才是 mini stream 本体）
    root = next((x for x in entries if x[1] == 5), None)
    mini_stream = read_chain(root[2]) if root and root[3] else b''
    mini_fat = []
    for i in chain(mini_fat_start, fat):
        mini_fat.extend(struct.unpack_from('<%dI' % (sector_size // 4), sector(i), 0))

    streams = {}
    for name, etype, start, size in entries:
        if etype != 2:
            continue
        if size < mini_cutoff and mini_stream:
            data = b''.join(
                mini_stream[i * mini_size:(i + 1) * mini_size]
                for i in chain(start, mini_fat)
            )
        else:
            data = read_chain(start)
        streams[name] = data[:size]
    return streams


class SegReader:
    """跨 CONTINUE 段读字节：SST 的长字符串会被切成多段。"""

    def __init__(self, segments):
        self.segs = segments
        self.si = 0
        self.pos = 0

    def _avail(self):
        return len(self.segs[self.si]) - self.pos

    def next_segment(self):
        """进入下一段，返回该段首字节（编码标志），由调用方消费。"""
        self.si += 1
        if self.si >= len(self.segs):
            raise EOFError('SST 段用完了')
        self.pos = 0
        return self.segs[self.si][0]

    def byte(self):
        if self._avail() <= 0:
            self.next_segment()
        b = self.segs[self.si][self.pos]
        self.pos += 1
        return b

    def take(self, n):
        out = bytearray()
        while n > 0:
            if self._avail() <= 0:
                self.next_segment()
            k = min(n, self._avail())
            out += self.segs[self.si][self.pos:self.pos + k]
            self.pos += k
            n -= k
        return bytes(out)

    def u16(self):
        return struct.unpack('<H', self.take(2))[0]

    def u32(self):
        return struct.unpack('<I', self.take(4))[0]


def read_sst(segments):
    """解析 SST，返回字符串列表。"""
    r = SegReader(segments)
    r.u32()  # 总引用数
    unique = r.u32()
    out = []
    for _ in range(unique):
        cch = r.u16()
        grbit = r.byte()
        high = grbit & 0x01
        rich = (grbit >> 3) & 0x01
        far = (grbit >> 2) & 0x01
        runs = r.u16() if rich else 0
        ext = r.u32() if far else 0
        # 字符数据，可能跨段；跨段时新段首字节重新给编码标志
        chars = []
        remaining = cch
        wide = high
        while remaining > 0:
            if r._avail() <= 0:
                wide = r.next_segment() & 0x01
            if wide:
                chunk = r.take(2 * remaining)
                chars.append(chunk.decode('utf-16-le', 'ignore'))
                remaining = 0
            else:
                n = min(remaining, r._avail())
                chunk = r.take(n)
                chars.append(chunk.decode('latin-1'))
                remaining -= n
                if remaining == 0:
                    break
        if runs:
            r.take(4 * runs)
        if ext:
            r.take(ext)
        out.append(''.join(chars))
    return out


def rk_to_num(rk):
    """RK 编码的数值：低位标志决定是整数还是 float、要不要除以 100。"""
    if rk & 0x02:
        val = float(rk >> 2 if rk < 0x80000000 else (rk >> 2) - (1 << 30))
        # 有符号处理：按 30 位补码
        if rk & 0x80000000:
            val = float(((rk >> 2) | 0xC0000000) - 0x100000000)
        else:
            val = float(rk >> 2)
    else:
        val = struct.unpack('<d', struct.pack('<Q', (rk & 0xFFFFFFFC) << 32))[0]
    if rk & 0x01:
        val /= 100.0
    return val


def read_biff(stream):
    """返回 (sheets, grid) —— 只取第一张工作表的网格。"""
    pos, n = 0, len(stream)
    sst, cells = [], {}
    max_row = max_col = 0
    sheet_names = []
    while pos + 4 <= n:
        rid, length = struct.unpack_from('<HH', stream, pos)
        body = stream[pos + 4:pos + 4 + length]
        pos += 4 + length
        if rid == 0x00FC:  # SST
            segs = [body]
            p = pos
            while p + 4 <= n:
                rid2, len2 = struct.unpack_from('<HH', stream, p)
                if rid2 != 0x003C:
                    break
                segs.append(stream[p + 4:p + 4 + len2])
                p += 4 + len2
            pos = p
            sst = read_sst(segs)
        elif rid == 0x0085:  # BOUNDSHEET
            cch = body[6]
            flags = body[7]
            if flags & 0x01:
                name = body[8:8 + cch * 2].decode('utf-16-le', 'ignore')
            else:
                name = body[8:8 + cch].decode('latin-1')
            sheet_names.append(name)
        elif rid == 0x00FD:  # LABELSST
            row, col, _xf, isst = struct.unpack_from('<HHHI', body, 0)
            if isst < len(sst):
                cells[(row, col)] = sst[isst]
        elif rid == 0x0203:  # NUMBER
            row, col, _xf, val = struct.unpack_from('<HHHd', body, 0)
            cells[(row, col)] = val
        elif rid == 0x027E:  # RK
            row, col, _xf, rk = struct.unpack_from('<HHHI', body, 0)
            cells[(row, col)] = rk_to_num(rk)
        elif rid == 0x00BD:  # MULRK
            row, first = struct.unpack_from('<HH', body, 0)
            count = (length - 6) // 6
            for i in range(count):
                rk = struct.unpack_from('<I', body, 4 + i * 6 + 2)[0]
                cells[(row, first + i)] = rk_to_num(rk)
        elif rid == 0x0204:  # LABEL
            row, col = struct.unpack_from('<HH', body, 0)
            cch = struct.unpack_from('<H', body, 6)[0]
            cells[(row, col)] = body[8:8 + cch].decode('utf-16-le', 'ignore')
    for (r, c) in cells:
        max_row, max_col = max(max_row, r), max(max_col, c)
    grid = [[cells.get((r, c), '') for c in range(max_col + 1)]
            for r in range(max_row + 1)]
    return sheet_names, grid


def main():
    path = sys.argv[1]
    streams = read_ole(path)
    print('流：', list(streams))
    data = streams.get('Workbook') or streams.get('Book')
    sheets, grid = read_biff(data)
    print('工作表：', sheets)
    print('网格 %d 行 × %d 列' % (len(grid), len(grid[0]) if grid else 0))
    for i, row in enumerate(grid):
        cells = [str(x).replace('\n', '⏎') for x in row]
        if any(c.strip() for c in cells):
            print(f'[{i:2d}] ' + ' | '.join(cells))


if __name__ == '__main__':
    main()
