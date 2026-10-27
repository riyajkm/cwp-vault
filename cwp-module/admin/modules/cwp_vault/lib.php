<?php
// CWP Vault - shared glue: engine runner, validation, CSRF, AJAX handlers.
// Included by modules/cwp_vault.php and addons/ajax/ajax_cwp_vault.php.
// Loaded only by CWP: the page loader sets $include_path, the AJAX loader (loader_ajax.php) sets $ajax_file.
// Both run after CWP's own admin login check; we still require a logged-in admin session.
if (!isset($include_path) && !isset($ajax_file)) { echo "invalid access"; exit(); }
if (empty($_SESSION['logged']) || empty($_SESSION['token'])) { http_response_code(403); echo "admin login required"; exit(); }
if (defined('CWP_VAULT_LIB')) { return; }
define('CWP_VAULT_LIB', 1);
const VAULT_PENDING_PW = '/usr/local/cwp-vault/var/wizard.pending';

const VAULT_BIN = '/usr/local/bin/vault';
const VAULT_CRON = '/etc/cron.d/cwp-vault';
const VAULT_RE_ACCOUNT = '/^[a-z][a-z0-9_]{0,31}$/';
const VAULT_RE_SNAPSHOT = '/^[a-f0-9]{8,64}$/';
const VAULT_RE_DBANY = '/^[a-z][a-z0-9_]{0,31}_[A-Za-z0-9_]{1,56}$/';

// CWP manages its own session; never start or write one here.

// Generated restic password waiting for "I saved it": set with a value, read without. 0600 root, 15 min.
function vault_pending_pw(?string $set = null)
{
    if ($set !== null) {
        $old = umask(077);
        $ok = @file_put_contents(VAULT_PENDING_PW, $set, LOCK_EX) !== false;
        umask($old);
        return $ok;
    }
    if (!is_file(VAULT_PENDING_PW) || time() - (int)@filemtime(VAULT_PENDING_PW) > 900) { @unlink(VAULT_PENDING_PW); return ''; }
    return (string)@file_get_contents(VAULT_PENDING_PW);
}

// ---------- strings ----------
function vault_lang(): array
{
    static $t = null;
    if ($t === null) {
        $t = @parse_ini_file(__DIR__ . '/../language/en/cwp_vault.ini') ?: [];
    }
    return $t;
}
function h($s): string { return htmlspecialchars((string)$s, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8'); }
function vault_json($v): string { return json_encode($v, JSON_HEX_TAG | JSON_HEX_AMP | JSON_HEX_APOS | JSON_HEX_QUOT | JSON_INVALID_UTF8_SUBSTITUTE); }

// ---------- CSRF ----------
function vault_csrf(): string
{
    // Derived from CWP's per-login session token, so it is stable for the login without writing to the session.
    return hash_hmac('sha256', 'cwp_vault_csrf', (string)$_SESSION['token']);
}
function vault_csrf_ok(): bool
{
    $got = $_POST['csrf'] ?? ($_SERVER['HTTP_X_CSRF_TOKEN'] ?? '');
    return is_string($got) && $got !== '' && hash_equals(vault_csrf(), $got);
}

// ---------- validation ----------
function vault_ok_path($p): bool
{
    return is_string($p) && $p !== '' && $p[0] === '/' && strlen($p) <= 4096
        && !preg_match('/[\x00-\x1f]/', $p) && !preg_match('#(^|/)\.\.(/|$)#', $p);
}
function vault_ok_url($v): bool { return $v === '' || (bool)preg_match('#^https://[^\s\'"`$\\\\]{1,1000}$#', $v); }

// key => validator(value): bool.  The only keys the module may write.
function vault_config_rules(): array
{
    $yn = function ($v) { return $v === 'yes' || $v === 'no'; };
    $int = function ($min, $max) { return function ($v) use ($min, $max) { return ctype_digit($v) && (int)$v >= $min && (int)$v <= $max; }; };
    return [
        'S3_ENDPOINT' => function ($v) { return (bool)preg_match('#^https?://[A-Za-z0-9.:-]{1,253}$#', $v); },
        'S3_BUCKET' => function ($v) { return (bool)preg_match('/^[A-Za-z0-9._-]{1,255}$/', $v); },
        'S3_PREFIX' => function ($v) { return (bool)preg_match('#^[A-Za-z0-9._/-]{0,200}$#', $v) && strpos($v, '..') === false; },
        'ALLOW_INSECURE' => $yn, 'BACKUP_MAIL' => $yn, 'BACKUP_DATABASES' => $yn, 'BACKUP_SERVER' => $yn,
        'KEEP_DAILY' => $int(0, 3650), 'KEEP_WEEKLY' => $int(0, 520), 'KEEP_MONTHLY' => $int(0, 240),
        'S3_CONNECTIONS' => $int(1, 64), 'LIMIT_UPLOAD_KIB' => $int(0, 100000000),
        'ALERT_EMAIL' => function ($v) { return $v === '' || (strlen($v) <= 254 && filter_var($v, FILTER_VALIDATE_EMAIL) && !preg_match('/[\s,;<>]/', $v)); },
        'ALERT_WEBHOOK' => 'vault_ok_url', 'HEARTBEAT_URL' => 'vault_ok_url',
        'IMMUTABLE' => $yn, 'LOCK_DAYS' => $int(1, 3650),
        'LOCK_MODE' => function ($v) { return $v === 'COMPLIANCE' || $v === 'GOVERNANCE'; },
    ];
}

// Returns null when $args are allowed, else an error string.
function vault_check_args(array $args): ?string
{
    $flagsAllowed = [
        'status' => ['--json'], 'version' => [], 'test-storage' => ['--json'], 'init' => ['--json'],
        'snapshots' => ['--account', '--json'],
        'ls' => ['--account', '--snapshot', '--path', '--json'],
        'log' => ['--tail', '--json'],
        'backup' => ['--account', '--all', '--dry-run', '--quiet'],
        'prune' => ['--account', '--all', '--quiet'], 'check' => ['--account', '--all', '--quiet'],
        'unlock' => ['--account', '--all'],
        'restore' => ['--account', '--snapshot', '--what', '--path', '--db', '--target', '--target-db', '--dry-run', '--json', '--quiet'],
    ];
    $bool = ['--json', '--all', '--dry-run', '--quiet'];
    $verb = $args[0] ?? '';
    foreach ($args as $a) { if (!is_string($a) || strpos($a, "\0") !== false) { return 'bad argument'; } }

    if ($verb === 'config') {
        $sub = $args[1] ?? '';
        if ($sub === 'get') { return $args === ['config', 'get', '--json'] ? null : 'bad config get'; }
        if ($sub !== 'set' || count($args) < 3) { return 'bad config verb'; }
        $rules = vault_config_rules();
        foreach (array_slice($args, 2) as $kv) {
            $p = explode('=', $kv, 2);
            if (count($p) !== 2 || !isset($rules[$p[0]])) { return 'config key not allowed'; }
            if (strlen($p[1]) > 1024 || preg_match('/[\r\n\0`]|\$\(/', $p[1]) || !call_user_func($rules[$p[0]], $p[1])) { return 'invalid value for ' . $p[0]; }
        }
        return null;
    }
    if ($verb === 'secrets') {
        return ($args === ['secrets', 'set'] || $args === ['secrets', 'status', '--json']) ? null : 'bad secrets verb';
    }
    if (!isset($flagsAllowed[$verb])) { return 'verb not allowed'; }

    $seen = [];
    $n = count($args);
    for ($i = 1; $i < $n; $i++) {
        $f = $args[$i];
        if (!in_array($f, $flagsAllowed[$verb], true)) { return 'flag not allowed: ' . $verb; }
        if (in_array($f, $bool, true)) { $seen[$f][] = true; continue; }
        if (++$i >= $n) { return 'missing value'; }
        $v = $args[$i];
        $ok = false;
        switch ($f) {
            case '--account': $ok = (bool)preg_match(VAULT_RE_ACCOUNT, $v); break;
            case '--snapshot': $ok = $v === 'latest' || preg_match(VAULT_RE_SNAPSHOT, $v); break;
            case '--path': case '--target': $ok = vault_ok_path($v); break;
            case '--what': $ok = in_array($v, ['files', 'db', 'mail', 'meta'], true); break;
            case '--db': case '--target-db': $ok = (bool)preg_match(VAULT_RE_DBANY, $v); break;
            case '--tail': $ok = ctype_digit($v) && (int)$v >= 1 && (int)$v <= 2000; break;
        }
        if (!$ok) { return 'invalid ' . $f; }
        $seen[$f][] = $v;
    }
    $acct = $seen['--account'][0] ?? null;
    if (in_array($verb, ['snapshots', 'ls', 'restore'], true) && $acct === null) { return 'account required'; }
    foreach (['--db', '--target-db'] as $f) {
        foreach ($seen[$f] ?? [] as $db) { if (strpos($db, $acct . '_') !== 0) { return 'database does not belong to account'; } }
    }
    return null;
}

// ---------- engine runner ----------
function vault_mock(): bool
{
    // Demo data only when explicitly asked for: a missing engine must show an error, never fake backups.
    return (defined('CWP_VAULT_MOCK') && CWP_VAULT_MOCK) || getenv('CWP_VAULT_MOCK') === '1';
}

// Returns ['ok'=>bool,'code'=>int,'data'=>mixed,'error'=>?string]. data is decoded JSON, or raw stdout when not JSON.
function vault_run(array $args, ?string $stdin = null, bool $detached = false): array
{
    $args = array_values($args);
    if (($err = vault_check_args($args)) !== null) { return ['ok' => false, 'code' => 2, 'data' => null, 'error' => $err]; }

    if (vault_mock()) {
        require_once __DIR__ . '/mock.php';
        $d = vault_mock_data($args);
        $bad = is_array($d) && isset($d['error']);
        return ['ok' => !$bad, 'code' => $bad ? 2 : 0, 'data' => $d, 'error' => $bad ? (string)$d['error'] : null];
    }

    if (!is_file(VAULT_BIN) || !is_executable(VAULT_BIN)) {
        return ['ok' => false, 'code' => 127, 'data' => null, 'error' => 'CWP Vault engine is not installed (' . VAULT_BIN . ' missing). Run install.sh.'];
    }
    $verb = $args[0];
    $timeout = in_array($verb, ['restore'], true) ? 7200 : (in_array($verb, ['init', 'test-storage', 'unlock'], true) ? 300 : 60);
    $env = ['PATH' => '/usr/local/bin:/usr/bin:/bin', 'HOME' => '/root', 'LANG' => 'C'];

    if ($detached) {
        $spec = [0 => ['file', '/dev/null', 'r'], 1 => ['file', '/dev/null', 'w'], 2 => ['file', '/dev/null', 'w']];
        $p = @proc_open(array_merge(['setsid', '-f', VAULT_BIN], $args), $spec, $pipes, '/', $env);
        if (!is_resource($p)) { return ['ok' => false, 'code' => -1, 'data' => null, 'error' => 'cannot start engine']; }
        $code = proc_close($p);
        return ['ok' => $code === 0, 'code' => $code, 'data' => null, 'error' => $code === 0 ? null : 'cannot start engine'];
    }

    $spec = [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']];
    $p = @proc_open(array_merge([VAULT_BIN], $args), $spec, $pipes, '/', $env);
    if (!is_resource($p)) { return ['ok' => false, 'code' => -1, 'data' => null, 'error' => 'cannot start engine']; }
    if ($stdin !== null) { fwrite($pipes[0], $stdin); }
    fclose($pipes[0]);
    stream_set_blocking($pipes[1], false);
    stream_set_blocking($pipes[2], false);
    $out = $errOut = '';
    $deadline = time() + $timeout;
    $timedOut = false;
    while (true) {
        $r = [$pipes[1], $pipes[2]]; $w = null; $e = null;
        if (@stream_select($r, $w, $e, 1) > 0) {
            foreach ($r as $s) {
                $chunk = fread($s, 65536);
                if ($chunk === false || $chunk === '') { continue; }
                if ($s === $pipes[1]) { if (strlen($out) < 4000000) { $out .= $chunk; } }
                elseif (strlen($errOut) < 65536) { $errOut .= $chunk; }
            }
        }
        $st = proc_get_status($p);
        if (!$st['running']) { break; }
        if (time() > $deadline) { $timedOut = true; proc_terminate($p, 15); break; }
    }
    $out .= (string)stream_get_contents($pipes[1]);
    fclose($pipes[1]); fclose($pipes[2]);
    $code = proc_close($p);
    if (isset($st['exitcode']) && $st['exitcode'] >= 0 && !$st['running']) { $code = $st['exitcode']; }
    if ($timedOut) { return ['ok' => false, 'code' => -2, 'data' => null, 'error' => 'engine timed out']; }

    $data = json_decode($out, true);
    if ($data === null && trim($out) !== '' && json_last_error() !== JSON_ERROR_NONE) { $data = trim($out); }
    $err = null;
    if (is_array($data) && isset($data['error']) && $data['error']) { $err = (string)$data['error']; }
    elseif ($code !== 0) { $err = substr(trim($errOut) !== '' ? trim($errOut) : 'engine failed (exit ' . $code . ')', 0, 300); }
    return ['ok' => $code === 0 && $err === null, 'code' => $code, 'data' => $data, 'error' => $err];
}

// ---------- AJAX ----------
function vault_out(bool $ok, $data = null, ?string $err = null, int $http = 200): void
{
    while (ob_get_level() > 0) { ob_end_clean(); }
    http_response_code($http);
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store');
    echo vault_json($ok ? ['ok' => true, 'data' => $data] : ['ok' => false, 'error' => $err ?? 'error']);
    exit();
}
function vault_fail(array $r): void { vault_out(false, null, $r['error'] ?? 'engine error'); }
function vault_str(string $k, string $src = 'P'): string
{
    $v = $src === 'P' ? ($_POST[$k] ?? '') : ($_GET[$k] ?? '');
    return is_string($v) ? $v : '';
}

function vault_schedule(): array
{
    $raw = vault_mock() ? "30 1 * * *  root /usr/local/bin/vault backup --all\n0  4 * * 0  root /usr/local/bin/vault prune --all\n0  4 * * 3  root /usr/local/bin/vault check --all\n"
        : (string)@file_get_contents(VAULT_CRON);
    $lines = []; $next = null;
    foreach (preg_split('/\R/', $raw) as $l) {
        $l = trim($l);
        if ($l === '' || $l[0] === '#' || strlen($l) > 300) { continue; }
        $lines[] = $l;
        // shortcut: only "M H * * *" daily lines are turned into a next-run time; others show as text.
        if ($next === null && preg_match('~^(\d{1,2})\s+(\d{1,2})\s+\*\s+\*\s+\*\s+root\s+/usr/local/bin/vault\s+backup\b~', $l, $m) && $m[1] < 60 && $m[2] < 24) {
            $t = mktime((int)$m[2], (int)$m[1], 0);
            if ($t <= time()) { $t += 86400; }
            $next = date('c', $t);
        }
    }
    return ['lines' => $lines, 'next' => $next];
}

function vault_log_lines($d): array
{
    if (is_array($d) && isset($d['lines'])) { $d = $d['lines']; }
    if (is_string($d)) { $d = preg_split('/\R/', rtrim($d)); }
    return is_array($d) ? array_map('strval', array_slice(array_values($d), -2000)) : [];
}

function vault_dispatch(string $acc): void
{
    $writes = ['backup', 'restore', 'config_set', 'keys_save', 'test_storage', 'wizard_gen', 'wizard_commit', 'init'];
    if (in_array($acc, $writes, true)) {
        if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') { vault_out(false, null, 'POST required', 405); }
        if (!vault_csrf_ok()) { vault_out(false, null, 'Invalid or missing security token. Reload the page.', 403); }
    }
    $account = vault_str('account', ($_SERVER['REQUEST_METHOD'] ?? '') === 'POST' ? 'P' : 'G');
    $acctOk = (bool)preg_match(VAULT_RE_ACCOUNT, $account);

    switch ($acc) {
        case 'status':
            $r = vault_run(['status', '--json']); if (!$r['ok'] && !is_array($r['data'])) { vault_fail($r); }
            vault_out(true, $r['data']);
        case 'snapshots':
            if (!$acctOk) { vault_out(false, null, 'Invalid account'); }
            $r = vault_run(['snapshots', '--account', $account, '--json']); if (!$r['ok']) { vault_fail($r); }
            vault_out(true, $r['data']);
        case 'ls':
            if (!$acctOk) { vault_out(false, null, 'Invalid account'); }
            $a = ['ls', '--account', $account, '--snapshot', vault_str('snapshot', 'G')];
            if (vault_str('path', 'G') !== '') { array_push($a, '--path', vault_str('path', 'G')); }
            $r = vault_run(array_merge($a, ['--json'])); if (!$r['ok']) { vault_fail($r); }
            vault_out(true, $r['data']);
        case 'config':
            $r = vault_run(['config', 'get', '--json']); if (!$r['ok']) { vault_fail($r); }
            vault_out(true, $r['data']);
        case 'secrets':
            $r = vault_run(['secrets', 'status', '--json']); if (!$r['ok']) { vault_fail($r); }
            vault_out(true, $r['data']);
        case 'log':
            $n = max(1, min(2000, (int)vault_str('n', 'G') ?: 200));
            $r = vault_run(['log', '--tail', (string)$n]); if (!$r['ok']) { vault_fail($r); }
            vault_out(true, vault_log_lines($r['data']));
        case 'schedule':
            vault_out(true, vault_schedule());

        case 'backup':
            $a = ['backup'];
            if ($account !== '') { if (!$acctOk) { vault_out(false, null, 'Invalid account'); } array_push($a, '--account', $account); }
            else { $a[] = '--all'; }
            $a[] = '--quiet';
            $r = vault_run($a, null, !vault_mock()); if (!$r['ok']) { vault_fail($r); }
            vault_out(true, ['started' => true]);

        case 'restore':
            if (!$acctOk) { vault_out(false, null, 'Invalid account'); }
            $what = vault_str('what');
            $a = ['restore', '--account', $account, '--snapshot', vault_str('snapshot') ?: 'latest', '--what', $what];
            $paths = $_POST['paths'] ?? [];
            if ($what === 'files' && is_array($paths)) {
                foreach (array_slice($paths, 0, 200) as $p) { if (is_string($p)) { array_push($a, '--path', $p); } }
            }
            if ($what === 'db') { array_push($a, '--db', vault_str('db'), '--target-db', vault_str('target_db')); }
            elseif (vault_str('target') !== '') { array_push($a, '--target', vault_str('target')); }
            if (vault_str('dry_run') === '1') { $a[] = '--dry-run'; }
            $a[] = '--json';
            @set_time_limit(0); ignore_user_abort(true);
            session_write_close(); // do not block other admin requests during a long restore
            $r = vault_run($a);
            if (!is_array($r['data'])) { vault_fail($r); }
            vault_out(true, $r['data']);

        case 'config_set':
            $c = $_POST['c'] ?? [];
            if (!is_array($c) || !$c) { vault_out(false, null, 'Nothing to save'); }
            $a = ['config', 'set'];
            foreach ($c as $k => $v) { if (is_string($k) && is_string($v)) { $a[] = $k . '=' . $v; } }
            $r = vault_run($a); if (!$r['ok']) { vault_fail($r); }
            vault_out(true, $r['data']);

        case 'keys_save':
            $ak = vault_str('access_key'); $sk = vault_str('secret_key');
            if (!preg_match('/^[A-Za-z0-9+\/=_.-]{8,128}$/', $ak) || !preg_match('/^[A-Za-z0-9+\/=_.-]{8,256}$/', $sk)) { vault_out(false, null, 'Keys have an invalid format'); }
            $r = vault_run(['secrets', 'set'], "AWS_ACCESS_KEY_ID=$ak\nAWS_SECRET_ACCESS_KEY=$sk\n");
            if (!$r['ok']) { vault_out(false, null, 'Could not store the keys'); } // engine text could echo input; keep it generic
            $s = vault_run(['secrets', 'status', '--json']);
            vault_out(true, $s['data']);

        case 'test_storage':
            session_write_close();
            $r = vault_run(['test-storage', '--json']);
            if (!is_array($r['data'])) { vault_fail($r); }
            vault_out(true, $r['data']);

        case 'wizard_gen':
            $s = vault_run(['secrets', 'status', '--json']);
            if (is_array($s['data']) && !empty($s['data']['password_set'])) { vault_out(false, null, 'A backup password is already set.'); }
            $pw = rtrim(strtr(base64_encode(random_bytes(24)), '+/', '-_'), '=');
            // Shown once; kept root-only on disk (CWP's AJAX loader has no writable PHP session) so the
            // browser never posts it back. Expires after 15 minutes.
            if (!vault_pending_pw($pw)) { vault_out(false, null, 'Could not prepare the password'); }
            vault_out(true, ['password' => $pw]);

        case 'wizard_commit':
            $pw = vault_pending_pw();
            if (vault_str('ack') !== '1') { vault_out(false, null, 'Confirm that you saved the password.'); }
            if (!is_string($pw) || !preg_match('/^[A-Za-z0-9_-]{32}$/', $pw)) { vault_out(false, null, 'No generated password. Generate one first.'); }
            $r = vault_run(['secrets', 'set'], "RESTIC_PASSWORD=$pw\n");
            if (!$r['ok']) { vault_out(false, null, 'Could not store the password'); }
            @unlink(VAULT_PENDING_PW);
            vault_out(true, ['ok' => true]);

        case 'init':
            session_write_close();
            $r = vault_run(['init', '--json']); if (!$r['ok']) { vault_fail($r); }
            vault_out(true, $r['data']);
    }
    vault_out(false, null, 'Unknown action', 404);
}
