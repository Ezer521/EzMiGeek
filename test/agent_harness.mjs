// agent_harness.mjs —— 真执行 agent.js 的行为验证（node vm + 假 DOM）。
//
// 由 test/review_fixes_test.dart 通过 Process.run('node', …) 调起。
// 场景断言都在这里做（JS 侧最贴近真实浏览器语义），输出 JSON：
//   { ok: true, results: [ {name, pass, detail} … ] }
// 任何场景挂掉 ok=false、detail 带原因。
import vm from 'node:vm';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const src = fs.readFileSync(path.join(here, '..', 'assets', 'agent.js'), 'utf8');

/* ── 假 DOM ─────────────────────────────────────────────── */
function makePinNumber(label) {
  const listeners = {};
  const el = {
    innerText: label,
    style: {},
    // 宿主真点击路径（CDP）不走这里；这里是页面内监听器能看到的合成事件。
    listeners,
    syntheticClicks: 0,
    nativeClickCalls: 0,
    addEventListener(type, fn) { (listeners[type] ||= []).push(fn); },
    dispatchEvent(ev) {
      for (const fn of listeners[ev.type] || []) fn(ev);
      if (ev.type === 'click') el.syntheticClicks += 1;
      return true;
    },
    click() { el.nativeClickCalls += 1; }, // 旧 bug 会补这一刀；修复后必须为 0
    getBoundingClientRect() { return { left: 10, top: 20, width: 30, height: 30 }; },
  };
  return el;
}

function makeCtx({ host, href, target, pinNumbers = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'].map(makePinNumber) }) {
  const doc = {
    readyState: 'complete',
    body: { appendChild() {}, innerText: '' },
    documentElement: { nodeName: 'HTML' },
    getElementById: () => null,
    createElement: () => ({ style: {}, appendChild() {}, textContent: '' }),
    querySelector: () => null,
    querySelectorAll: (sel) =>
      sel === '.pin-number' ? pinNumbers : [],
    addEventListener() {},
    activeElement: null,
  };
  const sandbox = {
    console,
    JSON,
    Date,
    Math,
    Promise,
    String,
    Number,
    RegExp,
    Object,
    Array,
    Error,
    TypeError,
    setTimeout: (fn) => fn(), // fill() 的逐键节奏立刻跑完
    URL,
    location: {
      hostname: host,
      href,
      origin: new URL(href).origin,
    },
    document: doc,
    Event: class { constructor(type) { this.type = type; } },
    MouseEvent: class { constructor(type) { this.type = type; } },
    PointerEvent: class { constructor(type) { this.type = type; } },
    MutationObserver: class { observe() {} },
  };
  sandbox.window = sandbox;
  if (target != null) sandbox.window.__EzMiGeekTarget = target;
  return vm.createContext(sandbox);
}

function install(ctx) {
  vm.runInContext(src, ctx, { filename: 'agent.js' });
}

const results = [];
function check(name, pass, detail = '') {
  results.push({ name, pass, detail });
}

/* ── 场景 ─────────────────────────────────────────────── */
// 1. 公网 IP、无目标钉：agent 必须连 __EzMiGeek__ 都不挂。
{
  const ctx = makeCtx({ host: '8.8.8.8', href: 'https://8.8.8.8/x' });
  install(ctx);
  check('公网IP无目标 → 完全不挂agent',
    vm.runInContext('typeof window.__EzMiGeek__', ctx) === 'undefined');
}

// 2. 私网 IP、无目标钉（老宿主路径的兼容面）：要挂上。
{
  const ctx = makeCtx({ host: '192.168.31.1', href: 'http://192.168.31.1:8086/' });
  install(ctx);
  check('私网IP无目标 → 正常挂载',
    vm.runInContext('window.__EzMiGeek__ && window.__EzMiGeek__.v', ctx) === 'agent-3');
}

// 3. 钉了本轮目标、页面就是目标 origin：挂上。
{
  const ctx = makeCtx({
    host: '192.168.31.1', href: 'http://192.168.31.1:8086/',
    target: 'http://192.168.31.1:8086/',
  });
  install(ctx);
  check('钉目标+同origin → 挂载',
    vm.runInContext('window.__EzMiGeek__ && window.__EzMiGeek__.v', ctx) === 'agent-3');
}

// 4. 钉了本轮目标、用户把标签页导航到同网段别的 IP：必须安静。
{
  const ctx = makeCtx({
    host: '192.168.31.2', href: 'http://192.168.31.2/admin',
    target: 'http://192.168.31.1:8086/',
  });
  install(ctx);
  check('钉目标+别的IP → 完全不挂agent',
    vm.runInContext('typeof window.__EzMiGeek__', ctx) === 'undefined');
}

// 5. 手动键盘输一个数字：普通 click 监听器恰好收到一次点击，
//    且绝不补 el.click() 那一刀（旧 bug = 双击数字）。
{
  const ctx = makeCtx({ host: '192.168.31.1', href: 'http://192.168.31.1:8086/' });
  const doc = ctx.document;
  const handlers = {};
  doc.addEventListener = (t, fn) => { (handlers[t] ||= []).push(fn); };
  install(ctx);
  check('键盘数字5 → click监听器恰好1次、无el.click补刀', (() => {
    for (const fn of handlers.keydown || []) {
      fn({ ctrlKey: false, altKey: false, key: '5' });
    }
    const el = doc.querySelectorAll('.pin-number').find((e) => e.innerText === '5');
    return el.syntheticClicks === 1 && el.nativeClickCalls === 0;
  })());
}

// 6. 钉了目标、装好之后 location 被换成别的 origin，fill() 必须拒填。
{
  const ctx = makeCtx({
    host: '192.168.31.1', href: 'http://192.168.31.1:8086/',
    target: 'http://192.168.31.1:8086/',
  });
  install(ctx);
  ctx.location.href = 'http://192.168.31.9/';
  ctx.location.origin = 'http://192.168.31.9';
  const res = await vm.runInContext('window.__EzMiGeek__.fill("123456")', ctx);
  const marks = vm.runInContext('window.__EzMiGeek__.marks()', ctx);
  check('换origin后fill → 拒填(wrong-origin)', res === false && marks.lastFillResult === 'wrong-origin');
}

// 7. 同 origin 下 fill 走键盘路径：6 键逐个真点、一次不多。
{
  const ctx = makeCtx({ host: '192.168.31.1', href: 'http://192.168.31.1:8086/' });
  const doc = ctx.document;
  install(ctx);
  const res = await vm.runInContext('window.__EzMiGeek__.fill("102030")', ctx);
  const marks = vm.runInContext('window.__EzMiGeek__.marks()', ctx);
  const clicks = doc.querySelectorAll('.pin-number').map((e) => e.syntheticClicks);
  check('同origin填102030 → keys路径+每键恰好1击',
    res === true && marks.lastFillResult === 'keys' &&
    clicks.join(',') === '1,1,1,0,0,0,0,0,0,3',
    `res=${res} marks=${marks.lastFillResult} clicks=${clicks.join(',')}`);
}

/* ── 汇总 ─────────────────────────────────────────────── */
const ok = results.every((r) => r.pass);
process.stdout.write(JSON.stringify({ ok, results }));
if (!ok) process.exitCode = 1;
