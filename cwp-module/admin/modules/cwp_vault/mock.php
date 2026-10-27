<?php
// Fixture data so the page renders without the engine (development and screenshots only).
if (!defined('CWP_VAULT_LIB')) { echo "invalid access"; exit(); }

function vault_mock_data(array $a)
{
    $now = time();
    $iso = function ($ago) use ($now) { return gmdate('Y-m-d\TH:i:s\Z', $now - $ago); };
    $verb = $a[0];
    $acct = '';
    foreach ($a as $i => $v) { if ($v === '--account' && isset($a[$i + 1])) { $acct = $a[$i + 1]; } }

    switch ($verb) {
        case 'status':
            $mk = function ($n, $res, $ago, $dur, $bytes, $snaps, $err = null) use ($iso) {
                return ['account' => $n, 'result' => $res, 'started' => $iso($ago + $dur), 'finished' => $iso($ago),
                    'duration_s' => $dur, 'bytes_added' => $bytes, 'snapshots' => $snaps, 'error' => $err];
            };
            return ['version' => '0.2.0', 'configured' => true,
                'accounts' => [
                    $mk('alice', 'ok', 5 * 3600, 312, 148234567, 21),
                    $mk('bob', 'failed', 5 * 3600, 41, 0, 14, 'mysqldump failed for bob_shop'),
                    $mk('carol', 'ok', 5 * 3600, 95, 20481234, 9),
                ],
                'server' => $mk('_server', 'ok', 5 * 3600 + 500, 33, 3123456, 7),
                'schedule' => vault_mock_schedule($now), 'now_epoch' => $now,
                'running' => [], 'immutable' => ['enabled' => true, 'mode' => 'COMPLIANCE', 'days' => 14]];
        case 'snapshots':
            if (!$acct) { return ['error' => 'account required', 'code' => 2]; }
            $out = [];
            for ($d = 0; $d < 4; $d++) {
                $t = $iso($d * 86400 + 5 * 3600);
                $h = function ($k) use ($acct, $d) { return md5($acct . $k . $d) . md5($k . $d); };
                $out[] = ['id' => $h('f'), 'short_id' => substr($h('f'), 0, 8), 'time' => $t, 'tags' => ['files', $acct],
                    'paths' => ["/home/$acct", '/var/vmail/example.com'], 'kind' => 'files', 'db' => null, 'size' => 900000000 + $d * 1000000];
                $out[] = ['id' => $h('d'), 'short_id' => substr($h('d'), 0, 8), 'time' => $t, 'tags' => ['db', $acct],
                    'paths' => ["db/{$acct}_wp.sql"], 'kind' => 'db', 'db' => "{$acct}_wp", 'size' => 12345678];
                $out[] = ['id' => $h('m'), 'short_id' => substr($h('m'), 0, 8), 'time' => $t, 'tags' => ['meta', $acct],
                    'paths' => ['meta/account.json'], 'kind' => 'meta', 'db' => null, 'size' => 2048];
            }
            return $out;
        case 'ls':
            $p = '/';
            foreach ($a as $i => $v) { if ($v === '--path' && isset($a[$i + 1])) { $p = rtrim($a[$i + 1], '/'); } }
            if ($p === '' || $p === '/') {
                return [['name' => 'home', 'type' => 'dir', 'size' => 0, 'mtime' => $iso(9000), 'path' => '/home'],
                    ['name' => 'var', 'type' => 'dir', 'size' => 0, 'mtime' => $iso(9000), 'path' => '/var']];
            }
            if ($p === '/home') {
                return [['name' => $acct, 'type' => 'dir', 'size' => 0, 'mtime' => $iso(9000), 'path' => "/home/$acct"]];
            }
            if ($p === "/home/$acct") {
                return [['name' => 'public_html', 'type' => 'dir', 'size' => 0, 'mtime' => $iso(7200), 'path' => "/home/$acct/public_html"],
                    ['name' => 'backup.tar', 'type' => 'file', 'size' => 52428800, 'mtime' => $iso(86400), 'path' => "/home/$acct/backup.tar"],
                    ['name' => '.bashrc', 'type' => 'file', 'size' => 231, 'mtime' => $iso(864000), 'path' => "/home/$acct/.bashrc"],
                    ['name' => 'www', 'type' => 'symlink', 'size' => 0, 'mtime' => $iso(864000), 'path' => "/home/$acct/www"]];
            }
            return [['name' => 'index.php', 'type' => 'file', 'size' => 4096, 'mtime' => $iso(7200), 'path' => $p . '/index.php'],
                ['name' => 'wp-content', 'type' => 'dir', 'size' => 0, 'mtime' => $iso(7200), 'path' => $p . '/wp-content']];
        case 'config':
            if (($a[1] ?? '') === 'set') {
                return ['ok' => true, 'changed' => array_map(function ($kv) { return explode('=', $kv, 2)[0]; }, array_slice($a, 2))];
            }
            return ['S3_ENDPOINT' => 'https://s3.example.com', 'S3_BUCKET' => 'example-backups', 'S3_PREFIX' => 'server1/', 'ALLOW_INSECURE' => 'no',
                'BACKUP_MAIL' => 'yes', 'BACKUP_DATABASES' => 'yes', 'BACKUP_SERVER' => 'yes',
                'KEEP_DAILY' => '7', 'KEEP_WEEKLY' => '4', 'KEEP_MONTHLY' => '3',
                'S3_CONNECTIONS' => '4', 'LIMIT_UPLOAD_KIB' => '0',
                'ALERT_EMAIL' => 'admin@example.com', 'ALERT_WEBHOOK' => '', 'HEARTBEAT_URL' => '', 'IMMUTABLE' => 'yes', 'LOCK_MODE' => 'COMPLIANCE', 'LOCK_DAYS' => '14'];
        case 'secrets':
            if (($a[1] ?? '') === 'set') { return ['ok' => true]; }
            return ['s3_key_set' => true, 'access_key_hint' => '…ABCD', 'password_set' => true];
        case 'log':
            $names = ['backup alice: files snapshot saved', 'backup alice: db alice_wp dumped', 'backup bob: mysqldump failed for bob_shop', 'prune carol: forgot 2 snapshots'];
            $lines = [];
            for ($i = 0; $i < 40; $i++) {
                $lines[] = gmdate('Y-m-d\TH:i:s\Z', $now - (40 - $i) * 60) . ' ' . ($i % 4 === 2 ? 'WARN' : 'INFO') . ' ' . $names[$i % 4];
            }
            return $lines;
        case 'test-storage':
            return ['ok' => true, 'write_ms' => 412, 'read_ms' => 188, 'delete_ms' => 95, 'error' => null];
        case 'jobs':
            return [['job' => gmdate('Ymd\THis\Z', $now - 600) . '-demo', 'state' => 'done', 'ok' => true, 'account' => 'demo', 'what' => 'files',
                'target' => '/var/lib/cwp-vault/restore/demo', 'files' => 1284, 'bytes' => 734003200, 'duration_s' => 38, 'error' => '', 'percent' => 100]];
        case 'job':
            return ['job' => $a[2], 'kind' => 'export', 'file' => 'demo-files.tar.gz', 'encrypted' => false, 'expires' => gmdate('Y-m-d\TH:i:s\Z', $now + 86400), 'state' => 'done', 'ok' => true, 'account' => 'demo', 'what' => 'files', 'target' => '/var/lib/cwp-vault/restore/demo',
                'files' => 1284, 'bytes' => 734003200, 'duration_s' => 38, 'error' => '', 'percent' => 100, 'in_place' => in_array('--in-place', $a, true), 'safety_snapshots' => ['deadbeef']];
        case 'restore':
            if (in_array('--detach', $a, true)) { return ['job' => gmdate('Ymd\THis\Z', $now) . "-$acct"]; }
            return ['ok' => true, 'job' => gmdate('YmdHis', $now) . '-' . $acct,
                'target' => '/var/lib/cwp-vault/restore/' . gmdate('YmdHis', $now) . "-$acct",
                'files' => 1284, 'bytes' => 734003200, 'duration_s' => 38, 'error' => null];
        case 'schedule':
            $t = null; $en = 'yes';
            foreach ($a as $i => $v) { if ($v === '--time' && isset($a[$i + 1])) { $t = $a[$i + 1]; } if ($v === '--enabled' && isset($a[$i + 1])) { $en = $a[$i + 1]; } }
            return vault_mock_schedule($now, $t ?: '01:30', $en === 'yes');
        case 'export':
            return ['job' => gmdate('Ymd\THis\Z', $now) . "-$acct"];
        case 'exports':
            return [
                ['job' => gmdate('Ymd\THis\Z', $now - 3600) . '-alice', 'account' => 'alice', 'what' => 'files', 'file' => 'alice-files.tar.gz.gpg', 'bytes' => 734003200, 'encrypted' => true, 'created' => $iso(3600), 'expires' => gmdate('Y-m-d\TH:i:s\Z', $now + 23 * 3600)],
                ['job' => gmdate('Ymd\THis\Z', $now - 7200) . '-bob', 'account' => 'bob', 'what' => 'db', 'file' => 'bob-bob_shop.sql.gz', 'bytes' => 12345678, 'encrypted' => false, 'created' => $iso(7200), 'expires' => gmdate('Y-m-d\TH:i:s\Z', $now + 22 * 3600)],
            ];
        case 'export-path':
            return '/var/lib/cwp-vault/exports/mock-export.tar.gz';
        case 'audit-download':
            return ['ok' => true];
        case 'version':
            return ['version' => '0.2.0'];
        default: // init, backup, prune, check, unlock
            return ['ok' => true];
    }
}

// Server timezone fixture: Asia/Colombo (+0530). Next run is the next occurrence of $time in that zone.
function vault_mock_schedule(int $now, string $time = '01:30', bool $enabled = true): array
{
    $off = 19800;
    [$h, $m] = array_map('intval', explode(':', $time));
    $day = (int)floor(($now + $off) / 86400) * 86400;
    $next = $day + $h * 3600 + $m * 60 - $off;
    if ($next <= $now) { $next += 86400; }
    return ['backup' => ['enabled' => $enabled, 'time' => $time], 'prune' => ['day' => 'sun', 'time' => '04:00'], 'check' => ['day' => 'wed', 'time' => '04:00'],
        'timezone' => 'Asia/Colombo', 'utc_offset' => '+0530', 'now_epoch' => $now,
        'next_run' => $enabled ? gmdate('Y-m-d\TH:i:s', $next + $off) . '+0530' : null, 'next_run_epoch' => $enabled ? $next : null];
}
