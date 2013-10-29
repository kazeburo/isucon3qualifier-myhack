use FindBin;
use lib "$FindBin::Bin/extlib/lib/perl5";
use lib "$FindBin::Bin/lib";
use File::Basename;
use Plack::Builder;
use Isucon3::Web;
use Plack::Session::Store::Cache;
use Plack::Session::State::Cookie;
use Cache::Memcached::Fast;

my $root_dir = File::Basename::dirname(__FILE__);

my $app = Isucon3::Web->psgi($root_dir);
builder {
    enable 'ReverseProxy';
    enable 'Static::OpenFileCache',
        path => qr!^/(?:(?:css|js|img)/|favicon\.ico$)!,
        root => $root_dir . '/public';
    enable 'Session::Simple',
        store => Cache::Memcached::Fast->new({
            servers => [ "localhost:12345" ],
        }),
        httponly => 1,
        cookie_name => "isucon_session",
        keep_empty => 0;
   $app;
};
