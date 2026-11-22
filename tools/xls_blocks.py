#!/usr/bin/env python3
"""把汕大导出的 .xls 课表拆成条目，看看解析器要处理哪些写法。

格式（从真实文件反推）：
    每行一个大节：一(01,02) 二(03,04,05) 三(06,07) 四(08,09,10) 五(11,12,13)
    每格可能塞多门课，块与块之间用空行分隔，块内四行：
        课程名
        教师
        周次([周])[节次]
        地点
"""
import re
import sys

sys.path.insert(0, 'tools')
from read_xls import read_ole, read_biff  # noqa: E402

WEEKDAY = {'星期一': 1, '星期二': 2, '星期三': 3, '星期四': 4,
           '星期五': 5, '星期六': 6, '星期日': 7}


def parse_blocks(text):
    """一格里的文字 → [{title, teacher, weeks, periods, place}]"""
    blocks = []
    chunk = []
    for line in str(text).split('\n'):
        if line.strip():
            chunk.append(line.strip())
        elif chunk:
            blocks.append(chunk)
            chunk = []
    if chunk:
        blocks.append(chunk)
    out = []
    for b in blocks:
        if len(b) < 3:
            continue
        # 块内可能第一行是空行残留；按「周次([周])[节次]」定位
        week_line = next((x for x in b if '周' in x and '节' in x), None)
        if week_line is None:
            continue
        idx = b.index(week_line)
        title = b[0] if idx > 0 else '(无标题)'
        teacher = b[1] if idx > 1 else ''
        m = re.search(r'([\d,\-]+)\(\[周\]\)\[([\d\-]+)节\]', week_line)
        weeks = m.group(1) if m else ''
        periods = m.group(2) if m else ''
        place = b[idx + 1] if idx + 1 < len(b) else ''
        out.append({'title': title.strip(), 'teacher': teacher.strip(),
                    'weeks': weeks, 'periods': periods, 'place': place.strip()})
    return out


def main():
    path = sys.argv[1]
    streams = read_ole(path)
    _sheets, grid = read_biff(streams.get('Workbook') or streams.get('Book'))

    head = grid[2]
    cols = {c: WEEKDAY.get(str(head[c]).strip()) for c in range(1, len(head))}
    print('星期列：', {k: v for k, v in cols.items() if v})

    entries = []
    for r in range(3, len(grid)):
        for c, dow in cols.items():
            if not dow or c >= len(grid[r]):
                continue
            for b in parse_blocks(grid[r][c]):
                b['day'] = dow
                entries.append(b)

    print(f'\n共 {len(entries)} 个课块：\n')
    print(f"{'课程':32s}{'星期':4s}{'节次':12s}{'周次':26s}地点")
    for e in entries:
        print(f"{e['title'][:30]:32s}周{e['day']}   {e['periods']:12s}"
              f"{e['weeks']:26s}{e['place']}")

    # 同一门课不同教师/周次的分段，按「课名+星期+节次+地点」合并周次
    print('\n按「课名+星期+节次+地点」合并：')
    merged = {}
    for e in entries:
        key = (e['title'], e['day'], e['periods'], e['place'])
        merged.setdefault(key, []).append(e['weeks'])
    for (title, day, periods, place), weeks in merged.items():
        teachers = {'?': ''}
        print(f"  周{day} {periods:12s} {title[:26]:28s} 周次={' + '.join(weeks):24s} @{place}")


if __name__ == '__main__':
    main()
