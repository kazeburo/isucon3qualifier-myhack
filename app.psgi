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
   $app;
};
