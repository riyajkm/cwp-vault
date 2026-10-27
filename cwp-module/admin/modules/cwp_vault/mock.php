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
            return ['job' => $a[2], 'state' => 'done', 'ok' => true, 'account' => 'demo', 'what' => 'files', 'target' => '/var/lib/cwp-vault/restore/demo',
                'files' => 1284, 'bytes' => 734003200, 'duration_s' => 38, 'error' => '', 'percent' => 100, 'in_place' => in_array('--in-place', $a, true), 'safety_snapshots' => ['deadbeef']];
        case 'restore':
            if (in_array('--detach', $a, true)) { return ['job' => gmdate('Ymd\THis\Z', $now) . "-$acct"]; }
            return ['ok' => true, 'job' => gmdate('YmdHis', $now) . '-' . $acct,
                'target' => '/var/lib/cwp-vault/restore/' . gmdate('YmdHis', $now) . "-$acct",
                'files' => 1284, 'bytes' => 734003200, 'duration_s' => 38, 'error' => null];
        case 'version':
            return ['version' => '0.2.0'];
        default: // init, backup, prune, check, unlock
            return ['ok' => true];
    }
}
