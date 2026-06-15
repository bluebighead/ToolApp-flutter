// 加解密工具页面
// 作为加解密工具大类的二级入口，展示所有加解密小工具
import 'package:flutter/material.dart';

import '../models/tool_item.dart';
import '../utils/app_logger.dart';
import '../widgets/tool_card.dart';
import 'encryptor/morse_code_page.dart';
import 'encryptor/code_transfer_page.dart';
import 'encryptor/qr_decoder_page.dart';
import 'encryptor/base64_page.dart';
import 'encryptor/hash_page.dart';
import 'encryptor/caesar_page.dart';
import 'encryptor/password_page.dart';
import 'encryptor/url_codec_page.dart';
import 'encryptor/unicode_page.dart';
import 'encryptor/radix_page.dart';
import 'encryptor/atbash_page.dart';
import 'encryptor/vigenere_page.dart';
import 'encryptor/playfair_page.dart';
import 'encryptor/affine_page.dart';
import 'encryptor/polybius_page.dart';
import 'encryptor/rail_fence_page.dart';
import 'encryptor/pigpen_page.dart';
import 'encryptor/substitution_page.dart';
import 'encryptor/hex_page.dart';
import 'encryptor/xor_page.dart';
import 'encryptor/hmac_page.dart';
import 'encryptor/aes_page.dart';
import 'encryptor/rsa_page.dart';
import 'encryptor/text_tools_page.dart';

class EncryptorPage extends StatelessWidget {
  const EncryptorPage({super.key});

  static final List<ToolItem> _ancientTools = [
    ToolItem(
      name: '摩斯电码',
      icon: Icons.signal_cellular_alt,
      color: Colors.amber,
      category: ToolCategory.geek,
      subtitle: '加解密 · 振动播放',
      pageBuilder: (_) => const MorseCodePage(),
    ),
    ToolItem(
      name: '凯撒密码',
      icon: Icons.shuffle,
      color: Color(0xFF2E7D32),
      category: ToolCategory.geek,
      subtitle: '经典位移密码',
      pageBuilder: (_) => const CaesarPage(),
    ),
    ToolItem(
      name: 'Atbash',
      icon: Icons.swap_horiz,
      color: Color(0xFF4E342E),
      category: ToolCategory.geek,
      subtitle: '字母表反转密码',
      pageBuilder: (_) => const AtbashPage(),
    ),
    ToolItem(
      name: '维吉尼亚',
      icon: Icons.keyboard,
      color: Color(0xFF283593),
      category: ToolCategory.geek,
      subtitle: '多表替换密码',
      pageBuilder: (_) => const VigenerePage(),
    ),
    ToolItem(
      name: '柏拉费',
      icon: Icons.grid_view,
      color: Color(0xFFBF360C),
      category: ToolCategory.geek,
      subtitle: '双字母分组加密',
      pageBuilder: (_) => const PlayfairPage(),
    ),
    ToolItem(
      name: '仿射密码',
      icon: Icons.calculate,
      color: Color(0xFF33691E),
      category: ToolCategory.geek,
      subtitle: '乘法+位移密码',
      pageBuilder: (_) => const AffinePage(),
    ),
    ToolItem(
      name: '波利比乌斯',
      icon: Icons.grid_on,
      color: Color(0xFF01579B),
      category: ToolCategory.geek,
      subtitle: '5×5 坐标方阵',
      pageBuilder: (_) => const PolybiusPage(),
    ),
    ToolItem(
      name: '栅栏密码',
      icon: Icons.swap_vert,
      color: Color(0xFF827717),
      category: ToolCategory.geek,
      subtitle: 'Z 字形换位加密',
      pageBuilder: (_) => const RailFencePage(),
    ),
    ToolItem(
      name: '猪圈密码',
      icon: Icons.category,
      color: Color(0xFF4A148C),
      category: ToolCategory.geek,
      subtitle: '符号替换密码',
      pageBuilder: (_) => const PigpenPage(),
    ),
    ToolItem(
      name: '简单替换',
      icon: Icons.sort,
      color: Color(0xFFE65100),
      category: ToolCategory.geek,
      subtitle: '随机字母表替换',
      pageBuilder: (_) => const SubstitutionPage(),
    ),
  ];

  static final List<ToolItem> _modernTools = [
    ToolItem(
      name: 'Base64',
      icon: Icons.code,
      color: Color(0xFF1565C0),
      category: ToolCategory.geek,
      subtitle: 'Base64 编解码',
      pageBuilder: (_) => const Base64Page(),
    ),
    ToolItem(
      name: '哈希计算',
      icon: Icons.fingerprint,
      color: Color(0xFFE65100),
      category: ToolCategory.geek,
      subtitle: 'MD5 · SHA1 · SHA256 · SHA512',
      pageBuilder: (_) => const HashPage(),
    ),
    ToolItem(
      name: '密码生成',
      icon: Icons.password,
      color: Color(0xFF6A1B9A),
      category: ToolCategory.geek,
      subtitle: '随机强密码 · 多种规则',
      pageBuilder: (_) => const PasswordPage(),
    ),
    ToolItem(
      name: 'URL 编解码',
      icon: Icons.link,
      color: Color(0xFF00838F),
      category: ToolCategory.geek,
      subtitle: 'URL 参数编解码',
      pageBuilder: (_) => const UrlCodecPage(),
    ),
    ToolItem(
      name: 'Unicode',
      icon: Icons.translate,
      color: Color(0xFFAD1457),
      category: ToolCategory.geek,
      subtitle: 'Unicode 编解码',
      pageBuilder: (_) => const UnicodePage(),
    ),
    ToolItem(
      name: '进制转换',
      icon: Icons.grid_on,
      color: Color(0xFF37474F),
      category: ToolCategory.geek,
      subtitle: '2 · 8 · 10 · 16 进制互转',
      pageBuilder: (_) => const RadixPage(),
    ),
    ToolItem(
      name: '扫码传信',
      icon: Icons.qr_code_2,
      color: Colors.teal,
      category: ToolCategory.geek,
      subtitle: '生成二维码 · 条形码',
      pageBuilder: (_) => const CodeTransferPage(),
    ),
    ToolItem(
      name: '二维码解码',
      icon: Icons.qr_code_scanner,
      color: Colors.indigo,
      category: ToolCategory.geek,
      subtitle: '图片解析 · 摄像头扫码 · 解码',
      pageBuilder: (_) => const QrDecoderPage(),
    ),
    ToolItem(
      name: 'Hex 转换',
      icon: Icons.settings_ethernet,
      color: Color(0xFF006064),
      category: ToolCategory.geek,
      subtitle: '文本 ↔ 十六进制',
      pageBuilder: (_) => const HexPage(),
    ),
    ToolItem(
      name: 'XOR 加密',
      icon: Icons.logout,
      color: Color(0xFF0097A7),
      category: ToolCategory.geek,
      subtitle: '异或加密 · 自反解密',
      pageBuilder: (_) => const XorPage(),
    ),
    ToolItem(
      name: 'HMAC',
      icon: Icons.verified_user,
      color: Color(0xFF558B2F),
      category: ToolCategory.geek,
      subtitle: '带密钥的哈希校验',
      pageBuilder: (_) => const HmacPage(),
    ),
    ToolItem(
      name: 'AES',
      icon: Icons.shield,
      color: Color(0xFF1A237E),
      category: ToolCategory.geek,
      subtitle: 'AES-128/192/256 · CBC/ECB',
      pageBuilder: (_) => const AesPage(),
    ),
    ToolItem(
      name: 'RSA',
      icon: Icons.vpn_key,
      color: Color(0xFFB71C1C),
      category: ToolCategory.geek,
      subtitle: '非对称加密 · 密钥对生成',
      pageBuilder: (_) => const RsaPage(),
    ),
    ToolItem(
      name: '文字工具箱',
      icon: Icons.text_fields,
      color: Color(0xFF4E342E),
      category: ToolCategory.geek,
      subtitle: '大小写 · 反转 · 统计',
      pageBuilder: (_) => const TextToolsPage(),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    AppLogger.d('EncryptorPage', '加解密工具页面 build');
    return Scaffold(
      appBar: AppBar(
        title: const Text('加解密工具'),
      ),
      body: CustomScrollView(
        slivers: [
          _buildSectionHeader(context, '古老加密技术', Icons.history, Colors.brown),
          _buildSliverGrid(context, _ancientTools),
          _buildSectionHeader(context, '现代加密技术', Icons.memory, Colors.blueGrey),
          _buildSliverGrid(context, _modernTools),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title, IconData icon, MaterialColor color) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
        child: Row(
          children: [
            Icon(icon, size: 20, color: color.shade700),
            const SizedBox(width: 8),
            Text(
              title,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: color.shade700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSliverGrid(BuildContext context, List<ToolItem> tools) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: 0.85,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final tool = tools[index];
            return ToolCard(
              tool: tool,
              onTap: () {
                AppLogger.i('EncryptorPage', '点击加密工具：${tool.name}');
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: tool.pageBuilder),
                );
              },
            );
          },
          childCount: tools.length,
        ),
      ),
    );
  }
}
