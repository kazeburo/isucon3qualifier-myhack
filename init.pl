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
    servers => [ { address => "localhost:12345",noreply=>0} ],
    serialize_methods => [ sub { Data::MessagePack->pack(+shift)}, sub {Data::MessagePack->unpack(+shift)} ],
});

my $memos = $dbh->select_all(<<EOF);
    SELECT memos.id AS id,user, title, content, is_private, created_at, updated_at, username AS username
        FROM memos FORCE INDEX (PRIMARY)
    INNER JOIN users ON memos.user = users.id
    ORDER BY id DESC
EOF

my %users_all;
my %users_public;
for my $memo (@$memos) {
    push @{$users_all{$memo->{user}}}, $memo->{id};
    push @{$users_public{$memo->{user}}}, $memo->{id} unless $memo->{is_private};
    $memo->{content_html} = markdown($memo->{content});
    $cache->set('memo:' . $memo->{id},$memo );
}

my $users = $dbh->select_all('SELECT id FROM users ORDER BY id ASC');
for my $user (@$users) {
    my $memos = $dbh->select_all('SELECT id, is_private FROM memos WHERE user = ? ORDER BY id', $user->{id});
    $cache->set('user_memos_all:' . $user->{id},
                [map { $_->{id} + 0 } @$memos]);
    $cache->set('user_memos_public:' . $user->{id},
                [map { $_->{id} + 0 } grep { !$_->{is_private} } @$memos]);
}

$cache->set('max_id', 0);

