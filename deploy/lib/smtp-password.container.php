<?php
/**
 * Stores SMTP_PASSWORD as Magento's system/smtp/password: encrypted once, in the
 * database. setup server runs it when it installs a store (--import), inside the
 * active app container, with this file on stdin and the password in the environment:
 *
 *   SMTP_PASSWORD=… docker exec -i -u www-data -e SMTP_PASSWORD <app> php < smtp-password.container.php
 *
 * Why not env.php: the password is an Encrypted field, and every encryption takes a
 * random nonce. Written into env.php on every container start, it changed the system
 * section's hash each time, so Magento refused every uncached request until
 * app:config:import ran, and each container held its own ciphertext. In the database
 * it's encrypted once, by Magento, and the admin changes it from then on.
 *
 * It runs Magento's own config:set in-process, so the value never appears on a command
 * line (where ps and the shell history would show it), and gets config:set's lock check,
 * admin area emulation, Encrypted backend model and config hash update. config:set
 * refuses to run while the config hash is out of date, so setup runs this after
 * setup:upgrade. It prints only config:set's message, never the value.
 */
declare(strict_types=1);

use Magento\Framework\Console\Cli;
use Symfony\Component\Console\Input\ArrayInput;
use Symfony\Component\Console\Output\ConsoleOutput;

$password = getenv('SMTP_PASSWORD');
if ($password === false || $password === '') {
    fwrite(STDERR, "[smtp-password] SMTP_PASSWORD is empty: nothing stored\n");
    exit(0);
}

require '/app/app/bootstrap.php';

$cli = new Cli('Magento CLI');
$cli->setAutoExit(false);
exit($cli->run(
    new ArrayInput([
        'command' => 'config:set',
        'path' => 'system/smtp/password',
        'value' => $password,
    ]),
    new ConsoleOutput()
));
