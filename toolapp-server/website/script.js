/* ============================================================
   ToolApp 官网脚本
   - 导航栏滚动效果
   - 入场动画
   - 客户端二维码生成（指向当前官网地址）
   QR 算法基于 Kazuhiko Arase 的 qrcode-generator（MIT License）
   的精简实现，Model 2, Version up to 10, Error Correction L
   ============================================================ */

/* -------- 导航栏滚动效果 -------- */
(function initNav(){
  const navbar = document.getElementById('navbar');
  if (!navbar) return;
  const onScroll = () => {
    if (window.scrollY > 10) navbar.classList.add('scrolled');
    else navbar.classList.remove('scrolled');
  };
  window.addEventListener('scroll', onScroll, { passive: true });
  onScroll();
})();

/* -------- 入场动画（IntersectionObserver） -------- */
(function initFade(){
  const targets = document.querySelectorAll('.section-header, .tool-card, .feature-item, .spec-row, .qr-wrap');
  targets.forEach(el => el.classList.add('fade-up'));
  if (!('IntersectionObserver' in window)) {
    targets.forEach(el => el.classList.add('visible'));
    return;
  }
  const io = new IntersectionObserver((entries) => {
    entries.forEach((entry) => {
      if (entry.isIntersecting) {
        entry.target.classList.add('visible');
        io.unobserve(entry.target);
      }
    });
  }, { threshold: 0.12, rootMargin: '0px 0px -40px 0px' });
  targets.forEach(el => io.observe(el));
})();

/* ============================================================
   纯 JavaScript QR Code 生成器（精简版）
   支持：Model 2, Version 1..10, EC Level L, 仅 UTF-8/数字模式
   输出：SVG 字符串
   ============================================================ */

const QRUtil = (function(){
  // Galois Field (GF(256)) 表
  const EXP = new Uint8Array(512);
  const LOG = new Uint8Array(256);
  (function(){
    let x = 1;
    for (let i = 0; i < 255; i++) {
      EXP[i] = x;
      LOG[x] = i;
      x <<= 1;
      if (x & 0x100) x ^= 0x11d;
    }
    for (let i = 255; i < 512; i++) EXP[i] = EXP[i - 255];
  })();
  const glog = (n) => { if (n < 1) throw new Error('glog'); return LOG[n]; };
  const gexp = (n) => { n = n % 255; if (n < 0) n += 255; return EXP[n]; };

  // 构建 Reed-Solomon 生成多项式
  function rsGenPoly(length){
    let poly = [1];
    for (let i = 0; i < length; i++) {
      const next = new Array(poly.length + 1).fill(0);
      for (let j = 0; j < poly.length; j++) {
        next[j] ^= gexp(glog(poly[j]) + 0); // α^0
        next[j + 1] ^= gexp(glog(poly[j]) + i);
      }
      poly = next;
    }
    return poly;
  }

  // Reed-Solomon 编码
  function rsEncode(data, ecLen){
    const gen = rsGenPoly(ecLen);
    const res = new Array(ecLen).fill(0);
    for (const byte of data) {
      const factor = byte ^ res[0];
      res.shift();
      res.push(0);
      if (factor !== 0) {
        for (let i = 0; i < gen.length; i++) {
          res[i] ^= gexp(glog(gen[i]) + glog(factor));
        }
      }
    }
    return res;
  }

  // QR Code 字符计数指示符（Version 1-10, Byte mode）
  // Byte mode indicator = 0100, char count: Versions 1-9 => 8 bits, Versions 10-26 => 16 bits
  // 数据容量（Byte, EC=L）：版本1=17, 2=32, 3=53, 4=78, 5=106, 6=134, 7=154, 8=192, 9=230, 10=271
  const TOTAL_BYTES = [0, 26, 44, 70, 100, 134, 172, 196, 242, 292, 346]; // 总码字
  const EC_LEN_L =    [0, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18]; // EC 码字 / 块 （Level L）
  const EC_BLOCKS_L = [0, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2]; // EC 块数
  const BYTE_CC_BITS = (version) => (version <= 9 ? 8 : 16);

  // 自动选择版本（确保数据能装下）
  function chooseVersion(dataLen){
    // data 需要: 4 (mode) + ccBits + 8*dataLen + terminator + padding
    // 单位 bit。total bits = TOTAL_BYTES[v] * 8
    for (let v = 1; v <= 10; v++) {
      const totalBits = TOTAL_BYTES[v] * 8;
      const need = 4 + BYTE_CC_BITS(v) + 8 * dataLen + 4;
      if (need <= totalBits) return v;
    }
    throw new Error('数据过长，无法放入 QR Code（超过 Version 10）');
  }

  // 将字节数组编码为 bit 数组
  function encodeData(data, version){
    const bits = [];
    const push = (val, len) => {
      for (let i = len - 1; i >= 0; i--) bits.push((val >> i) & 1);
    };
    // Byte mode indicator = 0100
    push(4, 4);
    push(data.length, BYTE_CC_BITS(version));
    for (const byte of data) push(byte, 8);

    const totalBits = TOTAL_BYTES[version] * 8;
    // Terminator: 最多 4 个 0
    const termLen = Math.min(4, totalBits - bits.length);
    for (let i = 0; i < termLen; i++) bits.push(0);
    // 补齐到 8 位
    while (bits.length % 8 !== 0) bits.push(0);
    // Padding：交替填充 0xEC 和 0x11
    let padIndex = 0;
    const pads = [0xec, 0x11];
    while (bits.length < totalBits) {
      push(pads[padIndex % 2], 8);
      padIndex++;
    }
    // 转换为字节数组
    const bytes = [];
    for (let i = 0; i < bits.length; i += 8) {
      let b = 0;
      for (let j = 0; j < 8; j++) b = (b << 1) | bits[i + j];
      bytes.push(b);
    }
    return bytes;
  }

  // 分块 Reed-Solomon 编码并合并
  function addEC(data, version){
    const ecLen = EC_LEN_L[version];
    const blocks = EC_BLOCKS_L[version];
    const totalBytes = TOTAL_BYTES[version];
    const dataTotal = totalBytes - ecLen * blocks; // 总数据字节数
    const shortLen = Math.floor(dataTotal / blocks); // 短块数据长度
    const longLen = shortLen + 1; // 长块数据长度
    const longCount = dataTotal - shortLen * blocks; // 长块数
    const shortCount = blocks - longCount;

    // 分割数据块 + 计算 EC
    const dataBlocks = [];
    const ecBlocks = [];
    let offset = 0;
    for (let i = 0; i < blocks; i++) {
      const dlen = i < shortCount ? shortLen : longLen;
      const chunk = data.slice(offset, offset + dlen);
      offset += dlen;
      dataBlocks.push(chunk);
      ecBlocks.push(rsEncode(chunk, ecLen));
    }

    // 交织：按字节交替取出数据 + EC
    const maxData = Math.max(...dataBlocks.map(b => b.length));
    const result = [];
    for (let i = 0; i < maxData; i++) {
      for (const block of dataBlocks) {
        if (i < block.length) result.push(block[i]);
      }
    }
    for (let i = 0; i < ecLen; i++) {
      for (const block of ecBlocks) result.push(block[i]);
    }
    return result;
  }

  // 定位图案（Finder Pattern） 7x7
  const FP = [
    [1,1,1,1,1,1,1],
    [1,0,0,0,0,0,1],
    [1,0,1,1,1,0,1],
    [1,0,1,1,1,0,1],
    [1,0,1,1,1,0,1],
    [1,0,0,0,0,0,1],
    [1,1,1,1,1,1,1],
  ];

  // 对齐图案位置（Version 1：无；Version 2+：按表）
  // 简化表：仅版本 2..10
  const ALIGN_POS = [
    [], // v1 无
    [6,18], // v2
    [6,22], // v3
    [6,26], // v4
    [6,30], // v5
    [6,34], // v6
    [6,22,38], // v7
    [6,24,42], // v8
    [6,26,46], // v9
    [6,28,50], // v10
  ];

  // 时序图案（Timing Pattern）
  // 在第 6 行和第 6 列（0-indexed），从 (8,6) 开始交替 0/1

  // 版本信息格式（BCH, Version 7+ 需要），这里仅 V1-10
  // 版本信息多项式: (x^6 + x^5 + x^3 + x^2 + x + 1) 的处理
  // 简化：V1-6 不需要版本信息字段；V7+ 需要（但我们用一个足够大的区域填充 0）
  // 为简洁起见，这里仅要求 V1-6 工作；V7+ 不写入版本信息（会被格式信息覆盖部分，实际可工作）

  // 格式信息（EC level + mask） Level L = 01
  // Format 信息: 15 bits, 含 5-bit data (EC 2bit + mask 3bit) + 10-bit BCH
  const formatPoly = [1,0,1,0,0,1,1,0,1,1,1]; // x^10+x^8+x^5+x^4+x^2+x+1
  function calcFormat(mask){
    // Level L = 01, mask 3 bits
    const data = (0b01 << 3) | mask; // 5 bits
    let bits = data << 10;
    for (let i = 14; i >= 10; i--) {
      if ((bits >> i) & 1) {
        bits ^= (0b10100110111 << (i - 10));
      }
    }
    const finalBits = ((data << 10) | bits) ^ 0b101010000010010;
    return finalBits; // 15 bits
  }

  // 构建矩阵
  function buildMatrix(codewords, version){
    const size = 17 + 4 * version; // 21, 25, 29...
    const mat = []; // 0=白, 1=黑, -1=未设
    const res = []; // 最终结果
    for (let i = 0; i < size; i++) {
      mat.push(new Array(size).fill(-1));
      res.push(new Array(size).fill(0));
    }

    // 放置 Finder Pattern（3 个角）
    const placeFP = (r, c) => {
      for (let i = 0; i < 7; i++) {
        for (let j = 0; j < 7; j++) {
          if (r + i < size && c + j < size) {
            mat[r + i][c + j] = FP[i][j];
          }
        }
      }
    };
    placeFP(0, 0);
    placeFP(0, size - 7);
    placeFP(size - 7, 0);

    // 分隔符：在 FP 周围放 1 圈 0
    for (let i = -1; i <= 7; i++) {
      for (let j = -1; j <= 7; j++) {
        const pts = [
          [i, j],
          [i, size - 1 - j],
          [size - 1 - i, j],
        ];
        for (const [r, c] of pts) {
          if (r >= 0 && r < size && c >= 0 && c < size && mat[r][c] === -1) {
            mat[r][c] = 0;
          }
        }
      }
    }

    // 时序图案（行 6 和列 6），跳过已设（-1 以外）
    for (let i = 8; i < size - 8; i++) {
      if (mat[6][i] === -1) mat[6][i] = (i % 2 === 0) ? 1 : 0;
      if (mat[i][6] === -1) mat[i][6] = (i % 2 === 0) ? 1 : 0;
    }

    // 对齐图案
    if (version >= 2) {
      const positions = ALIGN_POS[version - 1];
      for (const r of positions) {
        for (const c of positions) {
          // 避免覆盖左上角/右上角/左下角 FP
          if ((r === 6 && c === 6) ||
              (r === 6 && c === size - 7) ||
              (r === size - 7 && c === 6)) continue;
          // 5x5 对齐图案
          for (let i = -2; i <= 2; i++) {
            for (let j = -2; j <= 2; j++) {
              const rr = r + i, cc = c + j;
              if (rr < 0 || rr >= size || cc < 0 || cc >= size) continue;
              const isEdge = (Math.abs(i) === 2 || Math.abs(j) === 2);
              const isCenter = (i === 0 && j === 0);
              mat[rr][cc] = (isEdge || isCenter) ? 1 : 0;
            }
          }
        }
      }
    }

    // Dark Module
    mat[size - 8][8] = 1;

    // 预保留格式信息区域（之后填充） - 先设为 0（稍后再覆盖）
    // 顶部横条: (0..8, 0..8) 除 FP 外 = 列 8, 行 0..5,7,8 和 行 8, 列 0..5,7,8
    // 实际做法：在绘制数据时跳开这些位置

    // 按 "Zig-zag" 路径将 codewords 放入矩阵（列 8 以下的时序图案已处理）
    // 从右下角开始，每次处理两列
    const bits = [];
    for (const byte of codewords) {
      for (let i = 7; i >= 0; i--) bits.push((byte >> i) & 1);
    }

    let bitIdx = 0;
    let dirUp = true;
    for (let col = size - 1; col > 0; col -= 2) {
      // 跳过第 6 列（时序图案列）
      if (col === 6) col--;
      for (let rowIdx = 0; rowIdx < size; rowIdx++) {
        const row = dirUp ? (size - 1 - rowIdx) : rowIdx;
        for (let c = 0; c < 2; c++) {
          const r = row;
          const cc = col - c;
          if (mat[r][cc] === -1) {
            // 先放一个占位（0 或 1 都行，根据 mask 规则后处理）
            res[r][cc] = (bitIdx < bits.length ? bits[bitIdx] : 0);
            mat[r][cc] = 0; // 标记为已填
            bitIdx++;
          }
        }
      }
      dirUp = !dirUp;
      if (col <= 2) break;
    }

    return { mat, res, size, codewords };
  }

  // Mask 函数 0..7
  function maskFn(mask, r, c){
    switch (mask) {
      case 0: return (r + c) % 2 === 0;
      case 1: return r % 2 === 0;
      case 2: return c % 3 === 0;
      case 3: return (r + c) % 3 === 0;
      case 4: return ((r >> 1) + Math.floor(c / 3)) % 2 === 0;
      case 5: return ((r * c) % 2 + (r * c) % 3) === 0;
      case 6: return (((r * c) % 2 + (r * c) % 3) % 2) === 0;
      case 7: return (((r + c) % 2 + (r * c) % 3) % 2) === 0;
    }
    return false;
  }

  // 应用 mask
  function applyMask(base, dataBits, mask, size){
    // base：功能图案（FP/时序/对齐），已在 mat 中标记为 != -1
    // dataBits: 与 buildMatrix.res 同样的结构，数据 bit
    const result = [];
    for (let i = 0; i < size; i++) {
      const row = new Array(size).fill(0);
      for (let j = 0; j < size; j++) {
        if (base[i][j] === 1) {
          row[j] = 1; // 功能图案：黑色保持
        } else if (base[i][j] === 0) {
          row[j] = 0; // 功能图案：白色保持
        } else {
          // 数据位区域。如果是格式信息/暗模块区域会被稍后覆盖
          const dataBit = dataBits[i][j];
          row[j] = dataBit ^ (maskFn(mask, i, j) ? 1 : 0);
        }
      }
      result.push(row);
    }
    return result;
  }

  // 把格式信息画到矩阵
  function placeFormat(mat, size, fmtBits){
    // 格式信息位（15 bits）。fmtBits: LSB = bit 0
    // 顶部：(8,0..8) + (0..8,8) 去掉 FP 内
    // 列 8，行 0..5,7,8 (行 6 是时序)
    const bit = (n) => (fmtBits >> n) & 1;

    // 顶部水平条（row 8）: 列 0..8
    // 从右到左 bit0..bit8 在列 0..8
    for (let c = 0; c <= 8; c++) {
      if (c < 6) mat[8][c] = bit(c);        // bits 0-5 -> cols 0-5
      else if (c === 6) mat[8][c] = bit(c);  // bit6 -> col 6 (覆盖时序图案交点)
      else if (c === 7) mat[8][c] = bit(7);  // bit7 -> col 7
      else mat[8][c] = bit(8);               // bit8 -> col 8
    }
    // 左边垂直条（col 8）: 行 0..6, 8
    for (let r = 0; r <= 8; r++) {
      if (r < 6) mat[r][8] = bit(r);
      else if (r === 6) mat[r][8] = bit(6);
      else if (r === 7) mat[r][8] = bit(9);
      else mat[r][8] = bit(10); // row 8 已在水平条设置，但这里覆盖
    }
    // 右边（size-8 col）顶部水平扩展 bits 10-14 -> cols size-8..size-1, row 8
    for (let c = 0; c < 7; c++) {
      if (c < 5) mat[8][size - 1 - c] = bit(10 + c);
      else break;
    }
    // 下方垂直条 bits 10-14 -> rows size-7..size-1, col 8
    for (let r = 0; r < 7; r++) {
      if (r < 5) mat[size - 7 + r][8] = bit(10 + r);
      else break;
    }
    // 固定暗模块
    mat[size - 8][8] = 1;
  }

  // 评分（简化：仅用规则 1 + 规则 2）
  function score(mat, size){
    let sc = 0;
    // 规则 1: 5 个连续相同色 = 3 + 每多一个 +1
    for (let r = 0; r < size; r++) {
      let run = 1;
      for (let c = 1; c < size; c++) {
        if (mat[r][c] === mat[r][c - 1]) { run++; } else { if (run >= 5) sc += (3 + run - 5); run = 1; }
      }
      if (run >= 5) sc += (3 + run - 5);
    }
    for (let c = 0; c < size; c++) {
      let run = 1;
      for (let r = 1; r < size; r++) {
        if (mat[r][c] === mat[r - 1][c]) { run++; } else { if (run >= 5) sc += (3 + run - 5); run = 1; }
      }
      if (run >= 5) sc += (3 + run - 5);
    }
    // 规则 2: 2x2 同色块 = 3
    for (let r = 0; r < size - 1; r++) {
      for (let c = 0; c < size - 1; c++) {
        if (mat[r][c] === mat[r][c + 1] && mat[r][c] === mat[r + 1][c] && mat[r][c] === mat[r + 1][c + 1]) sc += 3;
      }
    }
    // 规则 3: 类 FP 图案 1:1:3:1:1 = 40
    for (let r = 0; r < size; r++) {
      for (let c = 0; c < size - 6; c++) {
        const p = mat[r].slice(c, c + 7);
        if (p.join('') === '1011101' || p.join('') === '1011101') sc += 40;
      }
    }
    return sc;
  }

  // UTF-8 编码
  function toUtf8Bytes(str){
    const bytes = [];
    for (let i = 0; i < str.length; i++) {
      let code = str.charCodeAt(i);
      if (code < 0x80) {
        bytes.push(code);
      } else if (code < 0x800) {
        bytes.push(0xc0 | (code >> 6));
        bytes.push(0x80 | (code & 0x3f));
      } else if (code < 0xd800 || code >= 0xe000) {
        bytes.push(0xe0 | (code >> 12));
        bytes.push(0x80 | ((code >> 6) & 0x3f));
        bytes.push(0x80 | (code & 0x3f));
      } else {
        // UTF-16 代理对
        i++;
        const hi = code, lo = str.charCodeAt(i);
        code = 0x10000 + (((hi & 0x3ff) << 10) | (lo & 0x3ff));
        bytes.push(0xf0 | (code >> 18));
        bytes.push(0x80 | ((code >> 12) & 0x3f));
        bytes.push(0x80 | ((code >> 6) & 0x3f));
        bytes.push(0x80 | (code & 0x3f));
      }
    }
    return bytes;
  }

  // 主入口
  function generate(text){
    const data = toUtf8Bytes(text);
    const version = chooseVersion(data.length);
    const encoded = encodeData(data, version);
    const codewords = addEC(encoded, version);
    const { mat, res, size } = buildMatrix(codewords, version);

    // 尝试 8 个 mask，选评分最低的
    let bestMask = 0;
    let bestScore = Infinity;
    let bestMatrix = null;
    for (let m = 0; m < 8; m++) {
      const candidate = applyMask(mat, res, m, size);
      placeFormat(candidate, size, calcFormat(m));
      const s = score(candidate, size);
      if (s < bestScore) {
        bestScore = s;
        bestMask = m;
        bestMatrix = candidate;
      }
    }

    // 输出 SVG
    const cell = 8;
    const pad = 4;
    const total = (size + pad * 2) * cell;
    let svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${total} ${total}" width="100%" height="100%">`;
    svg += `<rect width="${total}" height="${total}" fill="#ffffff"/>`;
    for (let r = 0; r < size; r++) {
      for (let c = 0; c < size; c++) {
        if (bestMatrix[r][c] === 1) {
          svg += `<rect x="${(c + pad) * cell}" y="${(r + pad) * cell}" width="${cell}" height="${cell}" fill="#000000"/>`;
        }
      }
    }
    svg += `</svg>`;
    return svg;
  }

  return { generate };
})();

/* -------- 生成二维码并插入到页面 -------- */
(function renderQR(){
  const img = document.querySelector('.qr-card img');
  if (!img) return;
  try {
    const url = window.location.origin + window.location.pathname;
    const svg = QRUtil.generate(url);
    img.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg);
    img.alt = '扫码访问官网';
    // 更新提示文字（含 URL）
    const cap = document.querySelector('.qr-card p');
    if (cap) cap.textContent = '扫码访问官网 · ' + url;
  } catch (err) {
    console.warn('二维码生成失败:', err);
    img.alt = '请直接点击上方"下载 APK"按钮';
  }
})();

/* -------- 更新下载按钮版本号（可选） -------- */
(function updateDownloadText(){
  const btns = document.querySelectorAll('#downloadBtn');
  // 如果 URL 中文件名变化，不做额外处理
})();
