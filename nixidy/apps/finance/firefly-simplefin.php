<?php
// Daily SimpleFIN -> Firefly III import, run by CronJob firefly-simplefin in the data-importer image.
//   1. Setup token (Bitwarden firefly/simplefin/token, mounted at /secrets/simplefin/token) is claimed
//      once for a long-lived access URL, kept in Secret firefly-simplefin-access next to a hash of the
//      token it came from (a new token in Bitwarden is claimed again; an access URL pasted instead of
//      a setup token is used as is). Setup tokens are single use, so never claim twice.
//   2. Lists the Bridge accounts and the Firefly asset accounts, and writes an importer config that maps
//      every Bridge account to the Firefly account of the same name, or creates it (id 0 + new_accounts).
//   3. Runs `importer:auto-import` on that config.
// Request budget (Bridge: <= 24/day per token, more can disable it): 1 + 1 (only when creating accounts)
// + 1 (importer, account list) + 1 per account (importer, transactions). Aborts above MAX_ACCOUNTS.
// Nothing here prints the access URL.

const SA = '/var/run/secrets/kubernetes.io/serviceaccount';
const MAX_ACCOUNTS = 20;
const WINDOW_DAYS = 45; // the Bridge recommends <= 45 (hard limit 90) per request

function out(string $m): void { fwrite(STDOUT, "$m\n"); }
function fail(string $m): never { fwrite(STDERR, "simplefin-import: $m\n"); exit(1); }

function http(string $method, string $url, array $headers = [], string $body = '', array $ssl = []): array
{
    $ctx = stream_context_create(['http' => [
        'method' => $method, 'header' => implode("\r\n", $headers) . "\r\n", 'content' => $body,
        'ignore_errors' => true, 'timeout' => 60,
    ], 'ssl' => $ssl]);
    $res = @file_get_contents($url, false, $ctx);
    $status = 0;
    if (isset($http_response_header[0]) && preg_match('#\s(\d{3})\s#', $http_response_header[0], $m)) {
        $status = (int) $m[1];
    }
    return [$status, false === $res ? '' : $res];
}

$ns = trim(file_get_contents(SA . '/namespace'));
$kubeBase = 'https://' . getenv('KUBERNETES_SERVICE_HOST') . ':' . getenv('KUBERNETES_SERVICE_PORT') . "/api/v1/namespaces/$ns/secrets";
function kube(string $method, string $url, ?array $body = null, string $type = 'application/json'): array
{
    // The API server's cert is signed by the cluster CA, not a public one.
    $res = http($method, $url, [
        'Authorization: Bearer ' . trim(file_get_contents(SA . '/token')),
        "Content-Type: $type", 'Accept: application/json',
    ], null === $body ? '' : json_encode($body), ['cafile' => SA . '/ca.crt']);
    if (0 === $res[0]) {
        fail("kube API $method request failed (no HTTP status)");
    }
    return $res;
}

// --- 1. access URL ---
$token = trim((string) file_get_contents('/secrets/simplefin/token'));
if ('' === $token) {
    fail('Bitwarden key firefly/simplefin/token is empty');
}
$hash = hash('sha256', $token);
$name = 'firefly-simplefin-access';
[$st, $body] = kube('GET', "$kubeBase/$name");
$have = 200 === $st ? array_map('base64_decode', json_decode($body, true)['data'] ?? []) : [];
$access = $have['access_url'] ?? '';
if ('' === $access || ($have['token_sha256'] ?? '') !== $hash) {
    if (preg_match('#^https://[^/]+:[^/]+@#', $token)) {
        $access = $token;
        out('token is an access URL, using it directly');
    } else {
        $claim = base64_decode($token, true);
        if (false === $claim || !preg_match('#^https://[^/]+/simplefin/claim/.+$#', $claim)) {
            fail('token is neither a SimpleFIN setup token nor an access URL');
        }
        [$st, $access] = http('POST', $claim, ['Content-Length: 0']);
        $access = trim($access);
        if (200 !== $st || !str_starts_with($access, 'https://')) {
            fail("claim failed with HTTP $st (403 = token unknown or already used: generate a new setup token and update firefly/simplefin/token)");
        }
        out('claimed the setup token');
    }
    $data = ['access_url' => $access, 'token_sha256' => $hash];
    if (200 === $st && [] !== $have) {
        kube('PATCH', "$kubeBase/$name", ['stringData' => $data], 'application/merge-patch+json');
    } else {
        // The claim above can't be repeated: a failed write loses the token, so check it.
        [$cst] = kube('POST', $kubeBase, ['apiVersion' => 'v1', 'kind' => 'Secret', 'metadata' => ['name' => $name], 'type' => 'Opaque', 'stringData' => $data]);
        if (409 === $cst) {
            [$cst] = kube('PATCH', "$kubeBase/$name", ['stringData' => $data], 'application/merge-patch+json');
        }
        if ($cst < 200 || $cst >= 300) {
            fail("could not store the access URL (HTTP $cst); the setup token is spent: generate a new one");
        }
    }
    out("stored access URL in secret $name");
}

$u = parse_url($access);
$bridge = $u['scheme'] . '://' . $u['host'] . (isset($u['port']) ? ':' . $u['port'] : '') . ($u['path'] ?? '');
$basic = ['Authorization: Basic ' . base64_encode(rawurldecode($u['user'] ?? '') . ':' . rawurldecode($u['pass'] ?? ''))];

function bridge(string $bridge, array $basic, string $query): array
{
    [$st, $body] = http('GET', "$bridge/accounts?$query", $basic);
    if (200 !== $st) {
        fail("SimpleFIN /accounts returned HTTP $st (402 = subscription lapsed, 403 = token revoked or disabled)");
    }
    $json = json_decode($body, true);
    foreach ($json['errors'] ?? [] as $e) {
        fwrite(STDERR, 'simplefin bridge message: ' . (is_array($e) ? ($e['code'] ?? '') . ' ' . ($e['msg'] ?? '') : $e) . "\n");
    }
    return $json['accounts'] ?? [];
}

// --- 2. config ---
$accounts = bridge($bridge, $basic, 'balances-only=1');
if ([] === $accounts) {
    fail('the Bridge returned no accounts: connect institutions in the Bridge first');
}
if (count($accounts) > MAX_ACCOUNTS) {
    fail(sprintf('%d accounts: a daily run would use more than the Bridge\'s 24 requests/day', count($accounts)));
}

$ff = rtrim((string) getenv('FIREFLY_III_URL'), '/');
$ffHeaders = ['Authorization: Bearer ' . getenv('FIREFLY_III_ACCESS_TOKEN'), 'Accept: application/json'];
$existing = [];
foreach (['asset', 'liabilities'] as $type) {
    for ($page = 1;; $page++) {
        [$st, $body] = http('GET', "$ff/api/v1/accounts?type=$type&limit=100&page=$page", $ffHeaders);
        if (200 !== $st) {
            fail("Firefly /accounts returned HTTP $st");
        }
        $j = json_decode($body, true);
        foreach ($j['data'] ?? [] as $a) {
            $existing[strtolower($a['attributes']['name'])] = (int) $a['id'];
        }
        if ($page >= ($j['meta']['pagination']['total_pages'] ?? 1)) {
            break;
        }
    }
}

$window = new DateTimeImmutable('-' . WINDOW_DAYS . ' days');
$map = [];
$new = [];
foreach ($accounts as $a) {
    $org = $a['org']['name'] ?? $a['org']['domain'] ?? 'SimpleFIN';
    $label = trim("$org - " . $a['name']);
    $id = $existing[strtolower($label)] ?? 0;
    $map[$a['id']] = $id;
    if (0 === $id) {
        $new[$a['id']] = ['name' => $label, 'type' => 'asset', 'currency' => strlen($a['currency'] ?? '') === 3 ? $a['currency'] : 'USD', 'opening_balance' => '', 'balance' => (string) ($a['balance'] ?? '0')];
    }
}
if ([] !== $new) {
    // Opening balance such that Firefly's balance matches the bank's once the window is imported.
    $withTx = bridge($bridge, $basic, 'start-date=' . $window->getTimestamp());
    foreach ($withTx as $a) {
        if (!isset($new[$a['id']])) {
            continue;
        }
        $sum = '0';
        foreach ($a['transactions'] ?? [] as $t) {
            if (empty($t['pending'])) {
                $sum = bcadd($sum, (string) $t['amount'], 2);
            }
        }
        $new[$a['id']]['opening_balance'] = bcsub($new[$a['id']]['balance'], $sum, 2);
    }
    foreach ($new as &$n) {
        unset($n['balance']);
    }
    unset($n);
}

$dir = '/tmp/simplefin';
@mkdir($dir, 0700, true);
file_put_contents("$dir/simplefin.json", json_encode([
    'version' => 3, 'flow' => 'simplefin', 'access_token' => $access,
    'accounts' => $map, 'new_accounts' => $new,
    'date_range' => 'partial', 'date_range_number' => WINDOW_DAYS, 'date_range_unit' => 'd',
    'date_not_before' => $window->format('Y-m-d'), 'pending_transactions' => false,
    'default_account' => 0, 'delimiter' => 'comma', 'headers' => false, 'rules' => true, 'skip_form' => false,
    'add_import_tag' => true, 'roles' => [], 'do_mapping' => [], 'mapping' => [],
    'duplicate_detection_method' => 'cell', 'ignore_duplicate_lines' => false, 'ignore_duplicate_transactions' => true,
    'unique_column_index' => 0, 'unique_column_type' => 'external-id', 'conversion' => false,
], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES));
chmod("$dir/simplefin.json", 0600);
out(sprintf('config: %d accounts (%d to create)', count($map), count($new)));

// --- 3. import ---
chdir('/var/www/html');
passthru('php artisan importer:auto-import ' . escapeshellarg($dir), $code);
exit($code);
