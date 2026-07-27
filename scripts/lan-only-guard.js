#!/usr/bin/env node
'use strict';

const dns = require('node:dns');
const dnsPromises = require('node:dns/promises');
const http = require('node:http');
const net = require('node:net');
const tls = require('node:tls');

if (!globalThis.__LAN_CODEX_GUARD_INSTALLED__) {
  Object.defineProperty(globalThis, '__LAN_CODEX_GUARD_INSTALLED__', { value: true });

  const accessToken = String(process.env.MOBILE_TYPER_TOKEN || '');

  function redactOutput(value) {
    if (!accessToken) return value;
    if (Buffer.isBuffer(value)) {
      const text = value.toString('utf8');
      return text.includes(accessToken) ? Buffer.from(text.replaceAll(accessToken, '[REDACTED]'), 'utf8') : value;
    }
    if (typeof value === 'string' && value.includes(accessToken)) return value.replaceAll(accessToken, '[REDACTED]');
    return value;
  }

  for (const stream of [process.stdout, process.stderr]) {
    const originalWrite = stream.write;
    stream.write = function guardedWrite(chunk, ...args) {
      return originalWrite.call(this, redactOutput(chunk), ...args);
    };
  }

  const blockedRoutes = [
    '/codex-mini/license',
    '/codex-mini/activate',
    '/codex-mini/purchase',
    '/codex-mini/relay',
    '/codex/notifications',
    '/codex/push',
  ];

  function normalizeHost(host) {
    let value = String(host || '').trim().toLowerCase();
    if (value.startsWith('[') && value.endsWith(']')) value = value.slice(1, -1);
    const zone = value.indexOf('%');
    if (zone >= 0) value = value.slice(0, zone);
    return value;
  }

  function isPrivateHost(host) {
    const value = normalizeHost(host);
    if (!value) return true;
    if (value === 'localhost' || value === 'ip6-localhost' || value === '0.0.0.0' || value === '::') return true;

    const ipVersion = net.isIP(value);
    if (ipVersion === 4) {
      const parts = value.split('.').map(Number);
      return parts[0] === 10
        || parts[0] === 127
        || (parts[0] === 169 && parts[1] === 254)
        || (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31)
        || (parts[0] === 192 && parts[1] === 168);
    }

    if (ipVersion === 6) {
      if (value === '::1') return true;
      if (/^(?:fc|fd)/.test(value) || /^fe[89ab]/.test(value)) return true;
      const mapped = value.match(/::ffff:(\d+\.\d+\.\d+\.\d+)$/);
      return Boolean(mapped && isPrivateHost(mapped[1]));
    }

    return false;
  }

  function blockedError(host) {
    const error = new Error(`LAN-only mode blocked public host: ${normalizeHost(host) || '<unknown>'}`);
    error.code = 'LAN_ONLY_BLOCKED';
    return error;
  }

  function assertPrivateHost(host) {
    if (!isPrivateHost(host)) throw blockedError(host);
  }

  function hostFromConnectArgs(args) {
    const first = args[0];
    if (first && typeof first === 'object') {
      if (first.path && !first.port) return '';
      return first.host || first.hostname || 'localhost';
    }
    if (typeof first === 'string' && !/^\d+$/.test(first)) return '';
    return typeof args[1] === 'string' ? args[1] : 'localhost';
  }

  const originalSocketConnect = net.Socket.prototype.connect;
  net.Socket.prototype.connect = function guardedConnect(...args) {
    assertPrivateHost(hostFromConnectArgs(args));
    return originalSocketConnect.apply(this, args);
  };

  const originalTlsConnect = tls.connect;
  tls.connect = function guardedTlsConnect(...args) {
    assertPrivateHost(hostFromConnectArgs(args));
    return originalTlsConnect.apply(this, args);
  };

  function urlHost(input) {
    if (typeof input === 'string' || input instanceof URL) return new URL(input).hostname;
    if (input && typeof input.url === 'string') return new URL(input.url).hostname;
    return '';
  }

  if (typeof globalThis.fetch === 'function') {
    const originalFetch = globalThis.fetch;
    globalThis.fetch = function guardedFetch(input, init) {
      try {
        assertPrivateHost(urlHost(input));
      } catch (error) {
        return Promise.reject(error);
      }
      return originalFetch(input, init);
    };
  }

  if (typeof globalThis.WebSocket === 'function') {
    const NativeWebSocket = globalThis.WebSocket;
    globalThis.WebSocket = class GuardedWebSocket extends NativeWebSocket {
      constructor(url, protocols) {
        assertPrivateHost(urlHost(url));
        super(url, protocols);
      }
    };
  }

  function guardDnsCallback(original) {
    return function guardedDns(host, ...args) {
      if (!isPrivateHost(host)) {
        const callback = args.findLast(value => typeof value === 'function');
        if (callback) {
          process.nextTick(callback, blockedError(host));
          return;
        }
        throw blockedError(host);
      }
      return original.call(this, host, ...args);
    };
  }

  for (const name of ['lookup', 'resolve', 'resolve4', 'resolve6', 'resolveAny', 'resolveCaa', 'resolveCname', 'resolveMx', 'resolveNaptr', 'resolveNs', 'resolvePtr', 'resolveSoa', 'resolveSrv', 'resolveTxt']) {
    if (typeof dns[name] === 'function') dns[name] = guardDnsCallback(dns[name]);
  }

  function guardDnsPromise(original) {
    return async function guardedDnsPromise(host, ...args) {
      assertPrivateHost(host);
      return original.call(this, host, ...args);
    };
  }

  for (const name of ['lookup', 'resolve', 'resolve4', 'resolve6', 'resolveAny', 'resolveCaa', 'resolveCname', 'resolveMx', 'resolveNaptr', 'resolveNs', 'resolvePtr', 'resolveSoa', 'resolveSrv', 'resolveTxt']) {
    if (typeof dnsPromises[name] === 'function') dnsPromises[name] = guardDnsPromise(dnsPromises[name]);
  }

  const originalServerEmit = http.Server.prototype.emit;
  http.Server.prototype.emit = function guardedServerEmit(event, request, response, ...rest) {
    if (event === 'request' && request && response) {
      const remoteHost = request.socket && request.socket.remoteAddress;
      if (remoteHost && !isPrivateHost(remoteHost)) {
        response.writeHead(403, {
          'cache-control': 'no-store',
          'content-type': 'application/json; charset=utf-8',
        });
        response.end('{"ok":false,"error":"LAN clients only"}');
        return true;
      }
      let pathname = '';
      try {
        pathname = new URL(request.url || '/', 'http://localhost').pathname;
      } catch {}
      if (blockedRoutes.some(prefix => pathname === prefix || pathname.startsWith(`${prefix}/`))) {
        response.writeHead(404, {
          'cache-control': 'no-store',
          'content-type': 'application/json; charset=utf-8',
        });
        response.end('{"ok":false,"error":"LAN-only build"}');
        return true;
      }
    }
    return originalServerEmit.call(this, event, request, response, ...rest);
  };

  process.env.CODEX_MINI_LOCAL_ONLY = '1';
  process.env.CODEX_MINI_DISABLE_A1_TUNNEL = '1';
  process.env.CODEX_MINI_DISABLE_IMESSAGE_NOTIFY = '1';

  module.exports = { isPrivateHost };
}
