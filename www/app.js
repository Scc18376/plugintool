/* PluginTool 前端逻辑 — 原生桥优先，浏览器环境自动降级 */
(function () {
  'use strict';

  var PUBKEY = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINjCL3phs9M/QoqIJfYUv5myfStXoMyagfg7tfuUO+Yb baby@minis-sandbox';
  var NATIVE = !!window.__PT_NATIVE__ && !!(window.pt);
  var $ = function (id) { return document.getElementById(id); };

  function call(action, data) {
    if (NATIVE) return window.pt(action, data || {});
    var mock = {
      hostInfo: { name: '香港', host: '165.99.43.34', port: 22, user: 'root',
        fingerprint: 'SHA256:UILGXdkSdzucU1CsN3OajdBr+73g5PvTsdtGMoZfwLg',
        auth: 'publickey', keyFile: 'id_ed25519' },
      sshCommand: { cmd: 'ssh -i ~/.ssh/id_ed25519 -p 22 root@165.99.43.34' },
      deviceInfo: { model: 'browser', name: navigator.platform, system: navigator.userAgent, idiom: 0, scale: 1 },
      pingSSH: { ok: false, banner: '', error: '浏览器预览模式：无原生 socket' },
      copy: { ok: true }, paste: { text: '' }, openURL: { ok: false },
      toast: { ok: true }, vibrate: { ok: true }, exitApp: { ok: true }
    };
    return Promise.resolve(mock[action] || { ok: false, error: 'no native' });
  }

  var logEl = $('log');
  function log(line) {
    var t = new Date().toTimeString().slice(0, 8);
    logEl.textContent += '\n[' + t + '] ' + line;
    logEl.scrollTop = logEl.scrollHeight;
  }
  function setStatus(text, cls) {
    var s = $('status'); s.textContent = text;
    s.className = 'status' + (cls ? ' ' + cls : '');
  }
  function setDot(cls) { $('stateDot').className = 'dot' + (cls ? ' ' + cls : ''); }

  // 主机信息
  call('hostInfo').then(function (h) {
    $('hostAddr').textContent = h.host + ':' + h.port;
    $('hostUser').textContent = h.user;
    $('portVal').textContent = h.port;
    $('fp').textContent = h.fingerprint;
    $('netBadge').textContent = NATIVE ? '原生' : '预览';
    $('netBadge').className = 'badge' + (NATIVE ? ' on' : '');
    log('host loaded: ' + h.name + ' ' + h.user + '@' + h.host + ':' + h.port + ' (' + h.auth + ')');
    if (!NATIVE) setStatus('浏览器预览模式');
  });

  // 连接探测
  $('btnConnect').addEventListener('click', function () {
    var btn = this;
    btn.disabled = true;
    setDot('busy');
    setStatus('连接中…');
    log('probing ' + $('hostAddr').textContent + ' …');
    var t0 = Date.now();
    call('pingSSH', { timeout: 6 }).then(function (r) {
      var ms = Date.now() - t0;
      btn.disabled = false;
      if (r.ok) {
        setDot('ok');
        setStatus('已连接 · ' + ms + 'ms', 'ok');
        $('netBadge').textContent = '在线';
        $('netBadge').className = 'badge on';
        log('OK  ' + ms + 'ms  banner: ' + (r.banner || '(none)'));
        call('vibrate');
      } else {
        setDot('err');
        setStatus('连接失败 · ' + (r.error || 'unknown'), 'err');
        $('netBadge').textContent = '离线';
        $('netBadge').className = 'badge off';
        log('FAIL ' + (r.error || ''));
      }
    }).catch(function (e) {
      btn.disabled = false;
      setDot('err');
      setStatus('出错: ' + e, 'err');
      log('ERR ' + e);
    });
  });

  // 复制 ssh 命令
  $('btnCmd').addEventListener('click', function () {
    call('sshCommand').then(function (r) {
      call('copy', { text: r.cmd }).then(function () {
        log('copied: ' + r.cmd);
        call('toast', { text: '已复制 ssh 命令' });
      });
    });
  });

  // 复制公钥
  $('btnCopyPub').addEventListener('click', function () {
    call('copy', { text: PUBKEY }).then(function () {
      log('copied pubkey');
      call('toast', { text: '已复制公钥' });
    });
  });

  $('btnClear').addEventListener('click', function () { logEl.textContent = 'cleared.'; });
  $('btnInfo').addEventListener('click', function () {
    call('deviceInfo').then(function (d) {
      log('device: ' + JSON.stringify(d));
      call('toast', { text: d.model + ' · ' + d.system });
    });
  });
  $('btnExit').addEventListener('click', function () { call('exitApp'); });

  document.addEventListener('touchstart', function () {}, { passive: true });
})();
