#!/usr/bin/perl

use strict;
use warnings;
use utf8;
use DBIx::Sunny;
use JSON qw/ decode_json /;
use FindBin;
use File::Copy;
use File::Temp;
use Text::Xslate;
use Time::HiRes;
use Text::Markdown::Hoedown;
use Cache::Memcached::Fast;

my $root_dir = $FindBin::Bin;
my $env = $ENV{ISUCON_ENV} || 'local';
open(my $fh, '<', $root_dir . "/../config/${env}.json") or die $!;
my $json = do { local $/; <$fh> };
close($fh);
my $config = decode_json($json);

my $dbconf = $config->{database};
my $dbh = DBIx::Sunny->connect(
    "dbi:mysql:database=${$dbconf}{dbname};host=${$dbconf}{host};port=${$dbconf}{port}", $dbconf->{username}, $dbconf->{password}, {
        RaiseError => 1,
        PrintError => 0,
        AutoInactiveDestroy => 1,
        mysql_enable_utf8   => 1,
        mysql_auto_reconnect => 1,
    },
);

my $cache = Cache::Memcached::Fast->new({
    servers => [ { address => "localhost:12345",noreply=>1} ],
    serialize_methods => [ sub { Data::MessagePack->pack(+shift)}, sub {Data::MessagePack->unpack(+shift)} ],
});

my $memos = $dbh->select_all(<<EOF);
    SELECT memos.id AS id,user, title, content, is_private, created_at, updated_at, username AS username
        FROM memos FORCE INDEX (PRIMARY)
    INNER JOIN users ON memos.user = users.id
    ORDER BY id DESC
EOF

my %users;
for my $memo (@$memos) {
    push @{$users{$memo->{user}}}, $memo->{id};
    $memo->{content_html} = markdown($memo->{content});
    $cache->set('memo:' . $memo->{id},$memo );
}

for my $user_id ( keys %users ) {
    $cache->set('user_memos:'.$user_id, $users{$user_id});
}


