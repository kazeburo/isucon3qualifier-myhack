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

my $tx = Text::Xslate->new(
    path => $root_dir . '/views_static',
    cache_dir => File::Temp::tempdir( CLEANUP => 1 ),
    cache => 2,
    module => ['Text::Xslate::Bridge::TT2Like','Number::Format' => [':subs']],
);

{
    my $html = $tx->render('signin.tx', {
    });
    my $filename = $root_dir . '/pages/signin';
    my $tmpfilename = $filename .'.'. int(rand(100));
    mkdir "$root_dir/pages";
    open my $fh , '>', $tmpfilename;
    print $fh $html;
    close $fh;
    move($tmpfilename, $filename);
}
my @memos_cache;
while(1){
    my $start_time = Time::HiRes::time();
    eval{
        $cache->get('stop_worker') and next;
        my $max_id = $cache->get('max_id') || 0;
        @memos_cache = () if $max_id == 0;

        my $new_memos = $dbh->select_all(<<EOF, $max_id);
            SELECT memos.id AS id,user, title, is_private, created_at, updated_at, username AS username
            FROM memos FORCE INDEX (PRIMARY)
            INNER JOIN users ON memos.user = users.id
            WHERE is_private=0 AND memos.id > ?
            ORDER BY id DESC
EOF

        @memos_cache =  (@$new_memos, @memos_cache);
        my @memos_all = @memos_cache; #copy
warn sprintf 'max_id:%s new_max_id:%stotal:%s', $max_id, $memos_all[0]->{id}, scalar @memos_all;

        $cache->set('max_id', $memos_all[0]->{id}) if @$new_memos;
        
        my $total = scalar @memos_all;
        my $page=0;
        while ( my @memos = splice(@memos_all,0,100) ) {
            my $html = $tx->render('index.tx', {
                memos => \@memos,
                page  => $page,
                total => $total,
            });
            my $filename = $root_dir . '/pages/recent/'.$page;
            my $tmpfilename = $filename .'.'. int(rand(100));
            mkdir "$root_dir/pages";
            mkdir "$root_dir/pages/recent";
            open my $fh , '>', $tmpfilename;
            print $fh $html;
            close $fh;
            move($tmpfilename, $filename);
            if ( $page == 0 ) {
                copy($filename,"$root_dir/pages/index.html.b");
                move("$root_dir/pages/index.html.b","$root_dir/pages/index.html");
            }
            $page++;
        }
    };
    warn $@ if $@;
    my $end_time = Time::HiRes::time();
    my $ela = $end_time - $start_time;
    warn sprintf('elaplsed %s, [%s]', $ela, scalar localtime()) if $ela > 0.6;

    select undef,undef,undef,0.3;
}


