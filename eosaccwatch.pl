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
use LWP::UserAgent;
use HTTP::Request;
use IO::File;
use Digest::SHA ('sha256_hex');
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


$Conf::n_receive_transactions = 20;
$Conf::smtp_host = 'localhost';
$Conf::smtp_port = 25;
$Conf::smtp_from = 'eosaddrwatch@example.com';


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


my $jswriter = JSON->new()->utf8(1)->canonical(1)->pretty(1);
    

my $url = $Conf::rpcurl . '/v1/history/get_actions';
my $offset = -1 * $Conf::n_receive_transactions;

my $n = 0;

foreach my $entry (@Conf::watchlist)
{
    $n++;

    my $ok = 1;
    foreach my $attr ('account_name', 'notify_email')
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

    my $req = HTTP::Request->new('POST', $url);
    $req->header('Content-Type' => 'application/json');
    
    $req->content(encode_json({'account_name' => $account,
                               'offset' => $offset}));
    
    my $resp = $ua->request($req);
    if( not $resp->is_success )
    {
        error("Cannot retrieve transactions for account $account");
        next;
    }

    my $content = $resp->decoded_content;
    my $data = eval { decode_json($content) };
    if( $@ )
    {
        error("Content at $url is not a valid JSON: $content");
        next;
    }

    if( not defined($data->{'actions'}) )
    {
        error("RPC result does not contain a list of actions: $content");
        next;
    }
    
    if( scalar(@{$data->{'actions'}}) == 0 )
    {
        error("Empty list of actions for $account");
        next;
    }

    my $jscontent = $jswriter->encode($data->{'actions'});
    my $jscontent_sha = sha256_hex($jscontent);
    
    my $outfile = $Conf::workdir . '/' . $account;

    if( -e $outfile )
    {
        my $sha = Digest::SHA->new(256);
        $sha->addfile($outfile);
        my $old_sha = $sha->hexdigest();

        if( $old_sha eq $jscontent_sha )
        {
            verbose("Nothing changed for $account");
            next;
        }
        else
        {
            verbose("Found new transactions for $account");
            notify_owner($entry, $data->{'actions'});
        }
    }
    else
    {
        verbose("Account $account is new for us. Saving the transactions");
    }

    my $fh = IO::File->new($outfile, 'w') or
        die("Cannot write to $outfile: $!");
    $fh->print($jscontent);
    $fh->close();
}

    
sub notify_owner
{
    my $entry = shift;
    my $actions = shift;

    my $account = $entry->{'account_name'};
    if( defined($entry->{'notify_email'}) )
    {
        my $mailto = $entry->{'notify_email'};
        verbose("Sending a notification to $mailto");

        my $body = join
            ("\n",
             'There are new transactions for account ' . $account . '.',
             '',
             'Here is the list of last ' . $Conf::n_receive_transactions .
             ' transactions:',
             '', '');

        foreach my $action (reverse @{$actions})
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
             
        my $message = Email::MIME->create(
            header_str => [
                From => $Conf::smtp_from,
                To => $mailto,
                Subject => 'New transactions for ' . $account,
            ],
            parts => [ $body ],
            );

        my $outfile = $Conf::workdir . '/' . $account . '_email_' . time();
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
