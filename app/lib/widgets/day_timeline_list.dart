import 'dart:async';

import 'package:flutter/material.dart';

import '../models/timeline.dart';
import 'timeline_item.dart';

/// 普通行位移/收展时长（取消勾选、日期内其它重排）。
///
/// 勾选完成走的是 [DayTimelineList] 里的四阶段粉尘动画，不用这个值。
const Duration kRowMoveDuration = Duration(milliseconds: 1000);

/// 勾选的四段时长（2026-11-25 定四段，11-26 改用 GPU shader 粉尘）。
///
/// 总长 2.2s：
/// ①  dissipating  0–500ms   卡片原地碎成粉尘飞散，**下方纹丝不动**
/// ②  collapsing  500–1100ms 卡片高度收起，下方条目滑上来补位
/// ③  reassembling 1100–1900ms 粉尘在下方已完成区聚成卡片
/// ④  flashing    1900–2300ms 聚成的卡片闪一下淡黄高亮
const Duration kBurstDissipate = Duration(milliseconds: 500);
const Duration kBurstCollapse = Duration(milliseconds: 600);
const Duration kBurstReassemble = Duration(milliseconds: 800);
const Duration kBurstFlash = Duration(milliseconds: 400);

/// 粉尘飞散方向。散开和重组必须用同一个值：往哪散，就从哪聚回来。
const Offset kDissolveDrift = Offset(18, 56);

/// 动画阶段。idle = 没有粉尘序列在跑（普通 reconcile 或完全静止）。
enum _BurstStage { idle, dissipating, collapsing, reassembling, flashing }

/// 行的身份。
sealed class _DayRow {
  const _DayRow();
  String get key;
}

class _HeaderRow extends _DayRow {
  const _HeaderRow(this.section, this.label, this.count);
  final String section;
  final String label;
  final int count;
  @override
  String get key => 'header_$section';
}

class _EntryRow extends _DayRow {
  const _EntryRow(this.entry, this.state);
  final TimelineEntry entry;
  final EntryState state;
  @override
  String get key => 'entry_${entry.key}';
}

class _FoldRow extends _DayRow {
  const _FoldRow(this.hidden, this.expanded);
  final int hidden;
  final bool expanded;
  @override
  String get key => 'fold';
}

/// 日程页一天的三段列表：正常 → 已过期 → 已完成。
///
/// 勾选一条任务/事件时按顺序播四段粉尘动画（见上方时长常量）：卡片原地碎成
/// 粉尘 → 下方补位 → 在已完成区重新聚成卡片 → 淡黄高亮。取消勾选、切日期、
/// 时间推移引起的重排走 [AnimatedList] 普通收展，不播粉尘（用户定的取舍）。
class DayTimelineList extends StatefulWidget {
  const DayTimelineList({
    super.key,
    required this.day,
    required this.sections,
    required this.now,
    this.courseColors,
    this.doneExpanded = false,
    this.foldThreshold = 5,
    this.flashKey,
    this.onOpenEntry,
    this.onToggleEntry,
    this.onToggleFold,
  });

  final DateTime day;
  final DaySections sections;
  final DateTime now;
  final Map<String, Color>? courseColors;
  final bool doneExpanded;
  final int foldThreshold;
  final String? flashKey;

  final ValueChanged<TimelineEntry>? onOpenEntry;
  final ValueChanged<TimelineEntry>? onToggleEntry;
  final VoidCallback? onToggleFold;

  @override
  State<DayTimelineList> createState() => _DayTimelineListState();
}

class _DayTimelineListState extends State<DayTimelineList>
    with SingleTickerProviderStateMixin {
  final GlobalKey<AnimatedListState> _listKey = GlobalKey<AnimatedListState>();

  late List<_DayRow> _rows;

  /// 逐帧驱动粉尘的 progress：散开 0→1，重组 1→0。
  late final AnimationController _dissolve = AnimationController(
    vsync: this,
    duration: kBurstDissipate,
  )..addListener(() {
      if (mounted) setState(() {});
    });

  double get _progress => _dissolve.value;

  _BurstStage _stage = _BurstStage.idle;
  String? _burstEntryKey;

  /// 勾选发生时的目标 rows。四段动画分步消化它：先 remove 源行、再 insert
  /// 目标行，中间刻意留空档，才有"散完 → 再重组"的先后。
  List<_DayRow>? _pendingNext;

  /// 动画期间到来的其它更新（60 秒 ticker 等）暂存，序列跑完再收敛。
  List<_DayRow>? _deferredNext;
  Timer? _stageTimer;

  @override
  void initState() {
    super.initState();
    _rows = _buildRows();
  }

  @override
  void dispose() {
    _stageTimer?.cancel();
    _dissolve.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant DayTimelineList oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = _buildRows();

    if (_stage != _BurstStage.idle) {
      // 粉尘序列正在跑，别插进来改 _rows —— 否则 AnimatedList 的内部计数
      // 和我们分步 remove/insert 的节奏对不上，会出现重复行。
      _deferredNext = next;
      return;
    }

    final completionKey = _completionKey(next);
    if (completionKey != null) {
      _startBurst(next, completionKey);
      return;
    }

    if (_sameKeys(next)) {
      for (var i = 0; i < next.length; i++) {
        _rows[i] = next[i];
      }
      return;
    }
    _reconcile(next);
  }

  /// 这次更新里，哪条是"刚勾完成"（从非完成 → 已完成）？
  ///
  /// 直接比 [_rows]（当前显示的）和 next 里每条的 state。**不能**靠 flashKey
  /// 判断——schedule_screen 的 `_toggleEntry` 是先 await 落库+重载、再 setState
  /// flashKey，两次更新分开，数据先到那一帧 flashKey 还是 null。取消勾选
  /// （done → 非 done）不匹配，走普通收展，不播粉尘。
  String? _completionKey(List<_DayRow> next) {
    for (final row in next) {
      if (row is! _EntryRow || row.state != EntryState.done) continue;
      // 课程下课后由时间推进自动变成 done（2026-11-26），不是用户勾选的，
      // 不能播粉尘。只有事件/任务的手动勾选才该炸一下。
      if (row.entry.type == EntryType.course) continue;
      final before = _stateOf(_rows, row.entry.key);
      if (before != null && before != EntryState.done) return row.entry.key;
    }
    return null;
  }

  EntryState? _stateOf(List<_DayRow> rows, String entryKey) {
    for (final row in rows) {
      if (row is _EntryRow && row.entry.key == entryKey) return row.state;
    }
    return null;
  }

  bool _sameKeys(List<_DayRow> next) {
    if (next.length != _rows.length) return false;
    for (var i = 0; i < next.length; i++) {
      if (next[i].key != _rows[i].key) return false;
    }
    return true;
  }

  // ---------------------------------------------------------------------
  // 四阶段粉尘序列
  // ---------------------------------------------------------------------

  void _startBurst(List<_DayRow> next, String entryKey) {
    _pendingNext = next;
    _burstEntryKey = entryKey;
    _setStage(_BurstStage.dissipating);

    // ① 散开：源行 progress 0→1，shader 把卡片本身碎成粉尘飞走。
    //    这一帧只切阶段并启动动画，列表结构一个不动，下方完全静止。
    _dissolve.duration = kBurstDissipate;
    _dissolve.forward(from: 0);

    _stageTimer = Timer(kBurstDissipate, () {
      if (!mounted) return;
      // ② 收起：源行此时 progress=1（已不可见），removeItem 只收高度，
      //    下方滑上来补位。目标行先不插入 —— "散完才重组"的关键空档。
      _setStage(_BurstStage.collapsing);
      _removePhase(_pendingNext!);

      _stageTimer = Timer(kBurstCollapse, () {
        if (!mounted) return;
        // ③ 重组：插入目标行，progress 1→0，粉尘在下方聚成卡片。
        _setStage(_BurstStage.reassembling);
        _insertPhase(_pendingNext!);
        _dissolve.duration = kBurstReassemble;
        _dissolve.reverse(from: 1);

        _stageTimer = Timer(kBurstReassemble, () {
          if (!mounted) return;
          // ④ 高亮：粉尘聚完，闪一下淡黄。
          _setStage(_BurstStage.flashing);

          _stageTimer = Timer(kBurstFlash, () {
            if (!mounted) return;
            _finishBurst();
          });
        });
      });
    });
  }

  void _setStage(_BurstStage stage) {
    if (!mounted) return;
    setState(() => _stage = stage);
  }

  void _finishBurst() {
    final deferred = _deferredNext;
    _burstEntryKey = null;
    _pendingNext = null;
    _deferredNext = null;
    _stage = _BurstStage.idle;

    if (deferred != null && !_sameKeys(deferred)) {
      _reconcile(deferred);
    } else {
      setState(() {}); // 让 flash 那层 ColoredBox 撤掉
    }
  }

  /// 阶段②专用：向 next 收敛，但**只做删除**，新增的行留到阶段③。
  void _removePhase(List<_DayRow> next) {
    final state = _listKey.currentState;
    final stable = _stableKeys(_rows, next);
    // 源行必须收起，哪怕 LCS 把它判成"位置不变"也要强制剔除。
    // 勾当天最后一条时 [a,b,c] → [a,b,已完成头,c] 的 LCS 是 [a,b,c]，
    // c 被当成 stable；不剔除它就不会 remove，也播不出重组。
    if (_burstEntryKey != null) {
      stable.remove('entry_$_burstEntryKey');
    }
    for (var i = _rows.length - 1; i >= 0; i--) {
      final row = _rows[i];
      if (stable.contains(row.key)) continue;
      _rows.removeAt(i);
      state?.removeItem(
        i,
        (context, animation) => _buildRow(row, animation),
        duration: kBurstCollapse,
      );
    }
  }

  /// 阶段③专用：把剩下的行插进来（目标行带粉尘重组）。
  void _insertPhase(List<_DayRow> next) {
    final state = _listKey.currentState;
    for (var i = 0; i < next.length; i++) {
      if (i < _rows.length && _rows[i].key == next[i].key) {
        _rows[i] = next[i];
        continue;
      }
      _rows.insert(i, next[i]);
      state?.insertItem(i, duration: kBurstReassemble);
    }
  }

  // ---------------------------------------------------------------------
  // 普通重排（取消勾选、时间推移等）
  // ---------------------------------------------------------------------

  void _reconcile(List<_DayRow> next) {
    final state = _listKey.currentState;
    final stable = _stableKeys(_rows, next);

    for (var i = _rows.length - 1; i >= 0; i--) {
      final row = _rows[i];
      if (stable.contains(row.key)) continue;
      _rows.removeAt(i);
      state?.removeItem(
        i,
        (context, animation) => _buildRow(row, animation),
        duration: kRowMoveDuration,
      );
    }

    for (var i = 0; i < next.length; i++) {
      if (i < _rows.length && _rows[i].key == next[i].key) {
        _rows[i] = next[i];
        continue;
      }
      _rows.insert(i, next[i]);
      state?.insertItem(i, duration: kRowMoveDuration);
    }
  }

  /// 新旧列表的最长公共子序列（按 key），这批行位置没变，不播动画。
  Set<String> _stableKeys(List<_DayRow> oldRows, List<_DayRow> next) {
    final n = oldRows.length;
    final m = next.length;
    final dp = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
    for (var i = n - 1; i >= 0; i--) {
      for (var j = m - 1; j >= 0; j--) {
        dp[i][j] = oldRows[i].key == next[j].key
            ? dp[i + 1][j + 1] + 1
            : (dp[i + 1][j] >= dp[i][j + 1] ? dp[i + 1][j] : dp[i][j + 1]);
      }
    }
    final stable = <String>{};
    var i = 0;
    var j = 0;
    while (i < n && j < m) {
      if (oldRows[i].key == next[j].key) {
        stable.add(oldRows[i].key);
        i++;
        j++;
      } else if (dp[i + 1][j] >= dp[i][j + 1]) {
        i++;
      } else {
        j++;
      }
    }
    return stable;
  }

  List<_DayRow> _buildRows() {
    final rows = <_DayRow>[];
    final sections = widget.sections;

    for (final entry in sections.normal) {
      rows.add(_EntryRow(entry, EntryState.normal));
    }

    if (sections.overdue.isNotEmpty) {
      rows.add(_HeaderRow('overdue', '已过期', sections.overdue.length));
      for (final entry in sections.overdue) {
        rows.add(_EntryRow(entry, EntryState.overdue));
      }
    }

    if (sections.done.isNotEmpty) {
      final all = sections.done;
      final needsFold = all.length > widget.foldThreshold;
      final shown = needsFold && !widget.doneExpanded
          ? all.sublist(all.length - widget.foldThreshold)
          : all;
      rows.add(_HeaderRow('done', '已完成', all.length));
      if (needsFold) {
        rows.add(_FoldRow(all.length - shown.length, widget.doneExpanded));
      }
      for (final entry in shown) {
        rows.add(_EntryRow(entry, EntryState.done));
      }
    }

    return rows;
  }

  /// 当前阶段下，这条该拿到什么 progress。
  ///
  /// ① 散开：源行 0→1；② 收起：源行保持 1（粉尘已散尽，不可见）；
  /// ③ 重组：目标行 1→0；④ 高亮及 idle：不套 shader。
  ///
  /// ⚠ 收起阶段**必须**保持 1，不能返回 null：否则源行的 shader 被摘掉，
  /// 卡片立刻变回完整不透明的普通卡片"复活"，再被 AnimatedList 的
  /// Opacity(t) 淡出动画隐去 —— 观感就是"粉末散了→卡片又冒出来→再淡出"。
  /// 保持 progress=1 时 DisintegrateEffect 内部是 Opacity(0)，卡片始终不可见，
  /// 收起只需 heightFactor 把空高度收掉、让下方补位。
  double? _dissolveProgressFor(String entryKey) {
    if (_burstEntryKey != entryKey) return null;
    return switch (_stage) {
      _BurstStage.dissipating => _progress,
      _BurstStage.collapsing => 1.0,
      _BurstStage.reassembling => _progress,
      _ => null,
    };
  }

  /// 种子用 entry.key 的稳定哈希，散开和重组两处一致，像同一批粉尘。
  double _seedFor(String entryKey) {
    var h = 7;
    for (final c in entryKey.codeUnits) {
      h = (h * 31 + c) & 0x7FFFFFFF;
    }
    return (h % 10000).toDouble();
  }

  /// 高亮只在"聚拢演完"那一小段才闪。idle 阶段（取消勾选等）按 flashKey 闪。
  bool _isFlashTarget(_DayRow row) {
    if (row is! _EntryRow) return false;
    if (_stage == _BurstStage.idle) {
      return widget.flashKey == row.entry.key;
    }
    return _stage == _BurstStage.flashing && _burstEntryKey == row.entry.key;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedList(
      key: _listKey,
      initialItemCount: _rows.length,
      itemBuilder: (context, index, animation) {
        if (index >= _rows.length) return const SizedBox.shrink();
        return _buildRow(_rows[index], animation);
      },
    );
  }

  Widget _buildRow(_DayRow row, Animation<double> animation) {
    if (identical(animation, kAlwaysCompleteAnimation)) {
      return _content(row, flashing: _isFlashTarget(row));
    }

    // 重组阶段的目标行：高度直接到位，淡入交给 shader 的 progress —— 否则
    // 高度展开和粉尘聚拢叠在一起像"长出来"。它在列表末尾，不顶动别的行。
    if (_stage == _BurstStage.reassembling &&
        row is _EntryRow &&
        _burstEntryKey == row.entry.key) {
      return _content(row, flashing: false);
    }

    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final t = Curves.easeOutCubic.transform(
          animation.value.clamp(0.0, 1.0),
        );
        return ClipRect(
          child: Align(
            alignment: Alignment.topCenter,
            heightFactor: t,
            child: Opacity(
              opacity: t,
              child: _content(
                row,
                flashing: animation.isCompleted && _isFlashTarget(row),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _content(_DayRow row, {required bool flashing}) {
    return switch (row) {
      _EntryRow(:final entry, :final state) => KeyedSubtree(
        key: Key('tile_${entry.key}'),
        child: TimelineItem(
          entry: entry,
          state: state,
          courseColors: widget.courseColors,
          flash: flashing,
          dissolveProgress: _dissolveProgressFor(entry.key),
          dissolveDrift: kDissolveDrift,
          dissolveSeed: _seedFor(entry.key),
          onToggleTask: widget.onToggleEntry,
          onTap: widget.onOpenEntry,
        ),
      ),
      _HeaderRow(:final section, :final label, :final count) =>
        _header(section, label, count),
      _FoldRow(:final hidden, :final expanded) => _foldBar(hidden, expanded),
    };
  }

  Widget _header(String section, String label, int count) {
    return Padding(
      key: Key('section_$section'),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade600,
            ),
          ),
          const SizedBox(width: 6),
          Text('$count',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
          const SizedBox(width: 8),
          Expanded(child: Divider(color: Colors.grey.shade300, height: 1)),
        ],
      ),
    );
  }

  Widget _foldBar(int hidden, bool expanded) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: TextButton(
        key: const Key('done_fold'),
        onPressed: widget.onToggleFold,
        child: Text(
          expanded ? '收起' : '展开更早的 $hidden 条',
          style: const TextStyle(fontSize: 12),
        ),
      ),
    );
  }
}
