package Isucon3::Web;

use strict;
use warnings;
use utf8;
use Kossy;
use DBIx::Sunny;
use JSON qw/ decode_json /;
use Digest::SHA qw/ sha256_hex /;
use DBIx::Sunny;
use File::Temp qw/ tempfile /;
use IO::Handle;
use Encode;
use Time::Piece;
use Cookie::Baker;
use Text::Markdown::Hoedown;

sub load_config {
    my $self = shift;
    $self->{_config} ||= do {
        my $env = $ENV{ISUCON_ENV} || 'local';
        open(my $fh, '<', $self->root_dir . "/../config/${env}.json") or die $!;
        my $json = do { local $/; <$fh> };
        close($fh);
        decode_json($json);
    };
}



sub dbh {
    my ($self) = @_;
    $self->{_dbh} ||= do {
        my $dbconf = $self->load_config->{database};
        DBIx::Sunny->connect(
            "dbi:mysql:database=${$dbconf}{dbname};host=${$dbconf}{host};port=${$dbconf}{port}", $dbconf->{username}, $dbconf->{password}, {
                RaiseError => 1,
                PrintError => 0,
                AutoInactiveDestroy => 1,
                mysql_enable_utf8   => 1,
                mysql_auto_reconnect => 1,
            },
        );
    };
}

filter 'session' => sub {
    my ($app) = @_;
    sub {
        my ($self, $c) = @_;
        my $cookie = crush_cookie($c->req->env->{'HTTP_COOKIE'})->{isucon_session} || '';
        my @cookie = split /,/, $cookie;
        $c->stash->{token} = $cookie[2] if $cookie;
        $c->stash->{user} = {
            id => $cookie[0],
            username => $cookie[1] 
        } if $cookie;
        $c->stash->{root_uri} = $c->req->uri_for('/');
        $app->($self, $c);
    };
};

filter 'get_user' => sub {
    my ($app) = @_;
    sub {
        my ($self, $c) = @_;
        $c->res->header('Cache-Control', 'private') if $c->stash->{user};
        $app->($self, $c);
    }
};

filter 'require_user' => sub {
    my ($app) = @_;
    sub {
        my ($self, $c) = @_;
        unless ( $c->stash->{user} ) {
            return $c->redirect('/');
        }
        $app->($self, $c);
    };
};

filter 'anti_csrf' => sub {
    my ($app) = @_;
    sub {
        my ($self, $c) = @_;
        my $sid   = $c->req->param('sid');
        my $token = $c->stash->{token};
        if ( $sid ne $token ) {
            return $c->halt(400);
        }
        $app->($self, $c);
    };
};

get '/' => [qw(session get_user)] => sub {
    my ($self, $c) = @_;
    my $total = $self->dbh->select_one(
        'SELECT count(*) FROM memos WHERE is_private=0'
    );
    my $memos = $self->dbh->select_all(
        'SELECT * FROM memos WHERE is_private=0 ORDER BY created_at DESC, id DESC LIMIT 100',
    );
    for my $memo (@$memos) {
        $memo->{username} = $self->dbh->select_one(
            'SELECT username FROM users WHERE id=?',
            $memo->{user},
        );
    }
    $c->render('index.tx', {
        memos => $memos,
        page  => 0,
        total => $total,
    });
};

get '/recent/:page' => [qw(session get_user)] => sub {
    my ($self, $c) = @_;
    my $page  = int $c->args->{page};
    my $total = $self->dbh->select_one(
        'SELECT count(*) FROM memos WHERE is_private=0'
    );
    my $memos = $self->dbh->select_all(
        sprintf("SELECT * FROM memos WHERE is_private=0 ORDER BY created_at DESC, id DESC LIMIT 100 OFFSET %d", $page * 100)
    );
    if ( @$memos == 0 ) {
        return $c->halt(404);
    }

    for my $memo (@$memos) {
        $memo->{username} = $self->dbh->select_one(
            'SELECT username FROM users WHERE id=?',
            $memo->{user},
        );
    }
    $c->render('index.tx', {
        memos => $memos,
        page  => $page,
        total => $total,
    });
};

get '/signin' => [qw(session get_user)] => sub {
    my ($self, $c) = @_;
    $c->render('signin.tx', {});
};

post '/signout' => [qw(session get_user require_user anti_csrf)] => sub {
    my ($self, $c) = @_;
    $c->res->header('Set-Cookie',bake_cookie("isucon_session",{value => "", expires => "now", path => "/", httponly => 1}));
    $c->redirect('/');
};

post '/signup' => [qw(session anti_csrf)] => sub {
    my ($self, $c) = @_;

    my $username = $c->req->param("username");
    my $password = $c->req->param("password");
    my $user = $self->dbh->select_row(
        'SELECT id, username, password, salt FROM users WHERE username=?',
        $username,
    );
    if ($user) {
        $c->halt(400);
    }
    else {
        my $salt = substr( sha256_hex( time() . $username ), 0, 8 );
        my $password_hash = sha256_hex( $salt, $password );
        $self->dbh->query(
            'INSERT INTO users (username, password, salt) VALUES (?, ?, ?)',
            $username, $password_hash, $salt,
        );
        my $user_id = $self->dbh->last_insert_id;
        $c->res->header('Set-Cookie',bake_cookie("isucon_session",{
            value => "$user_id,$username,".sha256_hex(rand()),
            httponly => 1,
            path => '/',
        }));
        $c->req->env->{"psgix.session"}->{user} = {
            username => $username,
            id => $user_id,
        };
        $c->req->env->{"psgix.session"}->{user_id} = $user_id;
        $c->redirect('/mypage');
    }
};

post '/signin' => [qw(session)] => sub {
    my ($self, $c) = @_;

    my $username = $c->req->param("username");
    my $password = $c->req->param("password");
    my $user = $self->dbh->select_row(
        'SELECT id, username, password, salt FROM users WHERE username=?',
        $username,
    );
    if ( $user && $user->{password} eq sha256_hex($user->{salt} . $password) ) {
        $c->res->header('Set-Cookie',bake_cookie("isucon_session",{
            value => "$user->{id},$user->{username},".sha256_hex(rand()),
            httponly => 1
        }));
        return $c->redirect('/mypage');
    }
    else {
        $c->render('signin.tx', {});
    }
};

get '/mypage' => [qw(session get_user require_user)] => sub {
    my ($self, $c) = @_;

    my $memos = $self->dbh->select_all(
        'SELECT id, title, is_private, created_at, updated_at FROM memos WHERE user=? ORDER BY id DESC',
        $c->stash->{user}->{id},
    );
    $c->render('mypage.tx', { memos => $memos });
};

post '/memo' => [qw(session get_user require_user anti_csrf)] => sub {
    my ($self, $c) = @_;

    $self->dbh->query(
        'INSERT INTO memos (user, title, content, is_private, created_at) VALUES (?, ?, ?, ?,  now())',
        $c->stash->{user}->{id},
        (split /\r?\n/, $c->req->param('content'))[0],
        scalar $c->req->param('content'),
        scalar($c->req->param('is_private')) ? 1 : 0,
    );
    my $memo_id = $self->dbh->last_insert_id;
    $c->redirect('/memo/' . $memo_id);
};

get '/memo/:id' => [qw(session get_user)] => sub {
    my ($self, $c) = @_;

    my $user = $c->stash->{user};
    my $memo = $self->dbh->select_row(
        'SELECT id, user, content, is_private, created_at, updated_at FROM memos WHERE id=?',
        $c->args->{id},
    );
    unless ($memo) {
        $c->halt(404);
    }
    if ($memo->{is_private}) {
        if ( !$user || $user->{id} != $memo->{user} ) {
            $c->halt(404);
        }
    }
    $memo->{content_html} = markdown($memo->{content});
    $memo->{username} = $self->dbh->select_one(
        'SELECT username FROM users WHERE id=?',
        $memo->{user},
    );

    my $cond;
    if ($user && $user->{id} == $memo->{user}) {
        $cond = "";
    }
    else {
        $cond = "AND is_private=0";
    }

    my $memos = $self->dbh->select_all(
        "SELECT id FROM memos WHERE user=? $cond ORDER BY id",
        $memo->{user},
    );
    my ($newer, $older);
    for my $i ( 0 .. scalar @$memos - 1 ) {
        if ( $memos->[$i]->{id} eq $memo->{id} ) {
            $older = $memos->[ $i - 1 ] if $i > 0;
            $newer = $memos->[ $i + 1 ] if $i < @$memos;
        }
    }

    $c->render('memo.tx', {
        memo  => $memo,
        older => $older,
        newer => $newer,
    });
};

1;
