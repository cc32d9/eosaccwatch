## EOS account watch tool
#
# Copyright 2018 cc32d9@gmail.com
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


use strict;
use warnings;
use Getopt::Long;
use JSON;
use Redis;
use Digest::SHA ('sha256_hex');
use LWP::UserAgent;
use HTTP::Request;
use File::Copy;
use Email::Sender::Simple qw(sendmail);
use Email::Sender::Transport::SMTP qw();
use Email::MIME;

my $cfgfile;
my $verbose;

{
    my $ok = GetOptions
        ('cfg=s'      => \$cfgfile,
         'verbose'    => \$verbose);


    if( not $ok or not $cfgfile or scalar(@ARGV) > 0 )
    {
        error("Usage: $0 --cfg=CFGFILE",
              "Options:",
              "  --cfg=CFGFILE   config file in Perl format",
              "  --verbose       print verbose output");
        exit 1;
    }
}



$Conf::redis_server = '127.0.0.1:6379';
$Conf::redis_accounts_last_seq = 'eosaccwatch_last_seq';

$Conf::smtp_host = 'localhost';
$Conf::smtp_port = 25;
$Conf::smtp_from = 'eosaddrwatch@example.com';
$Conf::use_git = 0;

if( not -r $cfgfile )
{
    error("No such file or directory: $cfgfile");
    exit 1;
}

if( not do($cfgfile) )
{
    error("Cannot read $cfgfile: $@");
    exit 1;
}

if( not defined($Conf::rpcurl) )
{
    error("\$Conf::rpcurl is not defined in $cfgfile");
    exit 1;
}

if( not defined($Conf::workdir) )
{
    error("\$Conf::workdir is not defined in $cfgfile");
    exit 1;
}

if( not -d $Conf::workdir )
{
    error("No such directory: $Conf::workdir");
    exit 1;
}


if( scalar(@Conf::watchlist) == 0 )
{
    error("\@Conf::watchlist is not defined in $cfgfile");
    exit 1;
}


my $redis = Redis->new(server => $Conf::redis_server);
die("Cannot connect to Redis server") unless defined($redis);


my $ua = LWP::UserAgent->new(keep_alive => 1);
$ua->timeout(5);
$ua->env_proxy;

{
    my $url = $Conf::rpcurl . '/v1/chain/get_info';
    my $resp = $ua->get($Conf::rpcurl . '/v1/chain/get_info');
    if( not $resp->is_success )
    {
        error("Cannot access $url: " . $resp->status_line);
        exit 1;
    }

    my $content = $resp->decoded_content;
    my $data = eval { decode_json($content) };
    if( $@ )
    {
        error("Content at $url is not a valid JSON: $content");
        exit 1;
    }

    if( not defined($data->{'server_version'}) )
    {
        error("$url returned invalid data $content");
        exit 1;
    }

    verbose('Retrieved server info',
            'server_version=' . $data->{'server_version'});
}

sub get_actions
{
    my $account = shift;
    my $pos = shift;
    my $offset = shift;

    verbose("get_actions acc=$account pos=$pos offset=$offset");

    my $url = $Conf::rpcurl . '/v1/history/get_actions';

    my $req = HTTP::Request->new('POST', $url);
    $req->header('Content-Type' => 'application/json');

    $req->content(encode_json(
                      {
                          'account_name' => $account,
                          'pos' => $pos,
                          'offset' => $offset,
                      }));

    my $resp = $ua->request($req);
    if( not $resp->is_success )
    {
        die("Cannot retrieve transactions for account $account");
    }

    my $content = $resp->decoded_content;
    my $data = eval { decode_json($content) };
    if( $@ )
    {
        die("Content at $url is not a valid JSON: $content");
    }

    if( not defined($data->{'actions'}) )
    {
        die("RPC result does not contain a list of actions: $content");
    }

    if( scalar(@{$data->{'actions'}}) == 0 )
    {
        die("Empty list of actions for $account");
    }

    verbose('got ' . scalar(@{$data->{'actions'}}));
    return $data->{'actions'};
}


my $jswriter = JSON->new()->utf8(1)->canonical(1)->pretty(1);


my $n = 0;

foreach my $entry (@Conf::watchlist)
{
    $n++;

    my $ok = 1;
    foreach my $attr ('account_name')
    {
        if( not defined($entry->{$attr}) )
        {
            error("Attribute $attr is not defined in watchlist entry #" . $n);
            $ok = 0;
        }
    }

    next unless $ok;

    my $account = $entry->{'account_name'};
    verbose("Checking account: $account");

    my $last_known_seq =
        $redis->hget($Conf::redis_accounts_last_seq, $account);

    my @new_actions;

    my $last_action = eval { get_actions($account, -1, -1) };

    if( $@ )
    {
        error($@);
        next;
    }

    my $last_seq = $last_action->[0]->{'account_action_seq'};

    if( defined($last_known_seq) )
    {
        if( $last_seq == $last_known_seq )
        {
            verbose("Nothing changed for $account");
            next;
        }
    }
    else
    {
        verbose("Account $account is new for us. Saving the transaction count");
        $redis->hset($Conf::redis_accounts_last_seq, $account, $last_seq);
        next;
    }

    my $seq = $last_known_seq + 1;

    if( $seq == $last_seq )
    {
        push(@new_actions, $last_action->[0]);
    }
    else
    {
        while( $seq < $last_seq )
        {
            my $rcount = $last_seq - $seq;
            $rcount = 50 if $rcount > 50;

            my $acts = eval { get_actions($account, $seq, $rcount) };

            if( $@ )
            {
                error($@);
                next;
            }

            foreach my $action (@{$acts})
            {
                push(@new_actions, $action);
                if( $action->{'account_action_seq'} > $seq )
                {
                    $seq = $action->{'account_action_seq'};
                }
            }
        }
    }

    $redis->hset($Conf::redis_accounts_last_seq, $account, $seq);

    verbose('Found ' . scalar(@new_actions) .
            ' new transactions for ' . $account);
    send_notifications($entry, \@new_actions);
}


if( $Conf::use_git )
{
    my $ok = 1;
    chdir($Conf::workdir);
    if( not -d '.git' )
    {
        my $cmd = 'git init';
        verbose("Executing: $cmd");
        my $r = system($cmd);
        if( $r != 0 )
        {
            $ok = 0;
            error('Error executing $cmd: ' . $!);
        }
    }

    if( $ok )
    {
        my $cmd = 'git add --all';
        verbose("Executing: $cmd");
        my $r = system($cmd);
        if( $r != 0 )
        {
            $ok = 0;
            error('Error executing $cmd: ' . $!);
        }
    }

    if( $ok )
    {
        my $timestr = scalar(localtime(time()));
        my $cmd = sprintf('git commit -m "%s" --author "%s <%s>" 1>/dev/null',
                          $timestr, 'eosaccwatch', $Conf::smtp_from);
        verbose("Executing: $cmd");
        my $r = system($cmd);
    }

    exit(1) unless $ok;
}




sub send_notifications
{
    my $entry = shift;
    my $actions = shift;

    my $account = $entry->{'account_name'};

    my $watch_contract = $entry->{'watch_contract'};
    my @set_code_actions;

    if( $watch_contract ) # watch only contract uploads
    {
        foreach my $action (@{$actions})
        {
            my $at = $action->{'action_trace'};
            my $act = $at->{'act'};
            if( $act->{'account'} eq 'eosio' and $act->{'name'} eq 'setcode' )
            {
                push(@set_code_actions, $action);
            }
        }

        verbose('Found ' . scalar(@set_code_actions) .
                ' setcode transactions for ' . $account);
        
        if( scalar(@set_code_actions) == 0 )
        {
            verbose("$account is a contract account and we have not " .
                    "found any setcode transactions");
            return;
        }
    }

    if( defined($entry->{'notify_email'}) )
    {
        my @tos;
        if( ref($entry->{'notify_email'}) eq 'ARRAY' )
        {
            push(@tos, @{$entry->{'notify_email'}});
        }
        else
        {
            push(@tos, $entry->{'notify_email'});
        }

        my $body ='';
        my $subject;

        if( $watch_contract )
        {
            $subject = "Code changes detected in contract $account";
            $body .= join
            ("\n",
             'There are ' . scalar(@set_code_actions) .
             ' new setcode transactions for account ' . $account . ':',
             '', '');

            foreach my $action (@set_code_actions)
            {
                my $text = '';
                foreach my $attr ('account_action_seq', 'block_time')
                {
                    $text .= sprintf("%s: %s\n", $attr, $action->{$attr});
                }

                my $at = $action->{'action_trace'};
                my $act = $at->{'act'};

                $text .= sprintf("%s: %s\n", 'trx_id', $at->{'trx_id'});

                $text .= sprintf("%s::%s => %s\n", $act->{'account'},
                                 $act->{'name'},
                                 $at->{'receipt'}{'receiver'});

                my $code = pack('H*', $act->{'data'}{'code'});
                my $code_hash = sha256_hex($code);
                verbose('Code hash: ' . $code_hash);
                $text .= sprintf("code hash: %s\n", $code_hash);

                $body .= $text . "\n";
            }
        }
        else
        {
            $subject = 'New transactions for ' . $account;
            $body .= join
                ("\n",
                 'There are ' . scalar(@{$actions}) .
                 ' new transactions for account ' . $account . ':',
                 '', '');

            foreach my $action (@{$actions})
            {
                my $text = '';
                foreach my $attr ('account_action_seq', 'block_time')
                {
                    $text .= sprintf("%s: %s\n", $attr, $action->{$attr});
                }

                my $at = $action->{'action_trace'};
                my $act = $at->{'act'};

                $text .= sprintf("%s: %s\n", 'trx_id', $at->{'trx_id'});

                $text .= sprintf("%s::%s => %s\n", $act->{'account'},
                                 $act->{'name'},
                                 $at->{'receipt'}{'receiver'});

                $text .= $jswriter->encode($act->{'data'}) . "\n";

                $body .= $text . "\n";
            }
        }

        foreach my $mailto (@tos)
        {
            verbose("Sending a notification to $mailto");

            my $message = Email::MIME->create(
                header_str => [
                    From => $Conf::smtp_from,
                    To => $mailto,
                    Subject => $subject,
                ],
                parts => [ $body ],
                );

            my $outfile = $Conf::workdir . '/' . $account . '_' . $mailto .
                '_' . time();
            my $fh = IO::File->new($outfile, 'w') or
                die("Cannot write to $outfile: $!");
            $fh->print($message->as_string());
            $fh->close();
            verbose("Saved a copy to $outfile");

            sendmail(
                $message,
                {
                    from => $Conf::smtp_from,
                    to => $mailto,
                    transport => Email::Sender::Transport::SMTP->new
                        ({
                            host => $Conf::smtp_host,
                            port => $Conf::smtp_port,
                         }),
                });
        }
    }
}





sub error
{
    print STDERR (join("\n", @_), "\n");
}

sub verbose
{
    if($verbose)
    {
        print(join("\n", @_), "\n");
    }
}
