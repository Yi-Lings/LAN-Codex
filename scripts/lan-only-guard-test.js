#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const http = require('node:http');
const path = require('node:path');

const guard = require('./lan-only-guard');

async function request(port, path) {
  return new Promise((resolve, reject) => {
    const req = http.get({ host: '127.0.0.1', port, path }, response => {
      let body = '';
      response.setEncoding('utf8');
      response.on('data', chunk => { body += chunk; });
      response.on('end', () => resolve({ status: response.statusCode, body }));
    });
    req.on('error', reject);
  });
}

async function main() {
  const probeToken = 'guard-redaction-probe-token';
  const probe = spawnSync(
    process.execPath,
    ['--require', path.join(__dirname, 'lan-only-guard.js'), '-e', `console.log('token=${probeToken}')`],
    { encoding: 'utf8', env: { ...process.env, MOBILE_TYPER_TOKEN: probeToken } },
  );
  assert.equal(probe.status, 0);
  assert.equal(probe.stdout.trim(), 'token=[REDACTED]');

  assert.equal(guard.isPrivateHost('127.0.0.1'), true);
  assert.equal(guard.isPrivateHost('0.0.0.0'), true);
  assert.equal(guard.isPrivateHost('::'), true);
  assert.equal(guard.isPrivateHost('192.168.1.20'), true);
  assert.equal(guard.isPrivateHost('172.31.4.5'), true);
  assert.equal(guard.isPrivateHost('8.8.8.8'), false);
  assert.equal(guard.isPrivateHost('example.com'), false);

  await assert.rejects(globalThis.fetch('https://example.com'), error => error.code === 'LAN_ONLY_BLOCKED');

  const server = http.createServer((req, res) => {
    res.writeHead(200, { 'content-type': 'text/plain' });
    res.end('ok');
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));

  try {
    const { port } = server.address();
    assert.deepEqual(await request(port, '/health'), { status: 200, body: 'ok' });
    assert.equal((await request(port, '/codex-mini/license')).status, 404);
    assert.equal((await request(port, '/codex-mini/activate')).status, 404);

    let blockedStatus = 0;
    server.emit(
      'request',
      { url: '/health', socket: { remoteAddress: '8.8.8.8' } },
      {
        writeHead(status) { blockedStatus = status; },
        end() {},
      },
    );
    assert.equal(blockedStatus, 403);
  } finally {
    await new Promise(resolve => server.close(resolve));
  }

  process.stdout.write('LAN-only guard tests passed.\n');
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
