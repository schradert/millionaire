<?php
// Baïkal first-run install, idempotent (initContainer, every start). Does what the
// 0.10.1 web installer does: config/baikal.yaml (SQLite, Digest auth), the database
// schema, Specific/INSTALL_DISABLED; then keeps the admin password in sync with
// $BAIKAL_ADMIN_PASSWORD and ensures the DAV user `admin` with the `org` calendar
// org-bridge writes to. Never prints the password.
require '/var/www/baikal/vendor/autoload.php';

use Symfony\Component\Yaml\Yaml;

const VERSION = '0.10.1';
const REALM = 'BaikalDAV';
const CONFIG = '/var/www/baikal/config/baikal.yaml';
const SPECIFIC = '/var/www/baikal/Specific';
const DB = SPECIFIC . '/db/db.sqlite';
const SCHEMA = '/var/www/baikal/Core/Resources/Db/SQLite/db.sql';

$password = getenv('BAIKAL_ADMIN_PASSWORD');
if ($password === false || $password === '') {
    fwrite(STDERR, "BAIKAL_ADMIN_PASSWORD is not set\n");
    exit(1);
}
$adminHash = hash('sha256', 'admin:' . REALM . ':' . $password);
$digest = md5('admin:' . REALM . ':' . $password);

// 1. Config: written once; afterwards only the admin hash is kept in sync.
if (file_exists(CONFIG)) {
    $config = Yaml::parseFile(CONFIG);
    if (($config['system']['configured_version'] ?? null) !== VERSION) {
        fwrite(STDERR, "baikal.yaml has configured_version " . ($config['system']['configured_version'] ?? 'none') . ", expected " . VERSION . "; not touching it\n");
        exit(1);
    }
    if ($config['system']['admin_passwordhash'] !== $adminHash) {
        $config['system']['admin_passwordhash'] = $adminHash;
        file_put_contents(CONFIG, Yaml::dump($config));
        echo "admin password updated\n";
    }
} else {
    $config = [
        'system' => [
            'configured_version' => VERSION,
            'timezone' => getenv('TZ') ?: 'America/Los_Angeles',
            'card_enabled' => true,
            'cal_enabled' => true,
            'invite_from' => '',
            'dav_auth_type' => 'Digest',
            'admin_passwordhash' => $adminHash,
            'failed_access_message' => 'user %u authentication failure for Baikal',
            'auth_realm' => REALM,
            'base_uri' => '',
        ],
        'database' => [
            'sqlite_file' => DB,
            'backend' => 'sqlite',
            'mysql_host' => '',
            'mysql_dbname' => '',
            'mysql_username' => '',
            'mysql_password' => '',
            'encryption_key' => bin2hex(random_bytes(16)),
            'pgsql_host' => '',
            'pgsql_dbname' => '',
            'pgsql_username' => '',
            'pgsql_password' => '',
        ],
    ];
    @mkdir(dirname(CONFIG), 0755, true);
    file_put_contents(CONFIG, Yaml::dump($config));
    echo "wrote baikal.yaml\n";
}

// 2. Database schema.
@mkdir(dirname(DB), 0775, true);
$pdo = new PDO('sqlite:' . DB);
$pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
$hasUsers = $pdo->query("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='users'")->fetchColumn();
if (!$hasUsers) {
    $pdo->exec(file_get_contents(SCHEMA));
    echo "created database schema\n";
}

// 3. DAV user admin (Digest a1), its principal, and the org calendar.
$pdo->beginTransaction();
$cur = $pdo->prepare("SELECT digesta1 FROM users WHERE username = 'admin'");
$cur->execute();
$row = $cur->fetchColumn();
if ($row === false) {
    $pdo->prepare("INSERT INTO users (username, digesta1) VALUES ('admin', ?)")->execute([$digest]);
    echo "created DAV user admin\n";
} elseif ($row !== $digest) {
    $pdo->prepare("UPDATE users SET digesta1 = ? WHERE username = 'admin'")->execute([$digest]);
    echo "updated DAV user admin password\n";
}
$pdo->exec("INSERT OR IGNORE INTO principals (uri, email, displayname) VALUES ('principals/admin', '', 'admin')");
$exists = $pdo->query("SELECT count(*) FROM calendarinstances WHERE principaluri = 'principals/admin' AND uri = 'org'")->fetchColumn();
if (!$exists) {
    $pdo->exec("INSERT INTO calendars (synctoken, components) VALUES (1, 'VEVENT,VTODO')");
    $id = $pdo->lastInsertId();
    $pdo->prepare("INSERT INTO calendarinstances (calendarid, principaluri, access, displayname, uri, description, calendarorder, calendarcolor, timezone, transparent) VALUES (?, 'principals/admin', 1, 'org', 'org', '', 0, '', '', 0)")->execute([$id]);
    echo "created calendar admin/org\n";
}
$pdo->commit();

// 4. Skip the installer's database step.
if (!file_exists(SPECIFIC . '/INSTALL_DISABLED')) {
    touch(SPECIFIC . '/INSTALL_DISABLED');
}
echo "baikal install ok\n";
