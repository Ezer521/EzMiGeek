/* ============================================================================
   米家极客版 · 页面侧 agent（由宿主通过 CDP 注入）
   ----------------------------------------------------------------------------
   跟原油猴脚本比，这里【只做 DOM】，一行网络代码都没有：
     取码在宿主机上做（浏览器页面是 http://192.168.x.x，直连小米云必被 CORS 拦）。
     宿主拿到 6 位码后调 __EzMiGeek__.fill(code)。

   ★ 注入时刻的实测事实（P0，2026-09-16）：
     脚本跑起来时 document.readyState = "loading"，
     document.documentElement 和 document.body 【都还不存在】。
     所以 MutationObserver 必须挂 document，不能挂 documentElement。
     （原油猴脚本靠 @run-at document-idle + setTimeout(boot,200) 绕开了这件事。）

   界面约定（沿用用户要求，别改回去）：平时页面上一根毛都看不到，
   只有真的失败了才建气泡；成功后 removeChild 真删节点。
   ========================================================================== */
(function () {
  'use strict';

  /* --------------------------------------------------------------------------
     只在【本轮目标页】里干活。
     注入是注册在浏览器上的，会对每一个新 document 生效 ——
     包括首次登录时打开的小米账号登录页、以及用户手输的任何网址。
     在那些页面上它必须彻底安静：尤其不能抢 Ctrl+Alt+L、不能拦 paste。
     两道闸（审查 2026-10-06）：
       1. 局域网 IP / localhost 才考虑干活（公网 IP 不算局域网页面）；
       2. 宿主注入时钉进来 window.__EzMiGeekTarget（本轮中枢页 origin），
          钉了就只认这个 origin —— 用户拿这个受控标签页去逛同网段其他
          IP 网页（路由器后台、别的设备面板）时，agent 连 __EzMiGeek__
          都不挂，取码和填码根本无从触发。
     ------------------------------------------------------------------------ */
  var host = location.hostname || '';
  /* 局域网闸收紧（审查二轮）：旧正则匹配任意 IPv4，公网地址（8.8.8.8 之类）
     也放行。中枢只会在私网段 —— 只认私网 IPv4 + localhost，
     公网 IP 网页无论有没有钉目标一律安静。 */
  var isLanPage = host === 'localhost' ||
    /^10\./.test(host) ||
    /^192\.168\./.test(host) ||
    /^127\./.test(host) ||
    /^172\.(1[6-9]|2\d|3[01])\./.test(host);
  if (!isLanPage) return;

  var TARGET = (typeof window.__EzMiGeekTarget === 'string')
    ? window.__EzMiGeekTarget : '';
  if (TARGET) {
    var targetOk = false;
    try { targetOk = location.origin === new URL(TARGET).origin; } catch (e) { }
    if (!targetOk) return;
  }

  var V = 'agent-3';
  var rec = {
    v: V, tInject: Date.now(), href: location.href,
    readyState: document.readyState, moRoot: null, moHits: 0,
    sawPinNumber: false, sawPinInput: false,
    lastFillAt: null, lastFillResult: null, error: null
  };

  /* ------------------------------------------------------------ 两套输码界面 */
  /* 界面 A：首次登录的虚拟键盘（10 个 .pin-number） */
  function pinPad() {
    var ns = document.querySelectorAll('.pin-number');
    return (ns && ns.length >= 6) ? ns : null;
  }
  /* 界面 B：中枢连接断开后的真实 <input class="pin-code-input" maxlength=6> */
  function inputPad() {
    var el = document.querySelector('input.pin-code-input');
    if (!el || el.disabled || el.readOnly) return null;
    try {
      var r = el.getBoundingClientRect();
      if (r && r.width === 0 && r.height === 0) return null;
    } catch (e) { }
    return el;
  }
  function pad() {
    if (pinPad()) return 'pin-number';
    if (inputPad()) return 'input.pin-code-input';
    return 'none';
  }
  function probePad() {
    if (!rec.sawPinNumber && pinPad()) rec.sawPinNumber = true;
    if (!rec.sawPinInput && inputPad()) rec.sawPinInput = true;
  }

  /* --------------------------------------------------------------- 填码 */
  /* React 受控 input：直接 el.value = x 会被 value tracker 当"没变"，
     onChange 不触发 → 必须走原型上的原生 setter，再派发 input 事件。 */
  function setInputValue(el, code) {
    try {
      var d = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
      if (d && d.set) d.set.call(el, code); else el.value = code;
    } catch (e) { el.value = code; }
    try { el.dispatchEvent(new Event('input', { bubbles: true })); } catch (e) { }
    try { el.dispatchEvent(new Event('change', { bubbles: true })); } catch (e) { }
  }

  function clickKey(ch) {
    var ns = document.querySelectorAll('.pin-number');
    for (var i = 0; i < ns.length; i++) {
      if ((ns[i].innerText || '').replace(/\s/g, '') === ch) {
        var el = ns[i], types = ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click'];
        for (var j = 0; j < types.length; j++) {
          var t = types[j];
          var Ev = t.indexOf('pointer') === 0 ? (window.PointerEvent || MouseEvent) : MouseEvent;
          try {
            el.dispatchEvent(new Ev(t, { bubbles: true, cancelable: true, view: window, button: 0 }));
          } catch (e) { }
        }
        /* ★ 上面的事件序列里已经含 click，不能再补 el.click() ——
           普通监听器一个数字会收到两次点击，等于输错码（审查 2026-10-06）。 */
        return true;
      }
    }
    return false;
  }

  function fill(code) {
    return new Promise(function (resolve) {
      /* 填码前再核对一次 origin：宿主 CDP 只会往本轮标签页发 fill，
         这里防的是页面内手动输入/粘贴兜底被拿去别处用。 */
      if (TARGET) {
        var ok = false;
        try { ok = location.origin === new URL(TARGET).origin; } catch (e) { }
        if (!ok) { rec.lastFillResult = 'wrong-origin'; return resolve(false); }
      }
      code = String(code == null ? '' : code).replace(/\D/g, '');
      if (code.length !== 6) { rec.lastFillResult = 'bad-code'; return resolve(false); }
      var inp = inputPad();
      if (inp) {
        setInputValue(inp, code);
        rec.lastFillAt = Date.now(); rec.lastFillResult = 'input';
        return resolve(true);
      }
      if (!pinPad()) { rec.lastFillResult = 'no-pad'; return resolve(false); }
      var i = 0;
      (function step() {
        if (i >= code.length) {
          rec.lastFillAt = Date.now(); rec.lastFillResult = 'keys';
          return resolve(true);
        }
        if (!clickKey(code.charAt(i))) { rec.lastFillResult = 'key-missing'; return resolve(false); }
        i++;
        setTimeout(step, 220);
      })();
    });
  }

  /* ------------------------------------------------------------------------
     给宿主用的「真实输入」接口
     ------------------------------------------------------------------------
     ★ 实测（2026-09-16）：靠 dispatchEvent 合成的 pointerdown/click 【页面不认】——
       fill() 返回 true，但登录界面毫无反应，6 位码根本没被吃进去。
       原因多半是页面的事件处理器看了 isTrusted。
       好在我们有 CDP，可以直接发【真·鼠标事件】（Input.dispatchMouseEvent），
       比合成事件更接近真人。宿主负责点击，这里只提供坐标和兜底。
     ---------------------------------------------------------------------- */
  function rectOf(el) {
    var r = el.getBoundingClientRect();
    return { x: r.left + r.width / 2, y: r.top + r.height / 2, w: r.width, h: r.height };
  }

  /* 返回某个数字键的中心坐标（CSS 像素，视口坐标 —— 正是 CDP 要的坐标系） */
  function keyRect(ch) {
    var ns = document.querySelectorAll('.pin-number');
    for (var i = 0; i < ns.length; i++) {
      if ((ns[i].innerText || '').replace(/\s/g, '') === String(ch)) {
        return rectOf(ns[i]);
      }
    }
    return null;
  }

  function inputRect() {
    var el = inputPad();
    return el ? rectOf(el) : null;
  }

  function focusInput() {
    var el = inputPad();
    if (!el) return false;
    try { el.focus(); el.select && el.select(); } catch (e) { }
    return document.activeElement === el;
  }

  /* 兜底：页面不认插入的文本时，走 React 原生 setter */
  function setInputValueByApi(code) {
    var el = inputPad();
    if (!el) return false;
    setInputValue(el, code);
    return true;
  }

  /* 诊断用：把输码相关的 DOM 片段和提示文案抠出来对比 */
  function dump() {
    function cut(el, n) {
      if (!el) return null;
      var s = el.outerHTML || '';
      return s.length > n ? s.slice(0, n) + '…' : s;
    }
    var tip = document.querySelector('.pin-tip');
    return {
      tip: tip ? (tip.innerText || '').trim() : null,
      keyboard: cut(document.querySelector('.pin-keyboard'), 700),
      pinCode: cut(document.querySelector('.pin-code'), 700),
      active: document.activeElement ? (document.activeElement.tagName + '.' +
        (document.activeElement.className || '')) : null
    };
  }

  /* ----------------------------------------------------------- 气泡（按需） */
  var box = null, statusEl = null;
  function buildUI() {
    if (document.getElementById('ezmigeek-agent')) return;
    if (!document.body) return;
    box = document.createElement('div');
    box.id = 'ezmigeek-agent';
    box.style.cssText = 'position:fixed;right:16px;bottom:16px;z-index:2147483647;' +
      'font:13px/1.6 -apple-system,"Segoe UI","Microsoft YaHei",sans-serif;' +
      'background:#fff;color:#1a1a1a;border:1px solid #e3e6eb;border-radius:12px;' +
      'box-shadow:0 8px 26px rgba(15,30,60,.16);padding:10px 12px;max-width:320px';
    var head = document.createElement('div');
    head.style.cssText = 'font-weight:600;margin-bottom:4px';
    head.textContent = '极客版自动登录';
    statusEl = document.createElement('div');
    statusEl.style.cssText = 'color:#5a6472;word-break:break-all';
    statusEl.textContent = '准备中…';
    box.appendChild(head); box.appendChild(statusEl);
    document.body.appendChild(box);
  }
  function note(text, kind) {
    buildUI();
    if (!statusEl) return;
    statusEl.textContent = String(text);
    statusEl.style.color = kind === 'err' ? '#d93025'
      : (kind === 'ok' ? '#2fa84f' : (kind === 'warn' ? '#c46a00' : '#5a6472'));
  }
  function hide() {
    var el = document.getElementById('ezmigeek-agent');
    if (el && el.parentNode) el.parentNode.removeChild(el);
    box = null; statusEl = null;
  }
  function show() {
    if (document.getElementById('ezmigeek-agent')) return hide();
    buildUI();
    var p = pad();
    if (p === 'pin-number') note('检测到首次登录界面', 'work');
    else if (p === 'input.pin-code-input') note('中枢连接断开，会自动补一个登录码', 'work');
    else note('待命中', 'work');
  }

  /* --------------------------------------------------- 手动兜底（保留逃生口） */
  function bindManual() {
    document.addEventListener('keydown', function (e) {
      if (e.ctrlKey && e.altKey && (e.key === 'l' || e.key === 'L')) { show(); return; }
      if (!pinPad()) return;
      if (e.key >= '0' && e.key <= '9') { clickKey(e.key); }
      else if (e.key === 'Backspace') {
        var d = document.querySelector('.pin-delete');
        if (d) { try { d.click(); } catch (err) { } }
      }
    }, true);
    document.addEventListener('paste', function (e) {
      if (!pinPad()) return;
      var t = '';
      try { t = (e.clipboardData || window.clipboardData).getData('text') || ''; } catch (err) { }
      var code = (t.match(/\d/g) || []).join('').slice(0, 6);
      if (code.length === 6) { e.preventDefault(); fill(code); }
    }, true);
  }

  /* ------------------------------------------------------------------ 启动 */
  window.__EzMiGeek__ = {
    v: V,
    pad: pad,
    fill: fill,
    /* 给宿主的「真实输入」接口（CDP Input.dispatchMouseEvent / insertText 用） */
    keyRect: keyRect,
    inputRect: inputRect,
    focusInput: focusInput,
    setInputValueByApi: setInputValueByApi,
    dump: dump,
    note: note,
    hide: hide,
    show: show,
    marks: function () { return rec; },
    counts: function () {
      function n(s) { return document.querySelectorAll(s).length; }
      return {
        pinNumber: n('.pin-number'), pinCodeInput: n('input.pin-code-input'),
        pinKeyboard: n('.pin-keyboard'), pinCode: n('.pin-code'),
        bodyText: (document.body ? (document.body.innerText || '') : '').slice(0, 160)
      };
    }
  };

  try {
    probePad();
    bindManual();
    /* ★ 必须挂 document：注入时刻 documentElement 还不存在（P0 实测） */
    var root = document.documentElement || document;
    rec.moRoot = (root === document) ? 'document' : 'documentElement';
    var mo = new MutationObserver(function () { rec.moHits++; probePad(); });
    mo.observe(root, { childList: true, subtree: true });
  } catch (e) {
    rec.error = String(e && e.message ? e.message : e);
  }
})();
