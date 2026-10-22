import 'package:flutter/material.dart';

/// In-memory layout samples only. Never persisted or treated as a real library.
class DemoBook {
  const DemoBook(
    this.title,
    this.author,
    this.cover, {
    this.ink = const Color(0xFF34473B),
  });
  final String title;
  final String author;
  final Color cover;
  final Color ink;
}

const demoBooks = [
  DemoBook('人间草木', '汪曾祺', Color(0xFFDCE3CE)),
  DemoBook('云边有个小卖部', '张嘉佳', Color(0xFFD5E4E8)),
  DemoBook('百年孤独', '加西亚·马尔克斯', Color(0xFF355646), ink: Color(0xFFF1EBD3)),
  DemoBook('我与地坛', '史铁生', Color(0xFFEAC5A1)),
  DemoBook('额尔古纳河右岸', '迟子建', Color(0xFF476D86), ink: Color(0xFFEAF0ED)),
  DemoBook('活着', '余华', Color(0xFFE3D9C3)),
  DemoBook('瓦尔登湖', '亨利·戴维·梭罗', Color(0xFF98B4AA)),
  DemoBook('三体', '刘慈欣', Color(0xFF293E50), ink: Color(0xFFE2EBEF)),
  DemoBook('月亮与六便士', '毛姆', Color(0xFFD9D2E2)),
];
