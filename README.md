# EOS Account Watch Tool

This tool is watching transactions for EOS accounts, and sends an email
alert whenever new transactions are seen in the network.

## Installing the software

Packages required for Ubuntu or Debian:

```
apt-get install -y libjson-xs-perl libredis-perl libjson-perl \
 libwww-perl liblwp-protocol-https-perl \
 libemail-sender-perl libemail-mime-perl \
 postfix redis-server

mkdir -p $HOME/tools $HOME/etc $HOME/var/eosaccwatch
cd $HOME/tools
git clone https://github.com/cc32d9/eosaccwatch.git
``` 

CentOS or RHEL can also be used, and you just need to install required
Perl modules.

## Configuration file

The configuration file is in Perl script syntax. There is am example
file in the tool distribution. A recommendded place for it is `etc`
folder in your home directory.

It should define the following elements:

* `$Conf::rpcurl`: the URL to one of working nodes in the network. Any
  of BP or BP Candidates should be fine. You can see this URL at the
  BP's home URL if you add `/bp.json` to it.

* `$Conf::workdir`: the working directory where the tool keeps its state
  information. `var/eosaccwatch` in your home directory is a good
  example for such a directory. It slowly grows in size, as the tool
  saves copies of every email it sends.

* `$Conf::smtp_from`: the sender email address that the tool will use
  for outgoing email. This should be a valid address with a valid
  domain, so that recipient mail servers don't treat the messages as
  spam.

* `@Conf::watchlist`: the list of EOS account names and correspondig
  email addresses for notifications. Each entry is a hash with keys
  `account_name` and `notify_email`.

* the file should end with `1;` to keep Perl happy.

## Running the tool

The tool understands two options: the mandatory `--cfg` option defines
the configuration file, and `--verbose` makes it print additional
diagnostics to standard output.

Whenever you run the tool from your shell command line, you typically
want the `--verbose` option, and the cron job command would run without
it.

```
# Command-line example
perl /home/bob/tools/eosaccwatch/eosaccwatch.pl --cfg /home/bob/etc/eosaccwatch_cfg.pl --verbose


# cron job example
*/5 * * * * /usr/bin/perl perl /home/bob/tools/eosaccwatch/eosaccwatch.pl --cfg /home/bob/etc/eosaccwatch_cfg.pl
```

## Setting up the mail server

This is the most tricky part: the script needs to be able to send email
that is not rreated as spam by recipients. The general recommendations
are as follows:

* The server's IPv4 and IPv6 addresses need reverse DNS records, and
  these records should not contain any keywords like ppp, adsl, docsis,
  dynamic.

* The sender's email address should have a valid domain name. The best
  is if the domain has SPF records explicitly alowing your server send
  email from it.

* If your ISP provides an SMTP server for outbound email, use it.


## Copyright and License

Copyright 2018 cc32d9@gmail.com

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.


## Donations and paid service

ETH address: `0x7137bfe007B15F05d3BF7819d28419EAFCD6501E`

EOS account: `cc32dninexxx`

You can send me equivalent of US$100 per account, and I will set up the
watching service for you for 10 years.