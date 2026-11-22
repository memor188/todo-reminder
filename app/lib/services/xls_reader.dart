import 'dart:convert';
import 'dart:typed_data';

/// 老式 `.xls`（OLE2 复合文档 + BIFF8）里的一张工作表。
///
/// 为什么自己写：教务系统导出的课表就是 BIFF8，`excel` 这类包只认 xlsx。
/// 一个「把文件丢进来」的功能，不能要求用户先去另存为别的格式。
///
/// 支持范围（够读课表就行，不做公式、样式、多表）：
/// - OLE2 复合文档（含 mini stream，小于 4096 字节的流走它）
/// - BIFF8 的 SST / CONTINUE、LABELSST、NUMBER、RK、MULRK、LABEL
///
/// 拿到的是一张按行列铺好的字符串网格，空单元格是空串。
class XlsSheet {
  const XlsSheet({required this.name, required this.rows});

  final String name;
  final List<List<String>> rows;

  bool get isEmpty => rows.every((row) => row.every((c) => c.trim().isEmpty));

  int get rowCount => rows.length;
  int get colCount => rows.isEmpty ? 0 : rows.first.length;

  String cell(int row, int col) {
    if (row < 0 || row >= rows.length) return '';
    final line = rows[row];
    if (col < 0 || col >= line.length) return '';
    return line[col];
  }
}

class XlsFormatException implements Exception {
  const XlsFormatException(this.message);
  final String message;
  @override
  String toString() => 'XlsFormatException: $message';
}

/// 读第一个工作表。文件不是 OLE2 / BIFF8 时抛 [XlsFormatException]。
XlsSheet readFirstXlsSheet(Uint8List bytes) {
  if (bytes.length < 512 || !_isOle2(bytes)) {
    throw const XlsFormatException('不是 .xls 文件（缺 OLE2 头）。如果是 xlsx，另存为 .xls 或直接导出 CSV');
  }
  final streams = _Ole2(bytes).readStreams();
  final workbook = streams['Workbook'] ?? streams['Book'];
  if (workbook == null) {
    throw const XlsFormatException('这个 .xls 里没有 Workbook 流，可能是别的 Office 文档');
  }
  return _parseBiff(workbook);
}

bool _isOle2(Uint8List bytes) {
  const magic = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];
  for (var i = 0; i < magic.length; i++) {
    if (bytes[i] != magic[i]) return false;
  }
  return true;
}

class _Ole2 {
  _Ole2(this.bytes);

  final Uint8List bytes;
  late final ByteData _view = ByteData.sublistView(bytes);
  late final int sectorSize = 1 << _view.getUint16(0x1E, Endian.little);
  late final int miniSize = 1 << _view.getUint16(0x20, Endian.little);

  int _u32(int offset) => _view.getUint32(offset, Endian.little);

  Uint8List _sector(int index) {
    final start = (index + 1) * sectorSize;
    final end = (start + sectorSize).clamp(0, bytes.length);
    return Uint8List.sublistView(bytes, start, end);
  }

  List<int> _chain(int start, List<int> table) {
    final out = <int>[];
    var current = start;
    while (current < 0xFFFFFFFA && out.length < 1 << 20) {
      out.add(current);
      current = current < table.length ? table[current] : 0xFFFFFFFE;
    }
    return out;
  }

  Uint8List _readChain(int start, List<int> fat) {
    final builder = BytesBuilder(copy: false);
    for (final index in _chain(start, fat)) {
      builder.add(_sector(index));
    }
    return builder.toBytes();
  }

  Map<String, Uint8List> readStreams() {
    final numFat = _u32(0x2C);
    final dirStart = _u32(0x30);
    final miniCutoff = _u32(0x38);
    final miniFatStart = _u32(0x3C);
    final difatStart = _u32(0x44);
    final numDifat = _u32(0x48);

    // DIFAT：前 109 个条目在头部，之后串成链
    final difat = <int>[];
    for (var i = 0; i < 109; i++) {
      difat.add(_u32(0x4C + i * 4));
    }
    var next = difatStart;
    for (var i = 0; i < numDifat; i++) {
      if (next >= 0xFFFFFFFA) break;
      final sec = _sector(next);
      final view = ByteData.sublistView(sec);
      final perSector = sectorSize ~/ 4;
      for (var j = 0; j < perSector - 1; j++) {
        difat.add(view.getUint32(j * 4, Endian.little));
      }
      next = view.getUint32((perSector - 1) * 4, Endian.little);
    }
    final fatSectors = difat.where((x) => x < 0xFFFFFFFA).take(numFat).toList();

    final fat = <int>[];
    for (final index in fatSectors) {
      final view = ByteData.sublistView(_sector(index));
      for (var j = 0; j < sectorSize ~/ 4; j++) {
        fat.add(view.getUint32(j * 4, Endian.little));
      }
    }

    // 目录项：128 字节一条
    final dirBytes = _readChain(dirStart, fat);
    final entries = <_DirEntry>[];
    for (var off = 0; off + 128 <= dirBytes.length; off += 128) {
      final entry = ByteData.sublistView(
        Uint8List.sublistView(dirBytes, off, off + 128),
      );
      final nameLen = entry.getUint16(0x40, Endian.little);
      final nameUnits = <int>[];
      for (var i = 0; i + 1 < nameLen; i += 2) {
        nameUnits.add(entry.getUint16(i, Endian.little));
      }
      // nameLen 把结尾的 NUL 也算进去了，直接转字符串会得到 'Workbook\u0000'，
      // 后面按名字找流就永远找不到。.
      while (nameUnits.isNotEmpty && nameUnits.last == 0) {
        nameUnits.removeLast();
      }
      entries.add(
        _DirEntry(
          name: String.fromCharCodes(nameUnits),
          type: entry.getUint8(0x42),
          start: entry.getUint32(0x74, Endian.little),
          size: entry.getUint32(0x78, Endian.little),
        ),
      );
    }

    // 小流本体在 root entry 的数据里
    final root = entries.where((e) => e.type == 5).firstOrNull;
    final miniStream = root == null || root.size == 0
        ? Uint8List(0)
        : _readChain(root.start, fat);

    final miniFat = <int>[];
    for (final index in _chain(miniFatStart, fat)) {
      final view = ByteData.sublistView(_sector(index));
      for (var j = 0; j < sectorSize ~/ 4; j++) {
        miniFat.add(view.getUint32(j * 4, Endian.little));
      }
    }

    final result = <String, Uint8List>{};
    for (final entry in entries) {
      if (entry.type != 2) continue;
      Uint8List data;
      if (entry.size < miniCutoff && miniStream.isNotEmpty) {
        final builder = BytesBuilder(copy: false);
        for (final index in _chain(entry.start, miniFat)) {
          final start = index * miniSize;
          final end = (start + miniSize).clamp(0, miniStream.length);
          if (start >= miniStream.length) break;
          builder.add(Uint8List.sublistView(miniStream, start, end));
        }
        data = builder.toBytes();
      } else {
        data = _readChain(entry.start, fat);
      }
      result[entry.name] = Uint8List.sublistView(
        data,
        0,
        entry.size.clamp(0, data.length),
      );
    }
    return result;
  }
}

class _DirEntry {
  const _DirEntry({
    required this.name,
    required this.type,
    required this.start,
    required this.size,
  });

  final String name;
  final int type;
  final int start;
  final int size;
}

/// BIFF8 记录流 → 网格。
XlsSheet _parseBiff(Uint8List stream) {
  var pos = 0;
  final view = ByteData.sublistView(stream);
  var sst = <String>[];
  final cells = <int, Map<int, String>>{};
  var sheetName = 'Sheet1';
  var sawBoundsheet = false;

  while (pos + 4 <= stream.length) {
    final id = view.getUint16(pos, Endian.little);
    final length = view.getUint16(pos + 2, Endian.little);
    final bodyStart = pos + 4;
    final bodyEnd = (bodyStart + length).clamp(0, stream.length);
    pos = bodyEnd;

    switch (id) {
      case 0x00FC: // SST
        final segments = <Uint8List>[Uint8List.sublistView(stream, bodyStart, bodyEnd)];
        var probe = pos;
        while (probe + 4 <= stream.length) {
          final rid = view.getUint16(probe, Endian.little);
          if (rid != 0x003C) break; // CONTINUE
          final len = view.getUint16(probe + 2, Endian.little);
          final start = probe + 4;
          final end = (start + len).clamp(0, stream.length);
          segments.add(Uint8List.sublistView(stream, start, end));
          probe = end;
        }
        pos = probe;
        sst = _readSst(segments);
        break;
      case 0x0085: // BOUNDSHEET
        if (!sawBoundsheet && length >= 8) {
          final cch = stream[bodyStart + 6];
          final flags = stream[bodyStart + 7];
          sheetName = _decodeChars(
            Uint8List.sublistView(stream, bodyStart + 8),
            cch,
            wide: (flags & 0x01) != 0,
          );
          sawBoundsheet = true;
        }
        break;
      case 0x00FD: // LABELSST
        if (length >= 10) {
          final row = view.getUint16(bodyStart, Endian.little);
          final col = view.getUint16(bodyStart + 2, Endian.little);
          final index = view.getUint32(bodyStart + 6, Endian.little);
          if (index < sst.length) {
            _put(cells, row, col, sst[index]);
          }
        }
        break;
      case 0x0203: // NUMBER
        if (length >= 14) {
          final row = view.getUint16(bodyStart, Endian.little);
          final col = view.getUint16(bodyStart + 2, Endian.little);
          final value = view.getFloat64(bodyStart + 6, Endian.little);
          _put(cells, row, col, _numberText(value));
        }
        break;
      case 0x027E: // RK
        if (length >= 10) {
          final row = view.getUint16(bodyStart, Endian.little);
          final col = view.getUint16(bodyStart + 2, Endian.little);
          final rk = view.getUint32(bodyStart + 6, Endian.little);
          _put(cells, row, col, _numberText(_rkToDouble(rk)));
        }
        break;
      case 0x00BD: // MULRK：一行里连续的多个 RK
        if (length >= 6) {
          final row = view.getUint16(bodyStart, Endian.little);
          final first = view.getUint16(bodyStart + 2, Endian.little);
          final count = (length - 6) ~/ 6;
          for (var i = 0; i < count; i++) {
            final rk = view.getUint32(bodyStart + 4 + i * 6 + 2, Endian.little);
            _put(cells, row, first + i, _numberText(_rkToDouble(rk)));
          }
        }
        break;
      case 0x0204: // LABEL（BIFF8 里少见，但老文件有）
        if (length >= 8) {
          final row = view.getUint16(bodyStart, Endian.little);
          final col = view.getUint16(bodyStart + 2, Endian.little);
          final cch = view.getUint16(bodyStart + 6, Endian.little);
          _put(
            cells,
            row,
            col,
            _decodeChars(
              Uint8List.sublistView(stream, bodyStart + 8),
              cch,
              wide: true,
            ),
          );
        }
        break;
    }
  }

  if (cells.isEmpty) return XlsSheet(name: sheetName, rows: const []);

  var maxRow = 0;
  var maxCol = 0;
  for (final row in cells.keys) {
    if (row > maxRow) maxRow = row;
    for (final col in cells[row]!.keys) {
      if (col > maxCol) maxCol = col;
    }
  }
  final rows = List.generate(
    maxRow + 1,
    (r) => List.generate(maxCol + 1, (c) => cells[r]?[c] ?? ''),
  );
  return XlsSheet(name: sheetName, rows: rows);
}

void _put(Map<int, Map<int, String>> cells, int row, int col, String value) {
  if (value.isEmpty) return;
  (cells[row] ??= {})[col] = value;
}

String _numberText(double value) {
  if (value == value.roundToDouble() && value.abs() < 1e15) {
    return value.toInt().toString();
  }
  return value.toString();
}

/// RK：低两位是标志位，其余是「30 位整数 ×100」或「IEEE754 高位」。
double _rkToDouble(int rk) {
  double value;
  if ((rk & 0x02) != 0) {
    // 有符号 30 位整数
    var intVal = rk >> 2;
    if ((rk & 0x80000000) != 0) intVal |= 0xC0000000;
    value = intVal.toSigned(32).toDouble();
  } else {
    // 剩下 30 位当成 IEEE754 双精度的【高】32 位，低 32 位补 0
    final buffer = ByteData(8);
    buffer.setUint32(0, 0, Endian.little);
    buffer.setUint32(4, rk & 0xFFFFFFFC, Endian.little);
    value = buffer.getFloat64(0, Endian.little);
  }
  if ((rk & 0x01) != 0) value /= 100.0;
  return value;
}

String _decodeChars(Uint8List data, int count, {required bool wide}) {
  if (wide) {
    final units = <int>[];
    for (var i = 0; i + 1 < data.length && units.length < count; i += 2) {
      units.add(data[i] | (data[i + 1] << 8));
    }
    return String.fromCharCodes(units);
  }
  final units = <int>[];
  for (var i = 0; i < data.length && i < count; i++) {
    units.add(data[i]);
  }
  return String.fromCharCodes(units);
}

/// SST：字符串表。长字符串会被切成多条 CONTINUE，跨段时新段首字节重新声明编码。
List<String> _readSst(List<Uint8List> segments) {
  final reader = _SegReader(segments);
  reader.u32(); // 总引用次数
  final unique = reader.u32();
  final out = <String>[];
  for (var i = 0; i < unique; i++) {
    final cch = reader.u16();
    final flags = reader.byte();
    final rich = (flags & 0x08) != 0;
    final farEast = (flags & 0x04) != 0;
    final runs = rich ? reader.u16() : 0;
    final extLen = farEast ? reader.u32() : 0;

    var wide = (flags & 0x01) != 0;
    final units = <int>[];
    var remaining = cch;
    while (remaining > 0) {
      if (reader.available == 0) {
        wide = (reader.nextSegment() & 0x01) != 0;
      }
      if (wide) {
        // 宽字符可能跨段：按「可读的完整字符数」取
        final canRead = reader.available ~/ 2;
        final take = remaining < canRead ? remaining : canRead;
        if (take == 0) {
          // 段里只剩半个字符：BIFF8 不会这么切，真遇到就跳过这段免得死循环
          reader.nextSegment();
          continue;
        }
        for (var k = 0; k < take; k++) {
          units.add(reader.u16());
        }
        remaining -= take;
      } else {
        final take = remaining < reader.available ? remaining : reader.available;
        for (var k = 0; k < take; k++) {
          units.add(reader.byte());
        }
        remaining -= take;
      }
    }
    if (runs > 0) reader.take(runs * 4);
    if (extLen > 0) reader.take(extLen);
    out.add(String.fromCharCodes(units));
  }
  return out;
}

/// 跨段读字节：SST 的字符串数据会被 8224 字节的记录长度上限切断。
class _SegReader {
  _SegReader(this.segments);

  final List<Uint8List> segments;
  int _index = 0;
  int _pos = 0;

  int get available => segments[_index].length - _pos;

  int nextSegment() {
    _index += 1;
    if (_index >= segments.length) {
      throw const XlsFormatException('字符串表被截断（CONTINUE 段不够）');
    }
    _pos = 0;
    return segments[_index][0];
  }

  int byte() {
    if (available <= 0) nextSegment();
    return segments[_index][_pos++];
  }

  List<int> take(int count) {
    final out = <int>[];
    var remaining = count;
    while (remaining > 0) {
      if (available <= 0) nextSegment();
      final step = remaining < available ? remaining : available;
      out.addAll(segments[_index].sublist(_pos, _pos + step));
      _pos += step;
      remaining -= step;
    }
    return out;
  }

  int u16() {
    final bytes = take(2);
    return bytes[0] | (bytes[1] << 8);
  }

  int u32() {
    final bytes = take(4);
    return bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24);
  }
}

/// 给外部用的文本解码（某些导出文件是 UTF-8 的 csv/txt）。
String decodeUtf8OrLatin(Uint8List bytes) {
  try {
    return utf8.decode(bytes);
  } catch (_) {
    return String.fromCharCodes(bytes);
  }
}
