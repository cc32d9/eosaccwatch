
$Conf::rpcurl = 'https://eu1.eosdac.io';
$Conf::workdir = '/home/eosaccwatch/var';
$Conf::smtp_from = 'eosaccwatch@domain.com';

@Conf::watchlist =
    (
     {
         'account_name' => 'ge4nwerufsdcec',
         'notify_email' => 'alice@example.com',
     },
     {
         'account_name' => 'd34rffewvw4456',
         'notify_email' => 'bob@example.com',
     },
     {
         'account_name' => 'watchdoggiee',
         'watch_contract' => 1,
         'notify_email' => 'bob@example.com',
     },
    );

1;
