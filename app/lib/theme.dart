import 'package:flutter/material.dart';

/// 全局背景色（2026-11-23 用户要求「暖一点，象牙白」）。
///
/// 不是纯白：纯白配这块马卡龙色板会显得发冷、发灰。象牙白略带黄调，
/// 和粉色/黄色/橙色的课程块放一起更协调。
const Color ivoryBackground = Color(0xFFFFFBF3);

/// 网格线、未选中日期格这类「辅助灰」，也要跟着从冷灰换成暖灰，
/// 否则象牙白背景上会出现一片偏青的线，反而更脏。
const Color warmDivider = Color(0xFFEFE9DE);
const Color warmChip = Color(0xFFF0EADF);
