// 经期宝数据导出工具
// 支持 CSV、TXT、DOCX 三种格式导出
import 'dart:convert';
import 'dart:io';

import 'package:docs_gee/docs_gee.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'period_model.dart';

/// 导出格式枚举
enum ExportFormat {
  csv('CSV', 'csv', '纯文本表格'),
  xls('XLS', 'xls', '推荐·居中对齐'),
  txt('TXT', 'txt', '纯文本报告'),
  docx('DOCX', 'docx', 'Word文档');

  final String label;
  final String extension;
  final String badge;

  const ExportFormat(this.label, this.extension, this.badge);
}

/// 经期宝数据导出器
class PeriodDataExporter {
  /// 导出数据到指定格式，返回文件路径
  static Future<String> export({
    required List<PeriodRecord> records,
    required List<OvulationMark> ovulationMarks,
    required PeriodSettings settings,
    required ExportFormat format,
  }) async {
    final now = DateTime.now();
    final timestamp =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}';
    final fileName = '经期宝数据_$timestamp.${format.extension}';

    final directory = await getApplicationDocumentsDirectory();
    final filePath = '${directory.path}/$fileName';

    switch (format) {
      case ExportFormat.csv:
        await _exportCSV(records, ovulationMarks, settings, filePath);
        break;
      case ExportFormat.xls:
        await _exportXLS(records, ovulationMarks, settings, filePath);
        break;
      case ExportFormat.txt:
        await _exportTXT(records, ovulationMarks, settings, filePath);
        break;
      case ExportFormat.docx:
        await _exportDOCX(records, ovulationMarks, settings, filePath);
        break;
    }

    return filePath;
  }

  /// 导出为 CSV 格式
  static Future<void> _exportCSV(
    List<PeriodRecord> records,
    List<OvulationMark> ovulationMarks,
    PeriodSettings settings,
    String filePath,
  ) async {
    final buffer = StringBuffer();

    // CSV 头部（使用 BOM 确保 Excel 正确识别 UTF-8 中文）
    buffer.write('\uFEFF');

    // 基本信息
    buffer.writeln('经期宝数据导出');
    buffer.writeln('导出时间,${_formatDateTime(DateTime.now())}');
    buffer.writeln('');

    // 设置信息
    buffer.writeln('== 参数设置 ==');
    buffer.writeln('参数,值');
    buffer.writeln('周期天数,${settings.averageCycleLength}');
    buffer.writeln('经期天数,${settings.averagePeriodLength}');
    buffer.writeln('黄体期天数,${settings.lutealPhaseLength}');
    buffer.writeln('智能模式,${settings.smartMode ? "开启" : "关闭"}');
    buffer.writeln('');

    // 经期记录
    buffer.writeln('== 经期记录 ==');
    buffer.writeln('序号,开始日期,结束日期,记录模式,持续天数,经量等级,症状,备注');
    for (int i = 0; i < records.length; i++) {
      final r = records[i];
      buffer.writeln(
        '${i + 1},'
        '${_formatDate(r.startDate)},'
        '${r.endDate != null ? _formatDate(r.endDate!) : "进行中"},'
        '${r.mode == "precise" ? "精确" : "模糊"},'
        '${r.durationDays},'
        '${_flowLevelText(r.flowLevel)},'
        '"${r.symptoms.join("、")}",'
        '"${r.notes}"',
      );
    }
    buffer.writeln('');

    // 排卵日标记
    buffer.writeln('== 排卵日标记 ==');
    buffer.writeln('序号,日期,备注');
    for (int i = 0; i < ovulationMarks.length; i++) {
      final m = ovulationMarks[i];
      buffer.writeln(
        '${i + 1},'
        '${_formatDate(m.date)},'
        '"${m.notes}"',
      );
    }

    final file = File(filePath);
    await file.writeAsString(buffer.toString(), encoding: utf8);
  }

  /// 导出为 XLS 格式（使用 HTML 表格，Excel 可直接打开并支持居中对齐和自适应列宽）
  static Future<void> _exportXLS(
    List<PeriodRecord> records,
    List<OvulationMark> ovulationMarks,
    PeriodSettings settings,
    String filePath,
  ) async {
    final buffer = StringBuffer();

    buffer.write('''
<html xmlns:o="urn:schemas-microsoft-com:office:office"
      xmlns:x="urn:schemas-microsoft-com:office:excel"
      xmlns="http://www.w3.org/TR/REC-html40">
<head>
<meta charset="UTF-8">
<!--[if gte mso 9]>
<xml>
  <x:ExcelWorkbook>
    <x:ExcelWorksheets>
      <x:ExcelWorksheet>
        <x:Name>经期宝数据</x:Name>
        <x:WorksheetOptions>
          <x:DisplayGridlines/>
        </x:WorksheetOptions>
      </x:ExcelWorksheet>
    </x:ExcelWorksheets>
  </x:ExcelWorkbook>
</xml>
<![endif]-->
<style>
  /* 全局样式：所有单元格默认居中对齐 */
  td, th {
    text-align: center;
    vertical-align: middle;
    padding: 6px 12px;
    border: 1px solid #d0d0d0;
    white-space: nowrap;
    font-size: 12pt;
    font-family: "Microsoft YaHei", "SimHei", sans-serif;
  }
  /* 表头样式 */
  th {
    background-color: #4CAF50;
    color: white;
    font-weight: bold;
  }
  /* 标题样式 */
  .title {
    font-size: 18pt;
    font-weight: bold;
    text-align: center;
    color: #333;
    padding: 16px 0;
  }
  /* 副标题样式 */
  .subtitle {
    font-size: 14pt;
    font-weight: bold;
    text-align: center;
    color: #666;
    padding: 8px 0;
  }
  /* 分区标题 */
  .section-title {
    font-size: 14pt;
    font-weight: bold;
    background-color: #E8F5E9;
    color: #2E7D32;
    text-align: center;
    padding: 10px 0;
  }
  /* 交替行颜色 */
  .row-alt {
    background-color: #F5F5F5;
  }
  /* 空行间距 */
  .spacer {
    height: 16px;
    border: none;
  }
</style>
</head>
<body>
''');

    // 标题
    buffer.writeln('<table>');
    buffer.writeln('<tr><td class="title">经期宝数据导出</td></tr>');
    buffer.writeln(
        '<tr><td class="subtitle">导出时间：${_formatDateTime(DateTime.now())}</td></tr>');
    buffer.writeln('<tr><td class="spacer"></td></tr>');
    buffer.writeln('</table>');

    // 参数设置表格
    buffer.writeln('<table>');
    buffer.writeln('<tr><td class="section-title" colspan="2">参数设置</td></tr>');
    buffer.writeln('<tr><th>参数</th><th>值</th></tr>');
    buffer.writeln(
        '<tr><td>周期天数</td><td>${settings.averageCycleLength} 天</td></tr>');
    buffer.writeln(
        '<tr><td>经期天数</td><td>${settings.averagePeriodLength} 天</td></tr>');
    buffer.writeln(
        '<tr><td>黄体期天数</td><td>${settings.lutealPhaseLength} 天</td></tr>');
    buffer.writeln(
        '<tr><td>智能模式</td><td>${settings.smartMode ? "开启" : "关闭"}</td></tr>');
    buffer.writeln('</table>');
    buffer.writeln('<table><tr><td class="spacer"></td></tr></table>');

    // 经期记录表格
    buffer.writeln('<table>');
    buffer.writeln(
        '<tr><td class="section-title" colspan="8">经期记录（共 ${records.length} 条）</td></tr>');
    buffer.writeln('<tr>'
        '<th>序号</th>'
        '<th>开始日期</th>'
        '<th>结束日期</th>'
        '<th>记录模式</th>'
        '<th>持续天数</th>'
        '<th>经量等级</th>'
        '<th>症状</th>'
        '<th>备注</th>'
        '</tr>');

    for (int i = 0; i < records.length; i++) {
      final r = records[i];
      final rowClass = i % 2 == 0 ? '' : ' class="row-alt"';
      buffer.writeln('<tr$rowClass>'
          '<td>${i + 1}</td>'
          '<td>${_formatDate(r.startDate)}</td>'
          '<td>${r.endDate != null ? _formatDate(r.endDate!) : "进行中"}</td>'
          '<td>${r.mode == "precise" ? "精确" : "模糊"}</td>'
          '<td>${r.durationDays} 天</td>'
          '<td>${_flowLevelText(r.flowLevel)}</td>'
          '<td>${r.symptoms.isNotEmpty ? r.symptoms.join("、") : "-"}</td>'
          '<td>${r.notes.isNotEmpty ? r.notes : "-"}</td>'
          '</tr>');
    }
    buffer.writeln('</table>');
    buffer.writeln('<table><tr><td class="spacer"></td></tr></table>');

    // 排卵日标记表格
    buffer.writeln('<table>');
    buffer.writeln(
        '<tr><td class="section-title" colspan="3">排卵日标记（共 ${ovulationMarks.length} 条）</td></tr>');
    buffer.writeln(
        '<tr><th>序号</th><th>日期</th><th>备注</th></tr>');

    for (int i = 0; i < ovulationMarks.length; i++) {
      final m = ovulationMarks[i];
      final rowClass = i % 2 == 0 ? '' : ' class="row-alt"';
      buffer.writeln('<tr$rowClass>'
          '<td>${i + 1}</td>'
          '<td>${_formatDate(m.date)}</td>'
          '<td>${m.notes.isNotEmpty ? m.notes : "-"}</td>'
          '</tr>');
    }
    buffer.writeln('</table>');

    buffer.writeln('</body></html>');

    final file = File(filePath);
    await file.writeAsString(buffer.toString(), encoding: utf8);
  }

  /// 导出为 TXT 格式
  static Future<void> _exportTXT(
    List<PeriodRecord> records,
    List<OvulationMark> ovulationMarks,
    PeriodSettings settings,
    String filePath,
  ) async {
    final buffer = StringBuffer();

    buffer.writeln('========================================');
    buffer.writeln('         经期宝数据导出报告');
    buffer.writeln('========================================');
    buffer.writeln('导出时间：${_formatDateTime(DateTime.now())}');
    buffer.writeln('');

    // 参数设置
    buffer.writeln('----------------------------------------');
    buffer.writeln('【参数设置】');
    buffer.writeln('----------------------------------------');
    buffer.writeln('  周期天数：${settings.averageCycleLength} 天');
    buffer.writeln('  经期天数：${settings.averagePeriodLength} 天');
    buffer.writeln('  黄体期天数：${settings.lutealPhaseLength} 天');
    buffer.writeln('  智能模式：${settings.smartMode ? "开启" : "关闭"}');
    buffer.writeln('');

    // 经期记录
    buffer.writeln('----------------------------------------');
    buffer.writeln('【经期记录】（共 ${records.length} 条）');
    buffer.writeln('----------------------------------------');
    for (int i = 0; i < records.length; i++) {
      final r = records[i];
      buffer.writeln('');
      buffer.writeln('  记录 ${i + 1}：');
      buffer.writeln('    开始日期：${_formatDate(r.startDate)}');
      buffer.writeln('    记录模式：${r.mode == "precise" ? "精确" : "模糊"}');
      buffer.writeln(
          '    结束日期：${r.endDate != null ? _formatDate(r.endDate!) : "进行中"}');
      buffer.writeln('    持续天数：${r.durationDays} 天');
      buffer.writeln('    经量等级：${_flowLevelText(r.flowLevel)}');
      if (r.symptoms.isNotEmpty) {
        buffer.writeln('    症状：${r.symptoms.join("、")}');
      }
      if (r.notes.isNotEmpty) {
        buffer.writeln('    备注：${r.notes}');
      }
    }
    buffer.writeln('');

    // 排卵日标记
    buffer.writeln('----------------------------------------');
    buffer.writeln('【排卵日标记】（共 ${ovulationMarks.length} 条）');
    buffer.writeln('----------------------------------------');
    for (int i = 0; i < ovulationMarks.length; i++) {
      final m = ovulationMarks[i];
      buffer.writeln('');
      buffer.writeln('  标记 ${i + 1}：');
      buffer.writeln('    日期：${_formatDate(m.date)}');
      if (m.notes.isNotEmpty) {
        buffer.writeln('    备注：${m.notes}');
      }
    }
    buffer.writeln('');
    buffer.writeln('========================================');
    buffer.writeln('              导出完毕');
    buffer.writeln('========================================');

    final file = File(filePath);
    await file.writeAsString(buffer.toString(), encoding: utf8);
  }

  /// 导出为 DOCX 格式
  static Future<void> _exportDOCX(
    List<PeriodRecord> records,
    List<OvulationMark> ovulationMarks,
    PeriodSettings settings,
    String filePath,
  ) async {
    final doc = Document(
      title: '经期宝数据导出报告',
      author: '经期宝',
    );

    // 标题
    doc.addParagraph(Paragraph.heading('经期宝数据导出报告', level: 1));
    doc.addParagraph(Paragraph.text('导出时间：${_formatDateTime(DateTime.now())}'));

    // 参数设置
    doc.addParagraph(Paragraph.heading('参数设置', level: 2));
    doc.addTable(Table(
      borders: TableBorders.all(),
      rows: [
        TableRow(cells: [
          TableCell.text('参数', backgroundColor: 'E8E8E8'),
          TableCell.text('值', backgroundColor: 'E8E8E8'),
        ]),
        TableRow(cells: [
          TableCell.text('周期天数'),
          TableCell.text('${settings.averageCycleLength} 天'),
        ]),
        TableRow(cells: [
          TableCell.text('经期天数'),
          TableCell.text('${settings.averagePeriodLength} 天'),
        ]),
        TableRow(cells: [
          TableCell.text('黄体期天数'),
          TableCell.text('${settings.lutealPhaseLength} 天'),
        ]),
        TableRow(cells: [
          TableCell.text('智能模式'),
          TableCell.text(settings.smartMode ? '开启' : '关闭'),
        ]),
      ],
    ));

    // 经期记录
    doc.addParagraph(Paragraph.heading('经期记录（共 ${records.length} 条）', level: 2));

    if (records.isNotEmpty) {
      // 经期记录表格
      final recordRows = <TableRow>[
        TableRow(cells: [
          TableCell.text('序号', backgroundColor: 'E8E8E8'),
          TableCell.text('开始日期', backgroundColor: 'E8E8E8'),
          TableCell.text('结束日期', backgroundColor: 'E8E8E8'),
          TableCell.text('模式', backgroundColor: 'E8E8E8'),
          TableCell.text('天数', backgroundColor: 'E8E8E8'),
          TableCell.text('经量', backgroundColor: 'E8E8E8'),
          TableCell.text('症状', backgroundColor: 'E8E8E8'),
          TableCell.text('备注', backgroundColor: 'E8E8E8'),
        ]),
      ];
      for (int i = 0; i < records.length; i++) {
        final r = records[i];
        recordRows.add(TableRow(cells: [
          TableCell.text('${i + 1}'),
          TableCell.text(_formatDate(r.startDate)),
          TableCell.text(r.endDate != null ? _formatDate(r.endDate!) : '进行中'),
          TableCell.text(r.mode == 'precise' ? '精确' : '模糊'),
          TableCell.text('${r.durationDays}'),
          TableCell.text(_flowLevelText(r.flowLevel)),
          TableCell.text(r.symptoms.join('、')),
          TableCell.text(r.notes),
        ]));
      }
      doc.addTable(Table(borders: TableBorders.all(), rows: recordRows));
    } else {
      doc.addParagraph(Paragraph.text('暂无记录'));
    }

    // 排卵日标记
    doc.addParagraph(
        Paragraph.heading('排卵日标记（共 ${ovulationMarks.length} 条）', level: 2));

    if (ovulationMarks.isNotEmpty) {
      final markRows = <TableRow>[
        TableRow(cells: [
          TableCell.text('序号', backgroundColor: 'E8E8E8'),
          TableCell.text('日期', backgroundColor: 'E8E8E8'),
          TableCell.text('备注', backgroundColor: 'E8E8E8'),
        ]),
      ];
      for (int i = 0; i < ovulationMarks.length; i++) {
        final m = ovulationMarks[i];
        markRows.add(TableRow(cells: [
          TableCell.text('${i + 1}'),
          TableCell.text(_formatDate(m.date)),
          TableCell.text(m.notes),
        ]));
      }
      doc.addTable(Table(borders: TableBorders.all(), rows: markRows));
    } else {
      doc.addParagraph(Paragraph.text('暂无标记'));
    }

    // 生成 DOCX 文件
    final bytes = DocxGenerator().generate(doc);
    final file = File(filePath);
    await file.writeAsBytes(bytes);
  }

  /// 分享导出文件
  static Future<void> shareExport(String filePath) async {
    final file = File(filePath);
    if (await file.exists()) {
      await Share.shareXFiles([XFile(filePath)], text: '经期宝数据导出');
    }
  }

  // ============================================================
  // 辅助方法
  // ============================================================

  static String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  static String _formatDateTime(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  static String _flowLevelText(int level) {
    switch (level) {
      case 1:
        return '少';
      case 3:
        return '多';
      default:
        return '中';
    }
  }
}
