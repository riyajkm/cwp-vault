<?php
if(!isset($include_path)){echo "invalid access";exit();}
// CWP Vault admin page. Engine calls and AJAX handlers live in cwp_vault/lib.php.
require_once __DIR__ . '/cwp_vault/lib.php';
if (isset($_GET['acc']) && is_string($_GET['acc'])) { vault_dispatch($_GET['acc']); } // router fallback: same handlers as the ajax file
$cv = ['url' => 'loader_ajax.php?ajax=cwp_vault', 'csrf' => vault_csrf(), 't' => vault_lang(), 'mock' => vault_mock()];
$T = vault_lang();
$tx = function ($k) use ($T) { return h($T[$k] ?? $k); };
?>
<div id="cwp-vault">
<style>
#cwp-vault .cv-spin{display:inline-block;width:12px;height:12px;border:2px solid currentColor;border-right-color:transparent;border-radius:50%;animation:cvs .8s linear infinite;vertical-align:-2px}
@keyframes cvs{to{transform:rotate(360deg)}}
@media (prefers-reduced-motion:reduce){#cwp-vault .cv-spin{animation:none}}
#cwp-vault .cv-tile{text-align:center;padding:6px 0}
#cwp-vault .cv-tile .cv-num{font-size:24px;line-height:1.3;font-weight:600}
#cwp-vault .cv-tile .cv-lbl{color:#777}
#cwp-vault .cv-wrap{overflow-x:auto}
#cwp-vault .cv-log{max-height:480px;overflow:auto;font-size:12px;white-space:pre-wrap;word-break:break-all}
#cwp-vault .cv-pw{font-size:20px;word-break:break-all;user-select:all}
#cwp-vault .tab-content{padding-top:15px}
#cwp-vault .cv-crumb a{cursor:pointer}
#cwp-vault .cv-mt{margin-top:10px}
</style>

<h4><?= $tx('TITLE') ?></h4>
<?php if ($cv['mock']) { ?><div class="alert alert-warning"><?= $tx('MOCK_NOTE') ?></div><?php } ?>
<div id="cv-alert" aria-live="polite"></div>

<ul class="nav nav-tabs" role="tablist">
  <li class="active"><a href="#cv-dash" data-toggle="tab"><?= $tx('TAB_DASH') ?></a></li>
  <li><a href="#cv-restore" data-toggle="tab"><?= $tx('TAB_RESTORE') ?></a></li>
  <li><a href="#cv-settings" data-toggle="tab"><?= $tx('TAB_SETTINGS') ?></a></li>
  <li><a href="#cv-logs" data-toggle="tab"><?= $tx('TAB_LOGS') ?></a></li>
  <li><a href="#cv-about" data-toggle="tab"><?= $tx('TAB_ABOUT') ?></a></li>
</ul>
<div class="tab-content">
  <div class="tab-pane active" id="cv-dash"><div id="cv-dash-body"><span class="cv-spin" aria-hidden="true"></span> <?= $tx('LOADING') ?></div></div>
  <div class="tab-pane" id="cv-restore">
    <div class="form-group">
      <label for="rs-account"><?= $tx('RS_ACCOUNT') ?></label>
      <select id="rs-account" class="form-control" style="max-width:320px"></select>
    </div>
    <div id="rs-snaps"></div>
    <div id="rs-panel"></div>
    <div id="rs-result" aria-live="polite"></div>
  </div>
  <div class="tab-pane" id="cv-settings"><div id="cv-settings-body"><span class="cv-spin" aria-hidden="true"></span> <?= $tx('LOADING') ?></div></div>
  <div class="tab-pane" id="cv-logs">
    <div class="form-inline" style="margin-bottom:10px">
      <label for="lg-filter" class="sr-only"><?= $tx('LG_FILTER') ?></label>
      <input type="text" id="lg-filter" class="form-control" placeholder="<?= $tx('LG_FILTER_PH') ?>" autocomplete="off">
      <label class="checkbox-inline" style="margin-left:10px"><input type="checkbox" id="lg-auto" checked> <?= $tx('LG_AUTO') ?></label>
      <button type="button" class="btn btn-default btn-xs" id="lg-reload" style="margin-left:10px"><?= $tx('BTN_RELOAD') ?></button>
    </div>
    <pre class="cv-log" id="lg-out" tabindex="0"></pre>
  </div>
  <div class="tab-pane" id="cv-about">
    <div class="panel panel-default"><div class="panel-heading"><?= $tx('TITLE') ?></div><div class="panel-body">
      <p><?= $tx('AB_TEXT') ?></p>
      <p><strong><?= $tx('AB_VERSION') ?>:</strong> <span id="ab-version">-</span></p>
      <ul>
        <li><a href="https://github.com/riyajkm/cwp-vault" target="_blank" rel="noopener noreferrer"><?= $tx('AB_REPO') ?></a></li>
        <li><a href="https://github.com/riyajkm/cwp-vault#readme" target="_blank" rel="noopener noreferrer"><?= $tx('AB_DOCS') ?></a></li>
        <li><a href="https://github.com/riyajkm/cwp-vault/issues/new/choose" target="_blank" rel="noopener noreferrer"><?= $tx('AB_ISSUE') ?></a></li>
      </ul>
    </div></div>
  </div>
</div>

<script>
window.CWPV = <?= vault_json($cv) ?>;
(function ($) {
  var C = window.CWPV, T = C.t;
  var S = {status: null, sched: null, timer: null, logTimer: null, cfg: null, orig: {}, secrets: null};
  var R = {account: '', snaps: [], snap: null, path: '', sel: {}};
  var W = {step: 0, pw: null};

  function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return {'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'}[c]; }); }
  function tt(k, r) { var s = T[k] || k; if (r) { for (var i in r) { s = s.split('{' + i + '}').join(r[i]); } } return s; }
  function L(k, r) { var q = {}; for (var i in (r || {})) { q[i] = esc(r[i]); } return tt(k, q); }
  function bytes(n) { if (n == null) { return '-'; } var u = ['B', 'KiB', 'MiB', 'GiB', 'TiB'], i = 0; n = +n; while (n >= 1024 && i < 4) { n /= 1024; i++; } return (i ? n.toFixed(1) : n) + ' ' + u[i]; }
  function dur(s) { if (s == null) { return '-'; } s = +s; return s >= 60 ? Math.floor(s / 60) + 'm ' + (s % 60) + 's' : s + 's'; }
  function ago(iso) {
    if (!iso) { return esc(tt('NEVER')); }
    var d = (Date.now() - new Date(iso).getTime()) / 1000;
    if (isNaN(d)) { return esc(iso); }
    if (d < 60) { return L('AGO_S'); }
    if (d < 3600) { return L('AGO_M', {n: Math.floor(d / 60)}); }
    if (d < 86400) { return L('AGO_H', {n: Math.floor(d / 3600)}); }
    return L('AGO_D', {n: Math.floor(d / 86400)});
  }
  function when(iso) { var d = new Date(iso); return isNaN(d) ? esc(iso) : esc(d.toLocaleString()); }
  function badge(res) {
    var m = {ok: ['success', '✔ ', 'R_OK'], failed: ['danger', '✖ ', 'R_FAILED'], running: ['info', '', 'R_RUNNING'], skipped: ['warning', '– ', 'R_SKIPPED'], never: ['default', '', 'R_NEVER']}[res] || ['default', '', 'R_NEVER'];
    return '<span class="label label-' + m[0] + '">' + (res === 'running' ? '<span class="cv-spin" aria-hidden="true"></span> ' : m[1]) + esc(tt(m[2])) + '</span>';
  }
  function alertBox(type, msg) { return '<div class="alert alert-' + type + '" role="alert">' + esc(msg) + '</div>'; }
  function notify(title, text, err) {
    if ($.gritter) { $.gritter.add({title: esc(title), text: esc(text), time: err ? 8000 : 4000}); }
    else { $('#cv-alert').html(alertBox(err ? 'danger' : 'success', title + ' ' + text)); }
  }
  function api(acc, data, post) {
    var o = {url: C.url + '&acc=' + acc, dataType: 'json', type: post ? 'POST' : 'GET', data: post ? $.extend({csrf: C.csrf}, data || {}) : (data || {})};
    // Explicit Deferred: on CWP's page .then() may not transform values (old jQuery semantics), so never rely on it.
    var d = $.Deferred();
    $.ajax(o).done(function (r) { if (r && r.ok) { d.resolve(r.data); } else { d.reject((r && r.error) || tt('E_NET')); } })
      .fail(function (x) { var m = x.responseJSON && x.responseJSON.error; d.reject(m || tt('E_NET')); });
    return d.promise();
  }
  function confirmBox(title, html, label, cb) {
    if (window.bootbox) {
      bootbox.confirm({title: esc(title), message: html, buttons: {confirm: {label: esc(label), className: 'btn-primary'}, cancel: {label: esc(tt('BTN_CANCEL')), className: 'btn-default'}}, callback: function (ok) { if (ok) { cb(); } }});
    } else if (window.confirm($('<div>').html(html).text())) { cb(); }
  }

  // ---------- Dashboard ----------
  function runningFor(a) {
    return ((S.status && S.status.running) || []).some(function (r) { return r.account === a || !r.account || r.account === 'all' || r.account === '_all'; });
  }
  function loadDash() {
    clearTimeout(S.timer);
    $.when(api('status'), S.sched ? S.sched : api('schedule')).then(function (st, sc) {
      S.status = st; S.sched = sc; renderDash(); $('#ab-version').text(st.version || '-');
      S.timer = setTimeout(loadDash, (st.running && st.running.length) ? 5000 : 60000);
    }, function (e) { $('#cv-dash-body').html(alertBox('danger', e)); S.timer = setTimeout(loadDash, 60000); });
  }
  function renderDash() {
    var st = S.status, accts = st.accounts || [], h = '';
    fillAccounts();
    if (st.configured === false) { if (!$('#w-body').length || !W.step) { $('#cv-dash-body').html(wizardHtml()); wizardBind(); } return; } // keep typed input on refresh
    var okN = accts.filter(function (a) { return a.result === 'ok'; }).length, failN = accts.filter(function (a) { return a.result === 'failed'; }).length;
    var sum = accts.reduce(function (s, a) { return s + (+a.bytes_added || 0); }, 0);
    var last = accts.concat(st.server ? [st.server] : []).filter(function (a) { return a.finished; }).sort(function (a, b) { return a.finished < b.finished ? 1 : -1; })[0];
    var next = S.sched && S.sched.next ? when(S.sched.next) : (S.sched && S.sched.lines && S.sched.lines[0] ? esc(S.sched.lines[0]) : esc(tt('NEVER')));
    var anyRun = (st.running || []).length > 0;
    function tile(n, l) { return '<div class="col-sm-3 col-xs-6"><div class="panel panel-default"><div class="panel-body cv-tile"><div class="cv-num">' + n + '</div><div class="cv-lbl">' + esc(tt(l)) + '</div></div></div></div>'; }
    h += '<div class="row">' + tile(okN + ' / ' + accts.length, 'T_ACCOUNTS') +
      tile(anyRun ? badge('running') : (last ? badge(failN ? 'failed' : last.result) + '<br><small>' + ago(last.finished) + '</small>' : badge('never')), 'T_LASTRUN') +
      tile(esc(bytes(sum)), 'T_STORED') + tile('<small>' + next + '</small>', 'T_NEXT') + '</div>';
    h += '<p><button type="button" class="btn btn-primary" data-act="backup-all"' + (anyRun ? ' disabled' : '') + '>' + esc(tt('BTN_BACKUP_ALL')) + '</button></p>';
    h += '<div class="cv-wrap"><table class="table table-striped table-hover"><thead><tr>' +
      ['TH_ACCOUNT', 'TH_LAST', 'TH_RESULT', 'TH_DURATION', 'TH_ADDED', 'TH_SNAPS', 'TH_ACTIONS'].map(function (k) { return '<th scope="col">' + esc(tt(k)) + '</th>'; }).join('') + '</tr></thead><tbody>';
    if (!accts.length) { h += '<tr><td colspan="7">' + esc(tt('NO_ACCOUNTS')) + '</td></tr>'; }
    accts.forEach(function (a) {
      var run = runningFor(a.account), res = run ? 'running' : (a.finished ? a.result : 'never');
      h += '<tr><td>' + esc(a.account) + '</td><td>' + ago(a.finished) + '</td><td>' + badge(res) +
        (a.error && res === 'failed' ? '<br><small class="text-danger">' + esc(a.error) + '</small>' : '') + '</td><td>' + esc(dur(a.duration_s)) + '</td><td>' +
        esc(bytes(a.bytes_added)) + '</td><td>' + esc(a.snapshots == null ? '-' : a.snapshots) + '</td><td>' +
        '<button type="button" class="btn btn-primary btn-xs" data-act="backup" data-acc="' + esc(a.account) + '"' + (anyRun ? ' disabled' : '') + '>' + esc(tt('BTN_BACKUP')) + '</button> ' +
        '<button type="button" class="btn btn-default btn-xs" data-act="snaps" data-acc="' + esc(a.account) + '">' + esc(tt('BTN_SNAPS')) + '</button></td></tr>';
    });
    $('#cv-dash-body').html(h + '</tbody></table></div>');
  }
  $('#cv-dash').on('click', '[data-act]', function () {
    var b = $(this), act = b.data('act'), acc = b.data('acc') || '';
    if (act === 'snaps') { $('#rs-account').val(acc); $('a[href="#cv-restore"]').tab('show'); loadSnaps(); return; }
    if (act !== 'backup' && act !== 'backup-all') { return; }
    confirmBox(tt('BTN_BACKUP'), '<p>' + L(act === 'backup' ? 'CF_BACKUP' : 'CF_BACKUP_ALL', {a: acc}) + '</p>', tt('BTN_BACKUP'), function () {
      api('backup', {account: acc}, true).then(function () { notify(tt('BTN_BACKUP'), tt('BACKUP_STARTED'), false); setTimeout(loadDash, 1500); }, function (e) { notify(tt('E_TITLE'), e, true); });
    });
  });
  function fillAccounts() {
    var cur = $('#rs-account').val(), o = '<option value="">' + esc(tt('RS_CHOOSE')) + '</option>';
    ((S.status && S.status.accounts) || []).forEach(function (a) { o += '<option value="' + esc(a.account) + '">' + esc(a.account) + '</option>'; });
    $('#rs-account').html(o).val(cur);
  }

  // ---------- Restore ----------
  $('#rs-account').on('change', loadSnaps);
  function loadSnaps() {
    R.account = $('#rs-account').val(); R.snap = null; $('#rs-panel,#rs-result').empty();
    if (!R.account) { $('#rs-snaps').empty(); return; }
    $('#rs-snaps').html('<span class="cv-spin" aria-hidden="true"></span> ' + esc(tt('LOADING')));
    api('snapshots', {account: R.account}).then(function (list) {
      R.snaps = (list || []).sort(function (a, b) { return a.time < b.time ? 1 : -1; });
      var h = '<h5>' + esc(tt('RS_SNAPS')) + '</h5><div class="cv-wrap"><table class="table table-striped table-hover"><thead><tr>' +
        ['TH_TIME', 'TH_KIND', 'TH_DB', 'TH_SIZE', 'TH_ACTIONS'].map(function (k) { return '<th scope="col">' + esc(tt(k)) + '</th>'; }).join('') + '</tr></thead><tbody>';
      R.snaps.forEach(function (s, i) {
        h += '<tr><td>' + when(s.time) + '</td><td>' + esc(tt('K_' + s.kind)) + '</td><td>' + esc(s.db || '-') + '</td><td>' + esc(bytes(s.size)) +
          '</td><td><button type="button" class="btn btn-default btn-xs" data-i="' + i + '">' + esc(tt('BTN_SELECT')) + '</button></td></tr>';
      });
      $('#rs-snaps').html(h + '</tbody></table></div>');
    }, function (e) { $('#rs-snaps').html(alertBox('danger', e)); });
  }
  $('#rs-snaps').on('click', 'button[data-i]', function () {
    R.snap = R.snaps[+$(this).data('i')]; R.path = ''; R.sel = {}; $('#rs-result').empty();
    $(this).closest('tbody').find('tr').removeClass('info'); $(this).closest('tr').addClass('info');
    var s = R.snap, d = new Date(), ymd = d.getFullYear() + ('0' + (d.getMonth() + 1)).slice(-2) + ('0' + d.getDate()).slice(-2);
    var h = '<div class="panel panel-default"><div class="panel-heading">' + L('RS_PANEL', {k: tt('K_' + s.kind), t: new Date(s.time).toLocaleString()}) + '</div><div class="panel-body">';
    if (s.kind === 'files') { h += '<div id="rs-browser"></div><hr>'; }
    else if (s.kind === 'db') {
      var nm = ((s.db || R.account + '_db') + '_restored_' + ymd).slice(0, R.account.length + 57);
      h += '<div class="form-group"><label for="rs-dbname">' + esc(tt('RS_DBNAME')) + '</label><input type="text" id="rs-dbname" class="form-control" style="max-width:420px" value="' + esc(nm) + '" maxlength="' + (R.account.length + 57) + '" autocomplete="off">' +
        '<p class="help-block">' + L('RS_DBHELP', {a: R.account}) + '</p></div>';
    } else { h += '<p>' + esc(tt('RS_META_NOTE')) + '</p>'; }
    if (s.kind !== 'db') {
      h += '<div class="form-group"><label for="rs-target">' + esc(tt('RS_TARGET')) + '</label><input type="text" id="rs-target" class="form-control" style="max-width:420px" placeholder="' + esc(tt('RS_TARGET_PH')) + '" autocomplete="off"><p class="help-block">' + esc(tt('RS_TARGET_HELP')) + '</p></div>';
    }
    h += '<div class="checkbox"><label><input type="checkbox" id="rs-dry" checked> ' + esc(tt('RS_DRY')) + '</label><p class="help-block">' + esc(tt('RS_DRY_HELP')) + '</p></div>' +
      '<button type="button" class="btn btn-primary" id="rs-go">' + esc(tt('BTN_RESTORE')) + '</button></div></div>';
    $('#rs-panel').html(h);
    if (s.kind === 'files') { browse(''); }
  });
  function browse(path) {
    R.path = path; $('#rs-browser').html('<span class="cv-spin" aria-hidden="true"></span> ' + esc(tt('LOADING')));
    api('ls', {account: R.account, snapshot: R.snap.id, path: path}).then(function (rows) {
      var segs = path.split('/').filter(Boolean), acc = '', h = '<ol class="breadcrumb cv-crumb" style="margin-bottom:8px"><li><a data-path="">' + esc(tt('RS_ROOT')) + '</a></li>';
      segs.forEach(function (sg, i) { acc += '/' + sg; h += i === segs.length - 1 ? '<li class="active">' + esc(sg) + '</li>' : '<li><a data-path="' + esc(acc) + '">' + esc(sg) + '</a></li>'; });
      h += '</ol><div class="cv-wrap"><table class="table table-striped table-hover"><thead><tr><th scope="col"><span class="sr-only">' + esc(tt('RS_PICK')) + '</span></th>' +
        ['TH_NAME', 'TH_TYPE', 'TH_SIZE', 'TH_MODIFIED'].map(function (k) { return '<th scope="col">' + esc(tt(k)) + '</th>'; }).join('') + '</tr></thead><tbody>';
      if (!rows.length) { h += '<tr><td colspan="5">' + esc(tt('RS_EMPTY')) + '</td></tr>'; }
      rows.forEach(function (e) {
        h += '<tr><td><input type="checkbox" class="rs-pick" data-path="' + esc(e.path) + '" aria-label="' + esc(e.name) + '"' + (R.sel[e.path] ? ' checked' : '') + '></td><td>' +
          (e.type === 'dir' ? '<a class="cv-dir" data-path="' + esc(e.path) + '" href="#" >' + esc(e.name) + '/</a>' : esc(e.name)) + '</td><td>' + esc(tt('Y_' + e.type)) + '</td><td>' + (e.type === 'file' ? esc(bytes(e.size)) : '') + '</td><td>' + (e.mtime ? when(e.mtime) : '') + '</td></tr>';
      });
      $('#rs-browser').html(h + '</tbody></table></div><p class="text-muted" id="rs-count"></p>'); selCount();
    }, function (e) { $('#rs-browser').html(alertBox('danger', e)); });
  }
  function selCount() { var n = Object.keys(R.sel).length; $('#rs-count').text(n ? tt('RS_SELECTED', {n: n}) : tt('RS_NOSEL')); }
  $('#rs-panel').on('click', '.cv-crumb a, a.cv-dir', function (e) { e.preventDefault(); browse($(this).data('path') + ''); })
    .on('change', '.rs-pick', function () { var p = $(this).data('path'); if (this.checked) { R.sel[p] = 1; } else { delete R.sel[p]; } selCount(); })
    .on('click', '#rs-go', restoreConfirm);
  function restoreConfirm() {
    var s = R.snap, dry = $('#rs-dry').is(':checked'), isDb = s.kind === 'db', target = $.trim($('#rs-target').val() || ''), db = $.trim($('#rs-dbname').val() || '');
    if (isDb && !new RegExp('^' + R.account + '_[A-Za-z0-9_]{1,56}$').test(db)) { notify(tt('E_TITLE'), tt('E_DBNAME', {a: R.account}), true); $('#rs-dbname').focus(); return; }
    if (target && (target.charAt(0) !== '/' || /(^|\/)\.\.(\/|$)/.test(target))) { notify(tt('E_TITLE'), tt('E_TARGET'), true); $('#rs-target').focus(); return; }
    var paths = Object.keys(R.sel), li = [];
    li.push(L('CF_ACCOUNT', {v: R.account}), L('CF_SNAP', {v: new Date(s.time).toLocaleString() + ' (' + s.short_id + ')'}));
    if (isDb) { li.push(L('CF_DB', {v: s.db}), L('CF_NEWDB', {v: db})); }
    else {
      li.push(paths.length ? L('CF_PATHS', {n: paths.length}) + '<ul><li>' + paths.slice(0, 10).map(esc).join('</li><li>') + (paths.length > 10 ? '</li><li>…' : '') + '</li></ul>' : esc(tt('CF_ALL')));
      li.push(L('CF_TARGET', {v: target || tt('RS_TARGET_DEFAULT')}));
    }
    li.push(esc(tt(dry ? 'CF_DRY' : 'CF_REAL')));
    confirmBox(tt(dry ? 'CF_TITLE_DRY' : 'CF_TITLE'), '<ul>' + li.map(function (x) { return '<li>' + x + '</li>'; }).join('') + '</ul>', tt('BTN_RESTORE'), function () {
      $('#rs-go').prop('disabled', true).prepend('<span class="cv-spin" aria-hidden="true"></span> ');
      $('#rs-result').html('<span class="cv-spin" aria-hidden="true"></span> ' + esc(tt('RS_WORKING')));
      var data = {account: R.account, snapshot: s.id, what: s.kind, dry_run: dry ? '1' : '0'};
      if (isDb) { data.db = s.db; data.target_db = db; } else { data.paths = paths; if (target) { data.target = target; } }
      api('restore', data, true).then(function (r) {
        $('#rs-go').prop('disabled', false).find('.cv-spin').remove();
        var rows = [['RS_STATUS', r.ok ? '✔ ' + tt(dry ? 'RS_DRYOK' : 'RS_OK') : '✖ ' + tt('R_FAILED')], ['RS_JOB', r.job], ['RS_TARGETDIR', r.target], ['RS_FILES', r.files], ['RS_BYTES', r.bytes == null ? null : bytes(r.bytes)], ['RS_DURATION', r.duration_s == null ? null : dur(r.duration_s)], ['RS_ERROR', r.error]];
        $('#rs-result').html('<div class="panel panel-' + (r.ok ? 'success' : 'danger') + '"><div class="panel-heading">' + esc(tt(dry ? 'RS_DRYRESULT' : 'RS_RESULT')) + '</div><div class="panel-body"><dl class="dl-horizontal">' +
          rows.filter(function (x) { return x[1] != null && x[1] !== ''; }).map(function (x) { return '<dt>' + esc(tt(x[0])) + '</dt><dd>' + esc(x[1]) + '</dd>'; }).join('') + '</dl></div></div>');
      }, function (e) { $('#rs-go').prop('disabled', false).find('.cv-spin').remove(); $('#rs-result').html(alertBox('danger', e)); });
    });
  }

  // ---------- Settings ----------
  var GROUPS = [
    ['G_STORAGE', [['S3_ENDPOINT', 'text', 'F_ENDPOINT', 'H_ENDPOINT'], ['S3_BUCKET', 'text', 'F_BUCKET'], ['S3_PREFIX', 'text', 'F_PREFIX', 'H_PREFIX'], ['ALLOW_INSECURE', 'bool', 'F_INSECURE', 'H_INSECURE']]],
    ['KEYS'],
    ['G_CONTENT', [['BACKUP_MAIL', 'bool', 'F_MAIL'], ['BACKUP_DATABASES', 'bool', 'F_DBS'], ['BACKUP_SERVER', 'bool', 'F_SERVER']]],
    ['G_RETENTION', [['KEEP_DAILY', 'number', 'F_DAILY'], ['KEEP_WEEKLY', 'number', 'F_WEEKLY'], ['KEEP_MONTHLY', 'number', 'F_MONTHLY']]],
    ['G_PERF', [['S3_CONNECTIONS', 'number', 'F_CONN'], ['LIMIT_UPLOAD_KIB', 'number', 'F_LIMIT', 'H_LIMIT']]],
    ['G_ALERTS', [['ALERT_EMAIL', 'email', 'F_EMAIL'], ['ALERT_WEBHOOK', 'url', 'F_WEBHOOK', 'H_HTTPS'], ['HEARTBEAT_URL', 'url', 'F_HEARTBEAT', 'H_HTTPS']]]
  ];
  function field(f, v, pre) {
    var id = pre + f[0], hp = f[3] ? '<p class="help-block" id="' + id + '-h">' + esc(tt(f[3])) + '</p>' : '', d = f[3] ? ' aria-describedby="' + id + '-h"' : '';
    if (f[1] === 'bool') { return '<div class="checkbox"><label><input type="checkbox" id="' + id + '"' + (v === 'yes' ? ' checked' : '') + d + '> ' + esc(tt(f[2])) + '</label>' + hp + '</div>'; }
    return '<div class="form-group"><label for="' + id + '">' + esc(tt(f[2])) + '</label><input type="' + (f[1] === 'number' ? 'number" min="0' : (f[1] === 'email' ? 'email' : 'text')) + '" class="form-control" style="max-width:420px" id="' + id + '" value="' + esc(v) + '"' + d + ' autocomplete="off">' + hp + '</div>';
  }
  function val(f, pre) { var $e = $('#' + pre + f[0]); return f[1] === 'bool' ? ($e.is(':checked') ? 'yes' : 'no') : $.trim($e.val()); }
  function keysHtml() {
    var s = S.secrets || {};
    return '<p>' + (s.s3_key_set ? L('KEY_SET', {h: s.access_key_hint || ''}) : esc(tt('KEY_NOTSET'))) + '<br>' + esc(tt(s.password_set ? 'PW_SET' : 'PW_NOTSET')) + '</p>' +
      '<button type="button" class="btn btn-default btn-xs" id="st-changekeys">' + esc(tt('BTN_CHANGEKEYS')) + '</button>' +
      '<div id="st-keyform" style="display:none" class="cv-mt"><div class="form-group"><label for="st-ak">' + esc(tt('F_ACCESSKEY')) + '</label><input type="password" id="st-ak" class="form-control" style="max-width:420px" autocomplete="new-password"></div>' +
      '<div class="form-group"><label for="st-sk">' + esc(tt('F_SECRETKEY')) + '</label><input type="password" id="st-sk" class="form-control" style="max-width:420px" autocomplete="new-password"><p class="help-block">' + esc(tt('H_KEYS')) + '</p></div>' +
      '<button type="button" class="btn btn-warning btn-xs" id="st-savekeys">' + esc(tt('BTN_SAVEKEYS')) + '</button></div>';
  }
  function loadSettings() {
    $.when(api('config'), api('secrets'), api('schedule')).then(function (cfg, sec, sch) {
      S.cfg = cfg; S.secrets = sec; S.sched = sch; S.orig = {};
      var h = '<form id="st-form" onsubmit="return false">';
      GROUPS.forEach(function (g) {
        h += '<div class="panel panel-default"><div class="panel-heading">' + esc(tt(g[0] === 'KEYS' ? 'G_KEYS' : g[0])) + '</div><div class="panel-body">';
        if (g[0] === 'KEYS') { h += '<div id="st-keys">' + keysHtml() + '</div>'; }
        else { g[1].forEach(function (f) { S.orig[f[0]] = f[1] === 'bool' ? (cfg[f[0]] === 'yes' ? 'yes' : 'no') : (cfg[f[0]] == null ? '' : String(cfg[f[0]])); h += field(f, S.orig[f[0]], 'st-'); }); }
        h += '</div></div>';
      });
      h += '<div class="panel panel-default"><div class="panel-heading">' + esc(tt('G_SCHEDULE')) + '</div><div class="panel-body"><p>' + esc(tt('SCHED_NOTE')) + '</p>' +
        ((sch.lines || []).length ? '<pre>' + esc(sch.lines.join('\n')) + '</pre>' : '<p>' + esc(tt('SCHED_NONE')) + '</p>') + '</div></div>' +
        '<button type="button" class="btn btn-primary" id="st-save">' + esc(tt('BTN_SAVE')) + '</button> <button type="button" class="btn btn-default" id="st-test">' + esc(tt('BTN_TEST')) + '</button><div id="st-test-out" class="cv-mt" aria-live="polite"></div></form>';
      $('#cv-settings-body').html(h);
    }, function (e) { $('#cv-settings-body').html(alertBox('danger', e)); });
  }
  $('#cv-settings')
    .on('click', '#st-changekeys', function () { $('#st-keyform').show(); $('#st-ak').focus(); })
    .on('click', '#st-savekeys', function () {
      var b = $(this).prop('disabled', true);
      api('keys_save', {access_key: $('#st-ak').val(), secret_key: $('#st-sk').val()}, true).then(function (s) {
        $('#st-ak,#st-sk').val(''); S.secrets = s; $('#st-keys').html(keysHtml()); notify(tt('BTN_SAVEKEYS'), tt('KEYS_SAVED'), false);
      }, function (e) { b.prop('disabled', false); notify(tt('E_TITLE'), e, true); });
    })
    .on('click', '#st-save', function () {
      var c = {}, n = 0;
      GROUPS.forEach(function (g) { (g[1] || []).forEach(function (f) { var v = val(f, 'st-'); if (v !== S.orig[f[0]]) { c[f[0]] = v; n++; } }); });
      if (!n) { notify(tt('BTN_SAVE'), tt('NOCHANGES'), false); return; }
      api('config_set', {c: c}, true).then(function () { $.extend(S.orig, c); notify(tt('BTN_SAVE'), tt('SAVED'), false); }, function (e) { notify(tt('E_TITLE'), e, true); });
    })
    .on('click', '#st-test', function () { testStorage($(this), $('#st-test-out')); });
  function testStorage(btn, out) {
    btn.prop('disabled', true); out.html('<span class="cv-spin" aria-hidden="true"></span> ' + esc(tt('RS_WORKING')));
    var d = $.Deferred(); // resolves true/false; explicit for the same jQuery reason as api()
    api('test_storage', {}, true).done(function (r) {
      btn.prop('disabled', false);
      out.html(r.ok ? '<div class="alert alert-success" role="status">✔ ' + L('TEST_OK', {w: r.write_ms, r: r.read_ms, d: r.delete_ms}) + '</div>' : alertBox('danger', '✖ ' + tt('TEST_FAIL') + ' ' + (r.error || '')));
      d.resolve(!!r.ok);
    }).fail(function (e) { btn.prop('disabled', false); out.html(alertBox('danger', e)); d.resolve(false); });
    return d.promise();
  }

  // ---------- First-run wizard ----------
  function wizardHtml() {
    var steps = ['W_S1', 'W_S2', 'W_S3', 'W_S4', 'W_S5'], h = '<div class="panel panel-primary"><div class="panel-heading">' + esc(tt('W_TITLE')) + '</div><div class="panel-body"><p>' + esc(tt('W_INTRO')) + '</p><ol class="breadcrumb">';
    steps.forEach(function (k, i) { h += '<li' + (i + 1 === W.step ? ' class="active"' : '') + '>' + (i + 1 === W.step ? '<strong>' + esc(tt(k)) + '</strong>' : (i + 1 < W.step ? '✔ ' : '') + esc(tt(k))) + '</li>'; });
    h += '</ol><div id="w-body">' + (W.step ? stepHtml(W.step) : '<span class="cv-spin" aria-hidden="true"></span>') + '</div><div id="w-msg" aria-live="polite"></div></div></div>';
    return h;
  }
  function stepHtml(n) {
    var c = S.cfg || {}, g = function (k) { return c[k] == null ? '' : c[k]; };
    if (n === 1) { return GROUPS[0][1].slice(0, 3).map(function (f) { return field(f, g(f[0]), 'w-'); }).join('') + '<button type="button" class="btn btn-primary" data-w="s1">' + esc(tt('W_SAVE')) + '</button>'; }
    if (n === 2) {
      return '<div class="form-group"><label for="w-ak">' + esc(tt('F_ACCESSKEY')) + '</label><input type="password" id="w-ak" class="form-control" style="max-width:420px" autocomplete="new-password"></div>' +
        '<div class="form-group"><label for="w-sk">' + esc(tt('F_SECRETKEY')) + '</label><input type="password" id="w-sk" class="form-control" style="max-width:420px" autocomplete="new-password"><p class="help-block">' + esc(tt('H_KEYS')) + '</p></div>' +
        '<button type="button" class="btn btn-primary" data-w="s2">' + esc(tt('W_SAVE')) + '</button>';
    }
    if (n === 3) { return '<button type="button" class="btn btn-primary" data-w="s3">' + esc(tt('BTN_TEST')) + '</button><div id="w-test" class="cv-mt"></div>'; }
    if (n === 4) {
      return W.pw ? '<div class="alert alert-danger" role="alert"><strong>' + esc(tt('W_WARN')) + '</strong></div><pre class="cv-pw">' + esc(W.pw) + '</pre>' +
        '<div class="checkbox"><label><input type="checkbox" id="w-ack"> ' + esc(tt('W_ACK')) + '</label></div><button type="button" class="btn btn-warning" id="w-setpw" data-w="s4b" disabled>' + esc(tt('W_SETPW')) + '</button>'
        : '<p>' + esc(tt('W_PWINFO')) + '</p><button type="button" class="btn btn-primary" data-w="s4a">' + esc(tt('W_GEN')) + '</button>';
    }
    return '<p>' + esc(tt('W_INITINFO')) + '</p><button type="button" class="btn btn-primary" data-w="s5">' + esc(tt('W_INIT')) + '</button>';
  }
  function wizardGo(n) { W.step = n; $('#w-body').html(stepHtml(n)); $('#w-msg').empty(); $('#cv-dash-body .breadcrumb').replaceWith($(wizardHtml()).find('.breadcrumb')); }
  function wizardBind() {
    if (!W.step) {
      $.when(api('config'), api('secrets')).then(function (c, s) {
        S.cfg = c; S.secrets = s;
        wizardGo(!(c.S3_ENDPOINT && c.S3_BUCKET) ? 1 : (!s.s3_key_set ? 2 : (!s.password_set ? 3 : 5)));
      }, function (e) { $('#w-msg').html(alertBox('danger', e)); });
    }
  }
  $('#cv-dash').on('change', '#w-ack', function () { $('#w-setpw').prop('disabled', !this.checked); })
    .on('click', '[data-w]', function () {
      var b = $(this), k = b.data('w'), err = function (e) { b.prop('disabled', false); $('#w-msg').html(alertBox('danger', e)); };
      b.prop('disabled', true);
      if (k === 's1') {
        var c = {}; GROUPS[0][1].slice(0, 3).forEach(function (f) { c[f[0]] = val(f, 'w-'); });
        api('config_set', {c: c}, true).then(function () { S.cfg = $.extend(S.cfg || {}, c); wizardGo(2); }, err);
      } else if (k === 's2') {
        api('keys_save', {access_key: $('#w-ak').val(), secret_key: $('#w-sk').val()}, true).then(function (s) { S.secrets = s; wizardGo(3); }, err);
      } else if (k === 's3') {
        testStorage(b, $('#w-test')).then(function (ok) { if (ok) { b.prop('disabled', false); $('#w-test').append('<button type="button" class="btn btn-primary cv-mt" data-w="s3n">' + esc(tt('W_NEXT')) + '</button>'); } });
      } else if (k === 's3n') { wizardGo(S.secrets && S.secrets.password_set ? 5 : 4); }
      else if (k === 's4a') { api('wizard_gen', {}, true).then(function (r) { W.pw = r.password; wizardGo(4); }, err); }
      else if (k === 's4b') { api('wizard_commit', {ack: $('#w-ack').is(':checked') ? '1' : '0'}, true).then(function () { W.pw = null; (S.secrets || {}).password_set = true; wizardGo(5); }, err); }
      else if (k === 's5') { api('init', {}, true).then(function () { W.step = 0; notify(tt('W_TITLE'), tt('W_DONE'), false); loadDash(); }, err); }
    });

  // ---------- Logs ----------
  var logLines = [];
  function renderLog() {
    var f = $.trim($('#lg-filter').val()).toLowerCase(), out = logLines.filter(function (l) { return !f || l.toLowerCase().indexOf(f) > -1; });
    var el = $('#lg-out'), bottom = el[0].scrollHeight - el.scrollTop() - el.innerHeight() < 40;
    el.text(out.length ? out.join('\n') : tt('LG_EMPTY')); if (bottom) { el.scrollTop(el[0].scrollHeight); }
  }
  function loadLogs() { return api('log', {n: 200}).then(function (l) { logLines = l; renderLog(); }, function (e) { $('#lg-out').text(e); }); }
  $('#lg-filter').on('input', renderLog); $('#lg-reload').on('click', loadLogs);
  function logTick() { clearTimeout(S.logTimer); if ($('#cv-logs').hasClass('active') && $('#lg-auto').is(':checked')) { loadLogs().always(function () { S.logTimer = setTimeout(logTick, 5000); }); } }
  $('#lg-auto').on('change', logTick);

  // CWP's theme does not always fire Bootstrap's shown.bs.tab, so react to the click as well (once per click).
  var lastTab = {t: '', at: 0};
  function onTab(t) {
    if (lastTab.t === t && Date.now() - lastTab.at < 500) { return; }
    lastTab = {t: t, at: Date.now()};
    if (t === '#cv-settings') { loadSettings(); } else if (t === '#cv-logs') { loadLogs().always(logTick); } else { clearTimeout(S.logTimer); }
  }
  $('#cwp-vault a[data-toggle="tab"]')
    .on('shown.bs.tab', function (e) { onTab($(e.target).attr('href')); })
    .on('click', function () { var t = $(this).attr('href'); setTimeout(function () { onTab(t); }, 50); });
  loadDash();
})(jQuery);
</script>
</div>
