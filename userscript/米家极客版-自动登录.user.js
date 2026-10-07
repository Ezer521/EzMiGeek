// ==UserScript==
// @name         米家极客版 · 自动登录
// @namespace    mijia-geek-auto-login
// @version      3.0.0
// @author       |Ezer|
// @include      /^https?:\/\/(192\.168\.\d{1,3}\.\d{1,3}|10\.\d{1,3}\.\d{1,3}\.\d{1,3}|172\.(1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}):8086\//
// @grant        GM_xmlhttpRequest
// @grant        GM_getValue
// @grant        GM_setValue
// @grant        GM_deleteValue
// @grant        GM_cookie
// @connect      account.xiaomi.com
// @connect      sts.api.mijia.tech
// @connect      sts.api.io.mi.com
// @connect      core.api.mijia.tech
// @connect      api.io.mi.com
// @run-at       document-idle
// ==/UserScript==

/* ============================================================================
   米家极客版 · 自动登录
   原理（全程实测过）：
     1) 用保存的小米登录态(passToken)换一张 sid=mijia 的 serviceToken；
     2) 带签名调用 core.api.mijia.tech 的 miIO.get_central_link_passcode，
        目标设备是【路由器】而不是中枢网关（码由路由器签发）；
     3) 拿到 6 位码后自动点页面上的虚拟键盘。
     ========================================================================== */

(function () {
  'use strict';

  /* ------------------------------------------------------------------ 配置 */
  var DEFAULTS = {
    userId: '',
    cUserId: '',
    deviceId: '',
    passToken: '',
    serviceToken: '',
    ssecurity: '',
    routerDid: '',
    auto: true
  };
  var CFG_KEY = 'mijia_geek_cfg_v2';
  var UA_APP = 'Android-7.1.1-1.0.0-ONEPLUS A3010-136-ABCDEFABCDEF0 APP/xiaomi.smarthome APPV/62830';
  var ACCESS_KEY = 'IOS00026747c5acafc2';
  var HOST = 'https://core.api.mijia.tech';

  function storeGet(k, d) {
    try { if (typeof GM_getValue === 'function') { var v = GM_getValue(k, null); if (v !== null && v !== undefined) return v; } } catch (e) {}
    try { var s = localStorage.getItem(k); if (s) return s; } catch (e) {}
    return d;
  }
  function storeSet(k, v) {
    try { if (typeof GM_setValue === 'function') GM_setValue(k, v); } catch (e) {}
    try { localStorage.setItem(k, v); } catch (e) {}
  }
  var PREFS_KEY = 'mijia_geek_prefs_v1';

  function loadCfg() {
    var c = {};
    for (var k in DEFAULTS) c[k] = DEFAULTS[k];
    var raw = storeGet(PREFS_KEY, null);
    if (raw) {
      try {
        var o = JSON.parse(raw);
        if (o.auto !== undefined) c.auto = !!o.auto;
        if (o.routerDid) c.routerDid = o.routerDid;
      } catch (e) {}
    }
    return c;
  }
  function saveCfg(c) {
    var o = { auto: !!c.auto, routerDid: c.routerDid || '' };
    storeSet(PREFS_KEY, JSON.stringify(o));
  }
  /* 清理旧版遗留：CFG_KEY 里存过 serviceToken/ssecurity 等凭据，启动即删
     （localStorage 与 GM 存储都清）；新结构 PREFS_KEY 不含任何凭据。 */
  function purgeLegacyCfg() {
    try { localStorage.removeItem(CFG_KEY); } catch (e) {}
    try { if (typeof GM_deleteValue === 'function') GM_deleteValue(CFG_KEY); } catch (e) {}
  }

  var CFG = loadCfg();

  /* ------------------------------------------------- 纯 JS SHA-256 / HMAC */
  var K256 = [0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2];

  function rotr(x, n) { return (x >>> n) | (x << (32 - n)); }

  function sha256Bytes(msg) {
    var ml = msg.length;
    var hi = Math.floor(ml / 536870912);
    var lo = (ml << 3) >>> 0;
    var total = ((ml + 9 + 63) >> 6) << 6;
    var m = new Uint8Array(total);
    m.set(msg);
    m[ml] = 0x80;
    var dv = new DataView(m.buffer);
    dv.setUint32(total - 8, hi);
    dv.setUint32(total - 4, lo);

    var H = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
    var w = new Int32Array(64);
    for (var i = 0; i < total; i += 64) {
      for (var t = 0; t < 16; t++) w[t] = dv.getInt32(i + t * 4);
      for (t = 16; t < 64; t++) {
        var s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >>> 3);
        var s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >>> 10);
        w[t] = (w[t - 16] + s0 + w[t - 7] + s1) | 0;
      }
      var a = H[0], b = H[1], c = H[2], d = H[3], e = H[4], f = H[5], g = H[6], h = H[7];
      for (t = 0; t < 64; t++) {
        var S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
        var ch = (e & f) ^ ((~e) & g);
        var t1 = (h + S1 + ch + K256[t] + w[t]) | 0;
        var S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
        var maj = (a & b) ^ (a & c) ^ (b & c);
        var t2 = (S0 + maj) | 0;
        h = g; g = f; f = e; e = (d + t1) | 0; d = c; c = b; b = a; a = (t1 + t2) | 0;
      }
      H[0] = (H[0] + a) | 0; H[1] = (H[1] + b) | 0; H[2] = (H[2] + c) | 0; H[3] = (H[3] + d) | 0;
      H[4] = (H[4] + e) | 0; H[5] = (H[5] + f) | 0; H[6] = (H[6] + g) | 0; H[7] = (H[7] + h) | 0;
    }
    var out = new Uint8Array(32);
    var odv = new DataView(out.buffer);
    for (i = 0; i < 8; i++) odv.setInt32(i * 4, H[i]);
    return out;
  }

  function hmacSha256(keyBytes, msgBytes) {
    var block = 64;
    var k = keyBytes;
    if (k.length > block) k = sha256Bytes(k);
    var kp = new Uint8Array(block);
    kp.set(k);
    var ipad = new Uint8Array(block + msgBytes.length);
    var opad = new Uint8Array(block + 32);
    for (var i = 0; i < block; i++) { ipad[i] = kp[i] ^ 0x36; opad[i] = kp[i] ^ 0x5c; }
    ipad.set(msgBytes, block);
    var inner = sha256Bytes(ipad);
    opad.set(inner, block);
    return sha256Bytes(opad);
  }

  var B64C = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  function b64encode(bytes) {
    var s = '', i;
    for (i = 0; i + 2 < bytes.length; i += 3) {
      var n = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
      s += B64C[(n >> 18) & 63] + B64C[(n >> 12) & 63] + B64C[(n >> 6) & 63] + B64C[n & 63];
    }
    var rest = bytes.length - i;
    if (rest === 1) {
      var n1 = bytes[i] << 16;
      s += B64C[(n1 >> 18) & 63] + B64C[(n1 >> 12) & 63] + '==';
    } else if (rest === 2) {
      var n2 = (bytes[i] << 16) | (bytes[i + 1] << 8);
      s += B64C[(n2 >> 18) & 63] + B64C[(n2 >> 12) & 63] + B64C[(n2 >> 6) & 63] + '=';
    }
    return s;
  }
  function b64decode(str) {
    var clean = String(str).replace(/[^A-Za-z0-9+/]/g, '');
    var len = clean.length;
    var bytes = new Uint8Array(Math.floor(len * 3 / 4));
    var p = 0, buf = 0, bits = 0;
    for (var i = 0; i < len; i++) {
      buf = (buf << 6) | B64C.indexOf(clean.charAt(i));
      bits += 6;
      if (bits >= 8) { bits -= 8; bytes[p++] = (buf >> bits) & 255; }
    }
    return bytes.subarray(0, p);
  }
  function strToBytes(s) {
    var b = new Uint8Array(s.length);
    for (var i = 0; i < s.length; i++) b[i] = s.charCodeAt(i) & 255;
    return b;
  }
  /* 与 Python urllib.parse.quote(safe='') 对齐的编码 */
  function urlEnc(s) {
    return encodeURIComponent(String(s)).replace(/[!'()*]/g, function (c) {
      return '%' + c.charCodeAt(0).toString(16).toUpperCase();
    });
  }

  /* --------------------------------------------------------------- 网络层 */
  function gm(opts) {
    return new Promise(function (resolve, reject) {
      GM_xmlhttpRequest({
        method: opts.method || 'GET',
        url: opts.url,
        headers: opts.headers || {},
        data: opts.data,
        anonymous: opts.anonymous !== false,
        timeout: opts.timeout || 25000,
        onload: function (r) { resolve(r); },
        onerror: function (e) { reject(new Error('网络错误')); },
        ontimeout: function () { reject(new Error('请求超时')); }
      });
    });
  }

  function readCookieToken(name, domain) {
    return new Promise(function (resolve) {
      if (typeof GM_cookie === 'undefined' || !GM_cookie || !GM_cookie.list) return resolve('');
      try {
        GM_cookie.list({ name: name, domain: domain }, function (cookies, err) {
          if (err || !cookies || !cookies.length) return resolve('');
          resolve(cookies[0].value || '');
        });
      } catch (e) { resolve(''); }
    });
  }

  function parseSetCookie(headers, name) {
    if (!headers) return '';
    var h = String(headers).replace(/\r/g, '\n');
    var re = new RegExp('(?:^|\\n)set-cookie:\\s*' + name + '=([^;\\s]+)', 'i');
    var m = re.exec(h);
    return m ? m[1] : '';
  }

  var LOGIN_URL = 'https://account.xiaomi.com/pass/serviceLogin?sid=mijia&_json=true&_locale=zh_CN';

  var lastMintNote = '';

  /* 续期：换一张新的 serviceToken。
     优先「借浏览器里已经登录的小米账号」——这样连 passToken 都不用过期担忧。
     sid 默认 mijia（打极客版接口用），拉设备列表时要换成 xiaomiio。 */
  function mintToken(cfg, sid, stsDomain) {
    //   全局变量跨调用残留 + 非 JSON 应答（502 网关页）也算拒绝 → 纯网络
    //   失败被误报成「登录态过期」。只有「合法 JSON 且明确带 result 拒绝」
    //   才置位，且每次调用都从 false 开始。
    var sawApiReject = false;
    sid = sid || 'mijia';
    stsDomain = stsDomain || 'sts.api.mijia.tech';
    var loginUrl = 'https://account.xiaomi.com/pass/serviceLogin?sid=' + sid +
      '&_json=true&_locale=zh_CN';
    var ways = [{
      label: '浏览器登录态',
      anonymous: false,
      headers: { 'User-Agent': UA_APP }
    }];
    if (cfg.passToken) {
      ways.push({
        label: '脚本内置登录态',
        anonymous: false,
        headers: {
          'User-Agent': UA_APP,
          'Cookie': 'userId=' + cfg.userId + '; passToken=' + cfg.passToken +
            '; cUserId=' + cfg.cUserId + '; deviceId=' + cfg.deviceId
        }
      });
    }
    var i = 0;
    function next() {
      if (i >= ways.length) {
        //   纯网络失败（从没应答）不再误报过期，交回给失败重试流程。
        if (!sawApiReject) {
          return Promise.reject(new Error('网络异常，暂时拿不到小米登录态（' + lastMintNote + '）'));
        }
        //   ① 发生了什么（两条路都不通）；② 下一步点什么。
        var e = new Error('小米登录态已过期，且脚本内置的凭据也失效了。' +
          '点面板上的「去小米登录」登一次，回来再点「刷新登录态」');
        e.expired = true;
        return Promise.reject(e);
      }
      var w = ways[i++];
      return gm({ method: 'GET', url: loginUrl, headers: w.headers, anonymous: w.anonymous, timeout: 20000 })
        .then(function (r) {
          var txt = String(r.responseText || '').replace('&&&START&&&', '');
          var j = null;
          try { j = JSON.parse(txt); } catch (e) {}
          //   这一支以前静默 next() 掉，现在留个痕，方便排查是"过期"还是"要验证"。
          if (!j || j.result !== 'ok' || !j.location) {
            lastMintNote = (j && (j.result || j.message)) || 'no-json';
            // 只有「合法 JSON 且明确带 result 拒绝」才构成过期/验证信号；
            // 非 JSON（502 网关页等）不算。
            //   不完整」，不算认证拒绝；只有【明确拒绝】才置位。
            if (j && j.result !== undefined && j.result !== 'ok') sawApiReject = true;
            return next();
          }
          return gm({ method: 'GET', url: j.location, headers: w.headers, anonymous: w.anonymous, timeout: 25000 })
            .then(function (r2) {
              return readCookieToken('serviceToken', stsDomain).then(function (v) {
                var tok = parseSetCookie(r2.responseHeaders, 'serviceToken') || v;
                if (!tok) { lastMintNote = 'no-serviceToken-cookie'; return next(); }
                return {
                  serviceToken: tok, ssecurity: j.ssecurity,
                  userId: String(j.userId || cfg.userId), cUserId: j.cUserId || cfg.cUserId,
                  via: w.label
                };
              });
            });
        })
        .catch(function (ev) {
          lastMintNote = (ev && ev.message) || 'request-failed';
          return next();
        });
    }
    return next();
  }

  /* 主动续期（界面上「刷新登录态」那个按钮走的就是这里）。
     手动点的场景 = 人已经在看着面板了，所以这里正常汇报进度。 */
  function refreshCred() {
    if (!document.getElementById(BOX_ID)) showUI();
    setStatus('正在刷新登录态…', 'work');
    return mintToken(CFG).then(function (cred) {
      CFG.serviceToken = cred.serviceToken;
      CFG.ssecurity = cred.ssecurity;
      CFG.userId = cred.userId;
      CFG.cUserId = cred.cUserId;
      saveCfg(CFG);
      return fetchPasscode(CFG, { serviceToken: cred.serviceToken, ssecurity: cred.ssecurity,
        userId: cred.userId, cUserId: cred.cUserId }).then(function (code) {
          //   否则小圆点会一直红着，下次真过期时反而看不出区别。
          paused = false;
          setExpired(false);
          setStatus('登录态已刷新（' + cred.via + '），测试取码 ' + code + ' ✓', 'ok');
          return code;
        }, function (e) {
          setStatus('刷新后仍取不到码：' + e.message, 'err');
          throw e;
        });
    }).catch(function (e) {
      // 刷新都失败了 —— 这就是"必须去小米登录一次"的确定信号
      if (e && (e.expired || e.authFailed)) setExpired(true);
      setStatus('刷新失败：' + e.message +
        (lastMintNote ? '（' + lastMintNote + '）' : ''), 'err');
      throw e;
    });
  }

  /* 打取码接口 */
  function fetchPasscode(cfg, cred, did) {
    var path = '/app/home/rpc/' + (did || cfg.routerDid);
    var data = JSON.stringify({ id: 2, method: 'miIO.get_central_link_passcode', accessKey: ACCESS_KEY, params: {} });
    var rnd = new Uint8Array(12);
    crypto.getRandomValues(rnd.subarray(0, 8));
    var p2 = Math.floor(Date.now() / 60000);
    rnd[8] = (p2 >>> 24) & 255; rnd[9] = (p2 >>> 16) & 255; rnd[10] = (p2 >>> 8) & 255; rnd[11] = p2 & 255;
    var nonce = b64encode(rnd);
    var sn = b64encode(sha256Bytes(concatBytes(b64decode(cred.ssecurity), b64decode(nonce))));
    var signStr = [path.replace('/app/', '/'), sn, nonce, 'data=' + data].join('&');
    var sig = b64encode(hmacSha256(b64decode(sn), strToBytes(signStr)));
    var body = '_nonce=' + urlEnc(nonce) + '&data=' + urlEnc(data) + '&signature=' + urlEnc(sig);
    return gm({
      method: 'POST', anonymous: true, timeout: 30000,
      url: HOST + path, data: body,
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'User-Agent': UA_APP,
        'Accept': '*/*',
        'X-XIAOMI-PROTOCAL-FLAG-CLI': 'PROTOCAL-HTTP2',
        'domain-refer': 'core.api.mijia.tech',
        'miot-request-model': 'xiaomi.gateway.hub1',
        'Cookie': 'serviceToken=' + cred.serviceToken + '; userId=' + cred.userId + '; cUserId=' + cred.cUserId
      }
    }).then(function (r) {
      var txt = String(r.responseText || '');
      var j;
      try { j = JSON.parse(txt); } catch (e) { throw new Error('取码返回不是 JSON：' + txt.slice(0, 160)); }
      var code = j && j.result && j.result.passcode;
      if (code) return code;
      var msg = (j && (j.message || (j.error && j.error.message))) || txt.slice(0, 160);
      var e2 = new Error('取码失败：' + msg);
      e2.authFailed = (String(msg).indexOf('auth') >= 0 || String(msg).indexOf('signature') >= 0);
      e2.detail = txt.slice(0, 300);
      throw e2;
    });
  }

  function concatBytes(a, b) {
    var o = new Uint8Array(a.length + b.length);
    o.set(a); o.set(b, a.length);
    return o;
  }

  /* ============================ 自动认设备（换硬件也不用改脚本） ============
     取码接口必须打给「当前主中枢」那台设备，而**页面本身就是它提供的**，
     所以它的 localip 就等于浏览器地址栏里的主机名。
     于是：拉一次云端设备列表 → 找 localip 等于当前主机名的那台 → 用它的 did。
     这样路由器换成中枢网关、或者加了新中枢，脚本都能自己找对，不用改代码。
     （设备列表接口在 api.io.mi.com，需要 SHA-1 + RC4，下面是自己实现的。） */
  var MI_IO = 'https://api.io.mi.com';
  var DEVICE_LIST_URL_PATH = '/app/home/device_list';
  var DEVICE_LIST_SIGN_PATH = '/home/device_list';   // 签名串里要去掉 /app
  var DEVICE_LIST_DATA = '{"getVirtualModel":true,"getHuamiDevices":1,' +
    '"get_split_device":false,"support_smart_home":true}';

  function sha1Bytes(msg) {
    var ml = msg.length;
    //   长度多垫一个空块 → 摘要错误。标准填充 = 64 * (floor((ml+8)/64) + 1)。
    var total = (((ml + 8) >> 6) + 1) << 6;
    var buf = new Uint8Array(total);
    buf.set(msg);
    buf[ml] = 0x80;
    var bitLen = ml * 8;
    buf[total - 4] = (bitLen >>> 24) & 255; buf[total - 3] = (bitLen >>> 16) & 255;
    buf[total - 2] = (bitLen >>> 8) & 255; buf[total - 1] = bitLen & 255;
    var h0 = 0x67452301, h1 = 0xEFCDAB89, h2 = 0x98BADCFE, h3 = 0x10325476, h4 = 0xC3D2E1F0;
    var w = new Array(80);
    for (var off = 0; off < total; off += 64) {
      var i;
      for (i = 0; i < 16; i++) {
        w[i] = (buf[off + i * 4] << 24) | (buf[off + i * 4 + 1] << 16) |
               (buf[off + i * 4 + 2] << 8) | buf[off + i * 4 + 3];
      }
      for (i = 16; i < 80; i++) {
        var x = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16];
        w[i] = (x << 1) | (x >>> 31);
      }
      var a = h0, b = h1, c = h2, d = h3, e = h4;
      for (var j = 0; j < 80; j++) {
        var f, k;
        if (j < 20) { f = (b & c) | ((~b) & d); k = 0x5A827999; }
        else if (j < 40) { f = b ^ c ^ d; k = 0x6ED9EBA1; }
        else if (j < 60) { f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC; }
        else { f = b ^ c ^ d; k = 0xCA62C1D6; }
        var t = ((((a << 5) | (a >>> 27)) + f + e + k + w[j]) | 0);
        e = d; d = c; c = (b << 30) | (b >>> 2); b = a; a = t;
      }
      h0 = (h0 + a) | 0; h1 = (h1 + b) | 0; h2 = (h2 + c) | 0;
      h3 = (h3 + d) | 0; h4 = (h4 + e) | 0;
    }
    var out = new Uint8Array(20);
    [h0, h1, h2, h3, h4].forEach(function (h, idx) {
      out[idx * 4] = (h >>> 24) & 255; out[idx * 4 + 1] = (h >>> 16) & 255;
      out[idx * 4 + 2] = (h >>> 8) & 255; out[idx * 4 + 3] = h & 255;
    });
    return out;
  }

  /* 小米云要求：RC4 先空转 1024 字节再开始用 */
  function rc4Bytes(keyBytes, dataBytes, skip) {
    var S = new Uint8Array(256), i, tmp, j = 0;
    for (i = 0; i < 256; i++) S[i] = i;
    for (i = 0; i < 256; i++) {
      j = (j + S[i] + keyBytes[i % keyBytes.length]) & 255;
      tmp = S[i]; S[i] = S[j]; S[j] = tmp;
    }
    var out = new Uint8Array(dataBytes.length);
    var ii = 0, jj = 0, n = skip + dataBytes.length, k = 0;
    for (var c = 0; c < n; c++) {
      ii = (ii + 1) & 255; jj = (jj + S[ii]) & 255;
      tmp = S[ii]; S[ii] = S[jj]; S[jj] = tmp;
      var kb = S[(S[ii] + S[jj]) & 255];
      if (c >= skip) out[k++] = dataBytes[c - skip] ^ kb;
    }
    return out;
  }

  function u8ToStr(b) {
    var s = '', i = 0, c, cp;
    while (i < b.length) {
      c = b[i++];
      if (c < 0x80) s += String.fromCharCode(c);
      else if (c < 0xE0) s += String.fromCharCode(((c & 0x1F) << 6) | (b[i++] & 0x3F));
      else if (c < 0xF0) s += String.fromCharCode(((c & 0x0F) << 12) | ((b[i++] & 0x3F) << 6) | (b[i++] & 0x3F));
      else {
        cp = ((c & 0x07) << 18) | ((b[i++] & 0x3F) << 12) |
             ((b[i++] & 0x3F) << 6) | (b[i++] & 0x3F);
        cp -= 0x10000;
        s += String.fromCharCode(0xD800 + (cp >> 10), 0xDC00 + (cp & 0x3FF));
      }
    }
    return s;
  }

  function newNonce() {
    var rnd = new Uint8Array(12);
    crypto.getRandomValues(rnd.subarray(0, 8));
    var p2 = Math.floor(Date.now() / 60000);
    rnd[8] = (p2 >>> 24) & 255; rnd[9] = (p2 >>> 16) & 255;
    rnd[10] = (p2 >>> 8) & 255; rnd[11] = p2 & 255;
    return b64encode(rnd);
  }

  /* 拉设备列表，返回 array（走 api.io.mi.com，需要 sid=xiaomiio 的票） */
  function listDevices() {
    return mintToken(CFG, 'xiaomiio', 'sts.api.io.mi.com').then(function (xio) {
      var nonce = newNonce();
      var sn = b64encode(sha256Bytes(concatBytes(b64decode(xio.ssecurity), b64decode(nonce))));
      var key = b64decode(sn);
      var h1 = b64encode(sha1Bytes(strToBytes(
        ['POST', DEVICE_LIST_SIGN_PATH, 'data=' + DEVICE_LIST_DATA, sn].join('&'))));
      var encData = b64encode(rc4Bytes(key, strToBytes(DEVICE_LIST_DATA), 1024));
      var encHash = b64encode(rc4Bytes(key, strToBytes(h1), 1024));
      var sig = b64encode(sha1Bytes(strToBytes(
        ['POST', DEVICE_LIST_SIGN_PATH, 'data=' + encData, 'rc4_hash__=' + encHash, sn].join('&'))));
      var body = 'data=' + urlEnc(encData) + '&rc4_hash__=' + urlEnc(encHash) +
        '&signature=' + urlEnc(sig) + '&ssecurity=' + urlEnc(xio.ssecurity) +
        '&_nonce=' + urlEnc(nonce);
      var ck = 'userId=' + xio.userId + '; yetAnotherServiceToken=' + xio.serviceToken +
        '; serviceToken=' + xio.serviceToken +
        '; locale=zh_CN; timezone=GMT+8:00; is_daylight=0; dst_offset=0; channel=MI_APP_STORE';
      return gm({
        method: 'POST', anonymous: true, timeout: 25000,
        url: MI_IO + DEVICE_LIST_URL_PATH, data: body,
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'Accept-Encoding': 'identity',
          'x-xiaomi-protocal-flag-cli': 'PROTOCAL-HTTP2',
          'MIOT-ENCRYPT-ALGORITHM': 'ENCRYPT-RC4',
          'User-Agent': UA_APP,
          'Cookie': ck
        }
      }).then(function (r) {
        var raw = String(r.responseText || '').trim();
        var plain;
        try {
          plain = u8ToStr(rc4Bytes(key, b64decode(raw), 1024));
        } catch (e) { throw new Error('设备列表解密失败'); }
        var j;
        try { j = JSON.parse(plain); } catch (e) {
          throw new Error('设备列表返回异常：' + plain.slice(0, 120));
        }
        if (j.code !== 0) throw new Error('设备列表失败：' + (j.message || j.code));
        return ((j.result || {}).list) || [];
      });
    });
  }

  /* 找出「当前页面所在的那台设备」——它的 localip 就是主机名 */
  function resolveDid() {
    var host = location.hostname;
    return listDevices().then(function (list) {
      var hit = null, online = [];
      for (var i = 0; i < list.length; i++) {
        var d = list[i];
        if (!d) continue;
        if (d.localip === host) { hit = d; if (d.isOnline) break; }
        if (d.isOnline && /gateway|hub|router|central/.test(String(d.model || ''))) online.push(d);
      }
      if (hit && hit.isOnline) return String(hit.did);
      if (online.length) {
        // 主机名对不上（比如经了反代/域名），退一步：挑一个在线的中枢类设备
        return String(online[0].did);
      }
      throw new Error('设备列表里找不到本机（' + host + '）对应的设备');
    });
  }

  /* 总入口：先试现成的票；票不行就续期，设备不行就重新认设备 */
  function grant() {
    return { serviceToken: CFG.serviceToken, ssecurity: CFG.ssecurity,
             userId: CFG.userId, cUserId: CFG.cUserId };
  }
  function applyCred(c) {
    CFG.serviceToken = c.serviceToken; CFG.ssecurity = c.ssecurity;
    CFG.userId = c.userId; CFG.cUserId = c.cUserId;
    saveCfg(CFG);
  }

  /* 设备侧没响应（换过路由器 / 加过中枢 / 主备切换）→ 重新认一次设备。
     这里是自动补救流程，成功不该打扰人；只有最终还是失败，才由上层 alertUI 兜住。 */
  function retryByDevice(e0) {
    return resolveDid().then(function (did) {
      if (!did || String(did) === String(CFG.routerDid)) throw e0;
      CFG.routerDid = String(did); saveCfg(CFG);
      return fetchPasscode(CFG, grant()).catch(function () { throw e0; });
    }).catch(function () { throw e0; });
  }

  function getPasscode() {
    return fetchPasscode(CFG, grant()).catch(function (e1) {
      if (!e1.authFailed) return retryByDevice(e1);      // 登录态没问题 → 是设备问题
      return mintToken(CFG).then(function (c) {
        applyCred(c);
        return fetchPasscode(CFG, grant());
      }).catch(function (e2) {
        //   旧写法把它们丢掉、重新抛出最初的认证错误 e1，于是网络失败
        //   会被界面误报成「登录过期」。只有续期阶段也明确认证拒绝时，
        //   才走换设备兜底。
        if (e2 && e2.authFailed) return retryByDevice(e2);
        throw e2;
      });
    });
  }

  function getPasscodeWithHint() {
    return getPasscode().catch(function (e) {
      if (e && (e.expired || e.authFailed)) {
        var ne = new Error('小米登录态已过期。点面板「去小米登录」登一次，回来再点「刷新登录态」');
        ne.expired = true;
        ne.detail = e.detail || '';
        throw ne;
      }
      throw e;
    });
  }

  /* --------------------------------------------------------------- 页面层 */
  var busy = false;
  var paused = false;     // 连续失败后的暂停闸门：只有手动点「重试」才解除
  var coolUntil = 0;      // 冷却：刚补完码先让页面稳定一会儿，别再动手

  /* 界面 A：首次登录的虚拟键盘（10 个 .pin-number） */
  function pinPad() {
    var ns = document.querySelectorAll('.pin-number');
    return ns && ns.length >= 6 ? ns : null;
  }

  /* 界面 B：连接断开后的输码框 —— 一个真实的 <input class="pin-code-input" maxlength=6>。
     这是和界面 A 完全不同的 DOM，必须单独识别，否则断连后脚本形同不存在。 */
  function inputPad() {
    var el = document.querySelector('input.pin-code-input');
    if (!el || el.disabled || el.readOnly) return null;
    if (typeof el.getBoundingClientRect === 'function') {
      var r = el.getBoundingClientRect();
      if (r && r.width === 0 && r.height === 0) return null;   // 不可见（隐藏在其他页签里）
    }
    return el;
  }

  /* 页面上当前有输码界面吗（两种都算） */
  function readyPad() { return !!(pinPad() || inputPad()); }

  /* React 受控 input：直接 el.value = x 会被 React 的 value tracker 当成"没变"，
     onChange 不触发 → 必须用原型上的原生 setter 赋值，再派发 input 事件。 */
  function setInputValue(el, code) {
    try {
      var d = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
      if (d && d.set) d.set.call(el, code); else el.value = code;
    } catch (e) { el.value = code; }
    try { el.dispatchEvent(new Event('input', { bubbles: true })); } catch (e) {}
    try { el.dispatchEvent(new Event('change', { bubbles: true })); } catch (e) {}
  }

  function clickKey(ch) {
    var ns = document.querySelectorAll('.pin-number');
    for (var i = 0; i < ns.length; i++) {
      if ((ns[i].innerText || '').replace(/\s/g, '') === ch) {
        var el = ns[i];
        ['pointerdown', 'mousedown', 'pointerup', 'mouseup'].forEach(function (t) {
          var Ev = t.indexOf('pointer') === 0 ? (window.PointerEvent || MouseEvent) : MouseEvent;
          try {
            el.dispatchEvent(new Ev(t, { bubbles: true, cancelable: true, view: window, button: 0 }));
          } catch (e) {}
        });
        try { el.click(); } catch (e) {}
        return true;
      }
    }
    return false;
  }

  function fillCode(code) {
    return new Promise(function (resolve) {
      var i = 0;
      (function step() {
        if (i >= code.length) return resolve(true);
        if (!clickKey(code.charAt(i))) return resolve(false);
        i++;
        setTimeout(step, 220);
      })();
    });
  }

  var failStreak = 0;
  function autoLogin(reason) {
    if (busy || paused) return;           // ★ 暂停中：DOM 变化/自动入口都不再触发
    if (!CFG.auto) return;
    if (!readyPad()) return;
    if (Date.now() < coolUntil) return;   // 刚补过码，等页面稳一会儿再动手
    busy = true;
    // 静默期间不汇报进度：主面板默认不出现，成功就是成功，不需要人知道。
    getPasscodeWithHint().then(function (code) {
      var inp = inputPad();
      if (inp) {
        // 断连界面：一次填满 6 位，满 6 位页面自己提交
        setInputValue(inp, code);
        return null;
      }
      if (!pinPad()) throw new Error('输码界面已消失');
      return fillCode(code).then(function (ok) {
        if (!ok) throw new Error('自动点击失败，请手动输入');
      });
    }).then(function () {
      // 界面一消失就说明进去了：立刻把气泡藏掉（不等固定延时）
      var waited = 0;
      var t = setInterval(function () {
        waited += 300;
        if (!readyPad()) {
          clearInterval(t);
          busy = false;
          failStreak = 0;
          coolUntil = Date.now() + 15000;   // 给页面 15 秒稳定期
          hideUI();
          return;
        }
        if (waited >= 9000) {
          clearInterval(t);
          busy = false;
          failStreak++;
          // 断连补码可能反复出现：连续失败就别再刷云端了，交回给人
          if (failStreak >= 3) {
            paused = true;   // ★ 真暂停：入口全部封住，只有手动重试能解除
            alertUI('自动补码连续失败，已暂停。点这里重试', 'err',
              function () { failStreak = 0; paused = false; autoLogin('手动重试'); });
          } else {
            alertUI('若没进去，点这里重试', 'warn', autoLogin);
          }
        }
      }, 300);
    }).catch(function (e) {
      busy = false;
      failStreak++;
      //   过期时给出固定说法（而不是把接口原文抛给用户），并把常驻小圆点
      //   点成红的、把面板叫出来，让"该去哪儿重登"一眼可见。
      //   判据只认确定信号：e.expired（mintToken 两条路都不通）、
      //   或 e.authFailed（取码接口回了 auth / signature 类错误）。
      //   刻意**不**把网络错误算进来 —— 那会把网络抖动误报成过期，
      //   骗人去白登一次。
      var isExpired = !!(e && (e.expired || e.authFailed));
      if (isExpired) {
        //   「刷新登录态」成功或手动重试才解除。
        paused = true;
        setExpired(true);
        alertUI('小米登录态已过期。点「去小米登录」登一次，回来点「刷新登录态」',
          'err', function () {
            setExpired(false); failStreak = 0; paused = false; autoLogin('手动重试');
          });
      } else if (failStreak >= 3) {
        paused = true;     // ★ 真暂停：入口全部封住
        alertUI('自动登录连续失败：' + e.message + '（已暂停）', 'err',
          function () { failStreak = 0; paused = false; autoLogin('手动重试'); });
      } else {
        alertUI('失败：' + e.message, 'err', autoLogin);
      }
      console.warn('[极客版自动登录]', e, e.detail || '', 'mintNote=' + lastMintNote);
    });
  }

  var box, statusEl, btnEl, dotEl, dotTimer, panelUp = false;

  var DOT_ID = 'mgg-auto-login-dot';
  var BOX_ID = 'mgg-auto-login';

  /* ---------- 常驻小圆点 ---------- */
  function buildDot() {
    if (document.getElementById(DOT_ID)) return;
    dotEl = document.createElement('div');
    dotEl.id = DOT_ID;
    dotEl.title = '米家极客版 · 自动登录（登录态过期时可在这里重登）';
    dotEl.style.cssText = 'position:fixed;right:14px;bottom:14px;z-index:2147483647;' +
      'width:14px;height:14px;border-radius:50%;background:#c9d2dd;opacity:.45;' +
      'cursor:pointer;transition:opacity .18s ease,background .18s ease';
    dotEl.addEventListener('mouseenter', function () {
      clearTimeout(dotTimer);
      dotEl.style.opacity = '.95';
      dotEl.style.background = '#2f7cff';
      // 悬停 260ms 再展开 —— 纯粹路过不弹面板
      dotTimer = setTimeout(function () { showUI(); }, 260);
    });
    dotEl.addEventListener('mouseleave', function () {
      clearTimeout(dotTimer);
      if (panelUp) return;                 // 面板已经出来了就别收，交给它自己管
      dotEl.style.opacity = '.45';
      dotEl.style.background = dotColor;
    });
    dotEl.addEventListener('click', function () { showUI(); });
    document.body.appendChild(dotEl);
    paintDot();
  }

  /* 圆点颜色 = 当前登录态：灰蓝待命 / 红过期 */
  var dotColor = '#c9d2dd';
  function paintDot() {
    if (!dotEl) return;
    dotColor = expired ? '#d93025' : '#c9d2dd';
    if (!panelUp) {
      dotEl.style.background = dotColor;
      dotEl.style.opacity = expired ? '.95' : '.45';
    }
  }

  /* ---------- 过期标记（唯一真身） ----------
     凡是"确认登录态不可用"的地方都收敛到这里，避免面板上出现好几种说法。 */
  var expired = false;
  function setExpired(v) {
    var nv = !!v;
    if (nv === expired) return;
    expired = nv;
    paintDot();
    // 过期是"必须让人知道"的事 —— 主动把面板叫出来（这是 alertUI 的唯一例外）
    if (nv) showUI();
  }

  function buildUI() {
    if (document.getElementById(BOX_ID)) return;
    box = document.createElement('div');
    box.id = BOX_ID;
    box.style.cssText = 'position:fixed;right:16px;bottom:38px;z-index:2147483647;' +
      'font:13px/1.6 -apple-system,"Segoe UI","Microsoft YaHei",sans-serif;' +
      'background:#fff;color:#1a1a1a;border:1px solid #e3e6eb;border-radius:12px;' +
      'box-shadow:0 8px 26px rgba(15,30,60,.16);padding:10px 12px;max-width:320px';
    var head = document.createElement('div');
    head.style.cssText = 'font-weight:600;margin-bottom:2px';
    head.textContent = '极客版自动登录';
    var authorEl = document.createElement('div');
    authorEl.style.cssText = 'color:#8a93a0;font-size:11.5px;margin-bottom:4px';
    authorEl.textContent = '作者：|Ezer|';
    var closeEl = document.createElement('div');
    closeEl.textContent = '✕';
    closeEl.title = '收起（小圆点可再叫出）';
    closeEl.style.cssText = 'position:absolute;top:6px;right:10px;color:#8a93a0;cursor:pointer;font-size:12px';
    closeEl.onclick = function () { hideUI(); };
    statusEl = document.createElement('div');
    statusEl.style.cssText = 'color:#5a6472;word-break:break-all';
    statusEl.textContent = '准备中…';
    var bar = document.createElement('div');
    bar.style.cssText = 'margin-top:8px;display:flex;gap:8px;align-items:center;flex-wrap:wrap';
    btnEl = document.createElement('button');
    btnEl.textContent = '立即登录';
    btnEl.style.cssText = 'padding:5px 12px;border:1px solid #2f7cff;background:#2f7cff;color:#fff;' +
      'border-radius:8px;cursor:pointer;font-size:12.5px';
    btnEl.onclick = function () {
      paused = false; coolUntil = 0; failStreak = 0;
      autoLogin('手动');
    };
    var tgl = document.createElement('label');
    tgl.style.cssText = 'display:flex;align-items:center;gap:4px;color:#5a6472;cursor:pointer';
    var cb = document.createElement('input');
    cb.type = 'checkbox'; cb.checked = !!CFG.auto;
    cb.onchange = function () { CFG.auto = cb.checked; saveCfg(CFG); };
    tgl.appendChild(cb); tgl.appendChild(document.createTextNode('自动'));
    var rf = document.createElement('button');
    rf.textContent = '刷新登录态';
    rf.title = '登录态过期时点这里（会借用浏览器里已登录的小米账号）';
    rf.style.cssText = 'padding:5px 10px;border:1px solid #d8dde5;background:#f7f8fa;color:#1a1a1a;' +
      'border-radius:8px;cursor:pointer;font-size:12.5px';
    rf.onclick = function () { refreshCred().catch(function () {}); };
    var gl = document.createElement('button');
    gl.textContent = '去小米登录';
    gl.title = '在新标签打开小米登录页；登完回来点「刷新登录态」';
    gl.style.cssText = 'padding:5px 10px;border:1px solid #d8dde5;background:#f7f8fa;color:#1a1a1a;' +
      'border-radius:8px;cursor:pointer;font-size:12.5px';
    gl.onclick = function () {
      try { window.open('https://account.xiaomi.com/pass/serviceLogin?sid=mijia', '_blank'); } catch (e) {}
      setStatus('已打开小米登录页。登完回来点「刷新登录态」', 'work');
    };
    bar.appendChild(btnEl); bar.appendChild(tgl); bar.appendChild(rf); bar.appendChild(gl);

    var helpBox = document.createElement('div');
    helpBox.style.cssText = 'display:none;margin-top:8px;padding:6px 8px;background:#f6f8fb;' +
      'border-radius:8px;color:#3a4450;white-space:pre-line;font-size:12px';
    helpBox.textContent = '交流反馈进群 添加：ezerrrr (ezer小小ai助手真人版）';
    var legalBox = document.createElement('div');
    legalBox.style.cssText = 'display:none;margin-top:8px;padding:6px 8px;background:#f6f8fb;' +
      'border-radius:8px;color:#3a4450;white-space:pre-line;font-size:12px';
    legalBox.textContent = [
      '非小米官方产品，与小米公司及其关联公司无关，未经其授权或背书。',
      '只用你自己的小米账号在本机浏览器运行，数据只发小米官方接口，',
      '不经过第三方、不采集上传。',
      '自动化可能失效，不承诺可用性，风险自负。',
      '安装或继续使用即表示已阅读并接受以上内容。'
    ].join('\n');
    var foot = document.createElement('div');
    foot.style.cssText = 'margin-top:8px;display:flex;gap:12px;align-items:center';
    function footToggle(label, target) {
      var b = document.createElement('span');
      b.textContent = label;
      b.style.cssText = 'color:#2f7cff;cursor:pointer;font-size:12px;user-select:none';
      b.onclick = function () {
        var show = target.style.display === 'none';
        helpBox.style.display = 'none';
        legalBox.style.display = 'none';
        target.style.display = show ? 'block' : 'none';
      };
      return b;
    }
    foot.appendChild(footToggle('使用说明', helpBox));
    foot.appendChild(footToggle('免责协议', legalBox));

    box.appendChild(head); box.appendChild(authorEl); box.appendChild(statusEl);
    box.appendChild(bar); box.appendChild(foot);
    box.appendChild(helpBox); box.appendChild(legalBox);
    document.body.appendChild(box);
    panelUp = true;
  }

  /* 收起面板（⚠ 不要删掉小圆点 —— 它是常驻入口） */
  function hideUI() {
    var el = document.getElementById(BOX_ID);
    if (el && el.parentNode) el.parentNode.removeChild(el);
    box = null; statusEl = null; btnEl = null;
    alerted = false;
    panelUp = false;
    if (dotEl) { dotEl.style.opacity = expired ? '.95' : '.45'; dotEl.style.background = dotColor; }
  }
  /* 手动叫出（Ctrl+Alt+L / 悬停小圆点）：给人看的状态，不是自动流程的状态 */
  function showUI() {
    if (document.getElementById(BOX_ID)) return;
    buildUI();
    if (expired) setStatus('小米登录态已过期。点「去小米登录」登一次，回来点「刷新登录态」', 'err');
    else if (pinPad()) setStatus('检测到登录界面，可点下方按钮手动取码', 'work');
    else if (inputPad()) setStatus('中枢连接断开，会自动补一个登录码重连', 'work');
    else if (looksLoggedIn()) setStatus('已登录。登录态过期时点「刷新登录态」', 'ok');
    else setStatus('待命中。会在出现登录界面时自动取码。', 'work');
  }

  /* 页面看起来已经是登录后的界面（没有键盘，但有自动化的内容） */
  function looksLoggedIn() {
    if (pinPad()) return false;
    var b = document.body;
    if (!b) return false;
    var t = b.innerText || '';
    return /自动化|中枢网关|设备列表/.test(t);
  }

  function setStatus(text, kind, onClick) {
    if (!statusEl) return;
    statusEl.textContent = text;
    statusEl.style.color = kind === 'err' ? '#d93025' : (kind === 'ok' ? '#2fa84f' :
      (kind === 'warn' ? '#c46a00' : '#5a6472'));
    if (onClick) { statusEl.style.cursor = 'pointer'; statusEl.onclick = onClick; }
    else { statusEl.style.cursor = 'default'; statusEl.onclick = null; }
  }

  /* 默认静默：主面板不建出来，只有右下角一个小圆点。
     只有「确实卡住了」才需要人看一眼 —— 见 alertUI 的调用点。
     注意：setStatus 在 statusEl 为空时是空操作，所以静默期间的状态更新不会出错。 */
  var alerted = false;
  function alertUI(text, kind, onClick) {
    //   否则 panelUp 一直是 false，小圆点的"悬停展开"就会和面板打架。
    if (!document.getElementById(BOX_ID)) showUI();
    alerted = true;
    setStatus(text, kind, onClick);
  }

  /* -------------------------------------------------------------- 手动兜底 */
  function manualBind() {
    document.addEventListener('keydown', function (e) {
      if (!pinPad()) return;
      if (e.key >= '0' && e.key <= '9') { clickKey(e.key); }
      else if (e.key === 'Backspace') {
        var d = document.querySelector('.pin-delete');
        if (d) d.click();
      }
    }, true);
    document.addEventListener('paste', function (e) {
      if (!pinPad()) return;
      var t = (e.clipboardData || window.clipboardData).getData('text') || '';
      var code = (t.match(/\d/g) || []).join('').slice(0, 6);
      if (code.length === 6) { e.preventDefault(); fillCode(code); }
    }, true);
  }

  /* ---------------------------------------------------------------- 启动 */
  /* 清掉旧版（v1.x）留下的界面。
     旧版和新版【同名不同源】，篡改猴会把两个都注入到页面上，
     于是右下角会同时冒出抓包窗口。旧版用 mgg-root / mgg-bubble /
     mgg-mask 这些 id，和我们完全不冲突，所以不会互相覆盖，得主动删。
     这一步只是让旧版"看不见" —— 真正的卸载要在篡改猴管理页里做。 */
  function removeOldVersionUI() {
    var ids = ['mgg-root', 'mgg-bubble', 'mgg-card', 'mgg-mask', 'mgg-modal'];
    //   的一律删掉"—— 而新加的小圆点 id 叫 `mgg-auto-login-dot`，正好踩中，
    //   会被它自己删掉（旧版清理每 500ms 跑一次，盯 12 秒）。
    //   所以这里必须把**我们自己的**两个 id 一起排除。
    var MINE = { 'mgg-auto-login': 1, 'mgg-auto-login-dot': 1 };
    function sweep() {
      var hit = false;
      for (var i = 0; i < ids.length; i++) {
        var el = document.getElementById(ids[i]);
        if (el && el.parentNode) { el.parentNode.removeChild(el); hit = true; }
      }
      var racks = document.querySelectorAll('[class*="mgg-"], [id^="mgg-"]');
      for (var j = 0; j < racks.length; j++) {
        var e = racks[j];
        if (MINE[e.id]) continue;              // ← 自己人，别动
        if (e.parentNode) { e.parentNode.removeChild(e); hit = true; }
      }
      return hit;
    }
    sweep();
    // 旧版可能会晚一点才建界面，所以盯一小会儿
    var n = 0;
    var t = setInterval(function () {
      sweep();
      if (++n >= 24) clearInterval(t);   // 盯约 12 秒
    }, 500);
  }

  function isGeekPage() {
    try {
      //   杜绝「局域网其它页面恰好有同名输入框」的误触发。
      if (/米家自动化极客版/.test(document.title || '')) return true;
      if ((pinPad() || inputPad()) &&
          (/米家自动化极客版/.test(document.title || '') ||
           (document.body && /米家自动化极客版/.test(document.body.innerText || '')))) return true;
      if (document.body && /米家自动化极客版/.test(document.body.innerText || '')) return true;
    } catch (e) {}
    return false;
  }

  function boot() {
    if (!document.body) return setTimeout(boot, 200);
    purgeLegacyCfg();          // ★ 清掉旧版遗留在 localStorage/GM 里的凭据
    removeOldVersionUI();

    //   （每 500ms 查一次），确认是极客版才启动；超时仍不是 → 静默退出。
    var waited = 0;
    var identify = setInterval(function () {
      waited += 500;
      if (isGeekPage()) { clearInterval(identify); startCore(); return; }
      if (waited >= 10000) { clearInterval(identify); return; }
    }, 500);
  }

  function startCore() {
    try {                      // SHA-1 自检（标准向量 abc）
      var t = sha1Bytes(strToBytes('abc')), hx = '';
      for (var i = 0; i < 20; i++) hx += ('0' + t[i].toString(16)).slice(-2);
      if (hx !== 'a9993e364706816aba3e25717850c26c9cd0d89d')
        console.warn('[极客版自动登录] SHA-1 自检失败：', hx);
    } catch (e) {}
    //   因为后面任何一步失败（取码失败、页面进不去）都得有地方可点。
    buildDot();
    manualBind();
    showUI(); // ★ Ezer 分发版：打开页面即亮出卡片（作者/使用说明/免责都在卡上）
    var tries = 0;
    var timer = setInterval(function () {
      tries++;
      // 两种输码界面都算：首次登录的虚拟键盘、断连后的输入框
      if (readyPad()) { clearInterval(timer); autoLogin('就绪'); return; }
      // 打开时就已经是登录后的界面：直接收手，什么都不用做
      if (tries >= 10 && looksLoggedIn()) { clearInterval(timer); return; }
      if (tries > 40) clearInterval(timer);
    }, 300);
    var mo = new MutationObserver(function () {
      if (readyPad() && !busy && !paused) autoLogin('DOM变化');
    });
    try { mo.observe(document.documentElement, { childList: true, subtree: true }); } catch (e) {}
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
  else boot();

  window.MGG = {
    cfg: CFG, getPasscode: getPasscode, autoLogin: autoLogin, fillCode: fillCode,
    pinPad: pinPad, inputPad: inputPad, readyPad: readyPad,
    refresh: refreshCred, mint: function () { return mintToken(CFG); },
    findDevice: resolveDid, listDevices: listDevices,
    show: showUI, hide: hideUI, alert: alertUI,
    //   expired   当前是否判定为"登录态过期"（小圆点红不红就是它）
    //   setExpired(v)  手动置位/清除（想自己试一下就调它）
    //   mintNote  最近一次续期为什么没成（result=verify / no-json / 网络…）
    isExpired: function () { return expired; },
    setExpired: setExpired,
    mintNote: function () { return lastMintNote; },
    test: function () { return getPasscode().then(function (c) { console.log('取码成功', c); return c; }); }
  };

  // Ctrl+Alt+L 手动叫出/收起面板（平时主面板是藏着的，不会挡操作；
  // 小圆点则一直常驻，作为"永远有地方可点"的兜底入口）
  document.addEventListener('keydown', function (e) {
    if (e.ctrlKey && e.altKey && (e.key === 'l' || e.key === 'L')) {
      if (document.getElementById('mgg-auto-login')) hideUI(); else showUI();
    }
  }, true);
})();