import 'package:flutter/material.dart';

/// V1 占位：课表周网格在 V2 实现，两阶段共用同一份数据。
class TimetableScreen extends StatelessWidget {
  const TimetableScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.grid_on, size: 56, color: Colors.grey),
          SizedBox(height: 12),
          Text('课表周网格将在 V2 实现', style: TextStyle(fontSize: 16)),
          SizedBox(height: 6),
          Text(
            '当前课程已保存在「日程」中，按周期规则展开显示。',
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }
}
