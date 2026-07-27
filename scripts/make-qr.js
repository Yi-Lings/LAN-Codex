#!/usr/bin/env node
'use strict';
// 生成「网站入口」二维码图片(完全离线、零网络请求;带 token 的网址只在本机编码)。
// 供 Windows 控制面板调用,也可跨端复用。
// 用法: node make-qr.js <text> <outPath> [cellSize=8] [ecLevel=M]
// 成功打印一行 JSON {"ok":true,...};失败打印 {"ok":false,"error":...} 并以退出码 1 结束。

const fs = require('fs');
const path = require('path');

function fail(msg) {
  process.stdout.write(JSON.stringify({ ok: false, error: String(msg) }) + '\n');
  process.exit(1);
}

try {
  const qrcode = require(path.join(__dirname, '..', 'public', 'vendor', 'qrcode', 'qrcode.js'));

  const text = process.argv[2];
  const outPath = process.argv[3];
  const cellSize = Math.max(1, parseInt(process.argv[4] || '8', 10) || 8);
  const ec = (process.argv[5] || 'M').toUpperCase();

  if (!text) fail('missing text');
  if (!outPath) fail('missing outPath');
  if (['L', 'M', 'Q', 'H'].indexOf(ec) < 0) fail('bad ecLevel: ' + ec);

  const qr = qrcode(0, ec);   // typeNumber 0 = 自动选能容纳内容的最小版本
  qr.addData(text);           // 默认 Byte 模式(UTF-8),适配带 token 的长网址
  qr.make();

  const margin = cellSize * 4; // 4 个模块的静区(quiet zone),保证手机能稳定识别
  const dataUrl = qr.createDataURL(cellSize, margin);
  const comma = dataUrl.indexOf(',');
  const meta = dataUrl.slice(5, comma); // 形如 image/gif;base64
  const buf = Buffer.from(dataUrl.slice(comma + 1), 'base64');
  fs.writeFileSync(outPath, buf);

  process.stdout.write(JSON.stringify({
    ok: true,
    out: outPath,
    mime: meta.split(';')[0],
    modules: qr.getModuleCount(),
    cellSize: cellSize,
    ec: ec,
    bytes: buf.length
  }) + '\n');
} catch (e) {
  fail(e && e.stack ? e.stack : e);
}
