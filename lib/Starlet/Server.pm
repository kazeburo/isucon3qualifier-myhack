package Starlet::Server;
use strict;
use warnings;

use Carp ();
use Plack;
use Plack::HTTPParser qw( parse_http_request );
use IO::Socket::INET;
use HTTP::Date;
use HTTP::Status;
use List::Util qw(max sum);
use Plack::Util;
use Plack::TempBuffer;
use POSIX qw(EINTR EAGAIN EWOULDBLOCK);
use Socket qw(IPPROTO_TCP TCP_NODELAY);
use Sys::Sendfile;
use AnyEvent::Util qw/fh_nonblocking/;

use Try::Tiny;
use Time::HiRes qw(time);

use constant MAX_REQUEST_SIZE => 131072;
use constant CHUNKSIZE        => 64 * 1024;
use constant MSWin32          => $^O eq 'MSWin32';

my $null_io = do { open my $io, "<", \""; $io };

my $have_accept4 = eval {
    require Linux::Socket::Accept4;
    Linux::Socket::Accept4::SOCK_CLOEXEC()|Linux::Socket::Accept4::SOCK_NONBLOCK();
};

sub new {
    my($class, %args) = @_;

    my $self = bless {
        host                 => $args{host} || 0,
        port                 => $args{port} || 8080,
        socket_path          => (defined $args{socket_path}) ? $args{socket_path} : undef,
        timeout              => $args{timeout} || 300,
        keepalive_timeout    => $args{keepalive_timeout} || 2,
        max_keepalive_reqs   => $args{max_keepalive_reqs} || 1,
        server_software      => $args{server_software} || $class,
        server_ready         => $args{server_ready} || sub {},
        min_reqs_per_child   => (
            defined $args{min_reqs_per_child}
                ? $args{min_reqs_per_child} : undef,
        ),
        max_reqs_per_child   => (
            $args{max_reqs_per_child} || $args{max_requests} || 1000,
        ),
        spawn_interval       => $args{spawn_interval} || 0,
        err_respawn_interval => (
            defined $args{err_respawn_interval}
                ? $args{err_respawn_interval} : undef,
        ),
        is_multiprocess      => Plack::Util::FALSE,
        _using_defer_accept  => undef,
    }, $class;

    if ($args{max_workers} && $args{max_workers} > 1) {
        Carp::carp(
            "Preforking in $class is deprecated. Falling back to the non-forking mode. ",
            "If you need preforking, use Starman or Starlet instead and run like `plackup -s Starlet`",
        );
    }

    $self;
}

sub run {
    my($self, $app) = @_;
    $self->setup_listener();
    $self->accept_loop($app);
}

sub setup_listener {
    my $self = shift;
    if ( my $path = $self->{socket_path} ) {
        if (-S $path) {
            warn "removing existing socket file:$path";
            unlink $path
                or die "failed to remove existing socket file:$path:$!";
        }
        unlink $path;
        my $saved_umask = umask(0);
        $self->{listen_sock} = IO::Socket::UNIX->new(
            Listen => Socket::SOMAXCONN(),
            Local  => $path,
        ) or die "failed to listen to socket $path:$!";
        umask($saved_umask);
        $self->{use_unix_domain} = 1;
        $self->{_using_defer_accept} = 1;
    }
    else {
        $self->{listen_sock} ||= IO::Socket::INET->new(
            Listen    => SOMAXCONN,
            LocalPort => $self->{port},
            LocalAddr => $self->{host},
            Proto     => 'tcp',
            ReuseAddr => 1,
        ) or die "failed to listen to port $self->{port}:$!";

        # set defer accept
        if ($^O eq 'linux') {
            setsockopt($self->{listen_sock}, IPPROTO_TCP, 9, 1)
                and $self->{_using_defer_accept} = 1;
        }

    }


    $self->{server_ready}->($self);
}

sub accept_loop {
    # TODO handle $max_reqs_per_child
    my($self, $app, $max_reqs_per_child) = @_;
    my $proc_req_count = 0;

    $self->{can_exit} = 1;
    my $is_keepalive = 0;
    local $SIG{TERM} = sub {
        exit 0 if $self->{can_exit};
        $self->{term_received}++;
        exit 0
            if ($is_keepalive && $self->{can_exit}) || $self->{term_received} > 1;
        # warn "server termination delayed while handling current HTTP request";
    };

    local $SIG{PIPE} = 'IGNORE';
    sub do_accept {
        my $listen = shift;
        my ($conn,$peer);
        use open 'IO' => ':unix';
        if ( $have_accept4 ) {
            $peer = Linux::Socket::Accept4::accept4($conn,$listen, $have_accept4);
        }
        else {
            $peer = accept($conn,$listen);
            fh_nonblocking($conn,1) if $peer;
        }
        return ($conn, $peer);
    }
    while (! defined $max_reqs_per_child || $proc_req_count < $max_reqs_per_child) {
        if ( my ($conn, $peer) = do_accept($self->{listen_sock}) ) {
            $self->{_is_deferred_accept} = $self->{_using_defer_accept};
            my ($peerport,$peerhost, $peeraddr) = (0, undef, undef);
            if ( !$self->{use_unix_domain} ) {
                setsockopt($conn, IPPROTO_TCP, TCP_NODELAY, 1)
                    or die "setsockopt(TCP_NODELAY) failed:$!";
                ($peerport,$peerhost) = unpack_sockaddr_in $peer;
                $peeraddr = inet_ntoa($peerhost);
            }
            my $req_count = 0;
            my $pipelined_buf = '';

            while (1) {
                ++$req_count;
                ++$proc_req_count;
                my $env = {
                    SERVER_PORT => $self->{port} || 0,
                    SERVER_NAME => $self->{host} || 0,
                    SCRIPT_NAME => '',
                    REMOTE_ADDR => $peeraddr,
                    REMOTE_PORT => $peerport,
                    'psgi.version' => [ 1, 1 ],
                    'psgi.errors'  => *STDERR,
                    'psgi.url_scheme' => 'http',
                    'psgi.run_once'     => Plack::Util::FALSE,
                    'psgi.multithread'  => Plack::Util::FALSE,
                    'psgi.multiprocess' => $self->{is_multiprocess},
                    'psgi.streaming'    => Plack::Util::TRUE,
                    'psgi.nonblocking'  => Plack::Util::FALSE,
                    'psgix.input.buffered' => Plack::Util::TRUE,
                    'psgix.io'          => $conn,
                    'psgix.harakiri'    => 1,
                };

                my $may_keepalive = $req_count < $self->{max_keepalive_reqs};
                if ($may_keepalive && $max_reqs_per_child && $proc_req_count >= $max_reqs_per_child) {
                    $may_keepalive = undef;
                }
                $may_keepalive = 1 if length $pipelined_buf;
                my $keepalive;
                ($keepalive, $pipelined_buf) = $self->handle_connection($env, $conn, $app, 
                                                                        $may_keepalive, $req_count != 1, $pipelined_buf);

                if ($env->{'psgix.harakiri.commit'}) {
                    $conn->close;
                    return;
                }
                last unless $keepalive;
                # TODO add special cases for clients with broken keep-alive support, as well as disabling keep-alive for HTTP/1.0 proxies
            }
            $conn->close;
        }
    }
}

my $bad_response = [ 400, [ 'Content-Type' => 'text/plain', 'Connection' => 'close' ], [ 'Bad Request' ] ];
sub handle_connection {
    my($self, $env, $conn, $app, $use_keepalive, $is_keepalive, $prebuf) = @_;
    
    my $buf = '';
    my $pipelined_buf='';
    my $res = $bad_response;
    
    local $self->{can_exit} = (defined $prebuf) ? 0 : 1;
    while (1) {
        my $rlen;
        if ( $rlen = length $prebuf ) {
            $buf = $prebuf;
            undef $prebuf;
        }
        else {
            $rlen = $self->read_timeout(
                $conn, \$buf, MAX_REQUEST_SIZE - length($buf), length($buf),
                $is_keepalive ? $self->{keepalive_timeout} : $self->{timeout},
            ) or return;
        }
        $self->{can_exit} = 0;
        my $reqlen = parse_http_request($buf, $env);
        if ($reqlen >= 0) {
            # handle request
            my $protocol = $env->{SERVER_PROTOCOL};
            if ($use_keepalive) {
                if ( $protocol eq 'HTTP/1.1' ) {
                    if (my $c = $env->{HTTP_CONNECTION}) {
                        $use_keepalive = undef 
                            if $c =~ /^\s*close\s*/i;
                    }
                }
                else {
                    if (my $c = $env->{HTTP_CONNECTION}) {
                        $use_keepalive = undef
                            unless $c =~ /^\s*keep-alive\s*/i;
                    } else {
                        $use_keepalive = undef;
                    }
                }
            }
            $buf = substr $buf, $reqlen;
            my $chunked = do { no warnings; lc delete $env->{HTTP_TRANSFER_ENCODING} eq 'chunked' };
            if (my $cl = $env->{CONTENT_LENGTH}) {
                my $buffer = Plack::TempBuffer->new($cl);
                while ($cl > 0) {
                    my $chunk;
                    if (length $buf) {
                        $chunk = $buf;
                        $buf = '';
                    } else {
                        $self->read_timeout(
                            $conn, \$chunk, $cl, 0, $self->{timeout})
                            or return;
                    }
                    $buffer->print($chunk);
                    $cl -= length $chunk;
                }
                $env->{'psgi.input'} = $buffer->rewind;
            }
            elsif ($chunked) {
                my $buffer = Plack::TempBuffer->new;
                my $chunk_buffer = '';
                my $length;
                DECHUNK: while(1) {
                    my $chunk;
                    if ( length $buf ) {
                        $chunk = $buf;
                        $buf = '';
                    }
                    else {
                        $self->read_timeout($conn, \$chunk, CHUNKSIZE, 0, $self->{timeout})
                            or return;
                    }

                    $chunk_buffer .= $chunk;
                    while ( $chunk_buffer =~ s/^(([0-9a-fA-F]+).*\015\012)// ) {
                        my $trailer   = $1;
                        my $chunk_len = hex $2;
                        if ($chunk_len == 0) {
                            last DECHUNK;
                        } elsif (length $chunk_buffer < $chunk_len + 2) {
                            $chunk_buffer = $trailer . $chunk_buffer;
                            last;
                        }
                        $buffer->print(substr $chunk_buffer, 0, $chunk_len, '');
                        $chunk_buffer =~ s/^\015\012//;
                        $length += $chunk_len;                        
                    }
                }
                $env->{CONTENT_LENGTH} = $length;
                $env->{'psgi.input'} = $buffer->rewind;
            } else {
                if ( $buf =~ m!^(?:GET|HEAD)! ) { #pipeline
                    $pipelined_buf = $buf;
                    $use_keepalive = 1; #force keepalive
                } # else clear buffer
                $env->{'psgi.input'} = $null_io;
            }

            if ( $env->{HTTP_EXPECT} ) {
                if ( $env->{HTTP_EXPECT} eq '100-continue' ) {
                    $self->write_all($conn, "HTTP/1.1 100 Continue\015\012\015\012")
                        or return;
                } else {
                    $res = [417,[ 'Content-Type' => 'text/plain', 'Connection' => 'close' ], [ 'Expectation Failed' ] ];
                    last;
                }
            }

            $res = Plack::Util::run_app $app, $env;
            last;
        }
        if ($reqlen == -2) {
            # request is incomplete, do nothing
        } elsif ($reqlen == -1) {
            # error, close conn
            last;
        }
    }

    if (ref $res eq 'ARRAY') {
        $self->_handle_response($env->{SERVER_PROTOCOL}, $res, $conn, \$use_keepalive);
    } elsif (ref $res eq 'CODE') {
        $res->(sub {
            $self->_handle_response($env->{SERVER_PROTOCOL}, $_[0], $conn, \$use_keepalive);
        });
    } else {
        die "Bad response $res";
    }
    if ($self->{term_received}) {
        exit 0;
    }
    
    return ($use_keepalive, $pipelined_buf);
}

sub _handle_response {
    my($self, $protocol, $res, $conn, $use_keepalive_r) = @_;
    my $status_code = $res->[0];
    my $headers = $res->[1];
    my $body = $res->[2];
    
    my @lines;
    my %send_headers;
    for (my $i = 0; $i < @$headers; $i += 2) {
        my $k = $headers->[$i];
        my $v = $headers->[$i + 1];
        my $lck = lc $k;
        if ($lck eq 'connection') {
            $$use_keepalive_r = undef
                if $$use_keepalive_r && lc $v ne 'keep-alive';
        } else {
            push @lines, "$k: $v\015\012";
            $send_headers{$lck} = $v;
        }
    }
    if ( ! exists $send_headers{server} ) {
        unshift @lines, "Server: $self->{server_software}\015\012";
    }
    if ( ! exists $send_headers{date} ) {
        unshift @lines, "Date: @{[HTTP::Date::time2str()]}\015\012";
    }

    # try to set content-length when keepalive can be used, or disable it
    my $use_chunked;
    if ( $protocol eq 'HTTP/1.0' ) {
        if ($$use_keepalive_r) {
            if (defined $send_headers{'content-length'}
                || defined $send_headers{'transfer-encoding'}) {
                # ok
            }
            elsif ( ! Plack::Util::status_with_no_entity_body($status_code)
                    && defined(my $cl = Plack::Util::content_length($body))) {
                push @lines, "Content-Length: $cl\015\012";
            }
            else {
                $$use_keepalive_r = undef
            }            
        }
        push @lines, "Connection: keep-alive\015\012" if $$use_keepalive_r;
        push @lines, "Connection: close\015\012" if !$$use_keepalive_r; #fmm..
    }
    elsif ( $protocol eq 'HTTP/1.1' ) {
        if (defined $send_headers{'content-length'}
                || defined $send_headers{'transfer-encoding'}) {
            # ok
        } elsif ( !Plack::Util::status_with_no_entity_body($status_code) ) {
            push @lines, "Transfer-Encoding: chunked\015\012";
            $use_chunked = 1;
        }
        push @lines, "Connection: close\015\012" unless $$use_keepalive_r;

    }

    unshift @lines, "HTTP/1.1 $status_code @{[ HTTP::Status::status_message($status_code) ]}\015\012";
    push @lines, "\015\012";
    
    if (defined $body && ref $body eq 'ARRAY' && @$body == 1
            && length $body->[0] < 16384) {
        # combine response header and small request body
        my $buf = $body->[0];
        if ($use_chunked ) {
            my $len = length $buf;
            $buf = sprintf("%x",$len) . "\015\012" . $buf . "\015\012" . '0' . "\015\012\015\012";
        }
        $self->write_all(
            $conn, join('', @lines, $buf), $self->{timeout},
        );
        return;
    }

    if ( !$use_chunked
      && defined $body && ref $body ne 'ARRAY'
      && fileno($body) ) {
        my $cl = $send_headers{'content-length'} || -s $body;
        # sendfile
        my $use_cork = 0;
        if ( $^O eq 'linux' && !$self->{use_unix_domain} ) {
            setsockopt($conn, IPPROTO_TCP, 3, 1)
                and $use_cork = 1;
        }
        $self->write_all($conn, join('', @lines), $self->{timeout})
            or return;
        my $len = $self->sendfile_all($conn, $body, $cl, $self->{timeout});
        if ( $use_cork && $$use_keepalive_r && !$self->{use_unix_domain} ) {
            setsockopt($conn, IPPROTO_TCP, 3, 0);
        }
        return;
    }

    $self->write_all($conn, join('', @lines), $self->{timeout})
        or return;

    if (defined $body) {
        my $failed;
        my $completed;
        my $body_count = (ref $body eq 'ARRAY') ? $#{$body} + 1 : -1;
        Plack::Util::foreach(
            $body,
            sub {
                unless ($failed) {
                    my $buf = $_[0];
                    --$body_count;
                    if ( $use_chunked ) {
                        my $len = length $buf;
                        return unless $len;
                        $buf = sprintf("%x",$len) . "\015\012" . $buf . "\015\012";
                        if ( $body_count == 0 ) {
                            $buf .= '0' . "\015\012\015\012";
                            $completed = 1;
                        }
                    }
                    $self->write_all($conn, $buf, $self->{timeout})
                        or $failed = 1;
                }
            },
        );
        $self->write_all($conn, '0' . "\015\012\015\012", $self->{timeout}) if $use_chunked && !$completed;
    } else {
        return Plack::Util::inline_object
            write => sub {
                my $buf = $_[0];
                if ( $use_chunked ) {
                    my $len = length $buf;
                    return unless $len;
                    $buf = sprintf("%x",$len) . "\015\012" . $buf . "\015\012"
                }
                $self->write_all($conn, $buf, $self->{timeout})
            },
            close => sub {
                $self->write_all($conn, '0' . "\015\012\015\012", $self->{timeout}) if $use_chunked;
            };
    }
}

# returns value returned by $cb, or undef on timeout or network error
sub do_io {
    my ($self, $is_write, $sock, $buf, $len, $off, $timeout) = @_;
    my $ret;
    unless ($is_write || delete $self->{_is_deferred_accept}) {
        goto DO_SELECT;
    }
 DO_READWRITE:
    # try to do the IO
    if ($is_write && $is_write == 1) {
        $ret = syswrite $sock, $buf, $len, $off
            and return $ret;
    } elsif ($is_write && $is_write == 2) {
        $ret = Sys::Sendfile::sendfile($sock, $buf, $len)
            and return $ret;
        $ret = undef if defined $ret && $ret == 0 && $! == EAGAIN; #hmm
    } else {
        $ret = sysread $sock, $$buf, $len, $off
            and return $ret;
    }
    unless ((! defined($ret)
                 && ($! == EINTR || $! == EAGAIN || $! == EWOULDBLOCK))) {
        return;
    }
    # wait for data
 DO_SELECT:
    while (1) {
        my ($rfd, $wfd);
        my $efd = '';
        vec($efd, fileno($sock), 1) = 1;
        if ($is_write) {
            ($rfd, $wfd) = ('', $efd);
        } else {
            ($rfd, $wfd) = ($efd, '');
        }
        my $start_at = time;
        my $nfound = select($rfd, $wfd, $efd, $timeout);
        $timeout -= (time - $start_at);
        last if $nfound;
        return if $timeout <= 0;
    }
    goto DO_READWRITE;
}

# returns (positive) number of bytes read, or undef if the socket is to be closed
sub read_timeout {
    my ($self, $sock, $buf, $len, $off, $timeout) = @_;
    $self->do_io(undef, $sock, $buf, $len, $off, $timeout);
}

# returns (positive) number of bytes written, or undef if the socket is to be closed
sub write_timeout {
    my ($self, $sock, $buf, $len, $off, $timeout) = @_;
    $self->do_io(1, $sock, $buf, $len, $off, $timeout);
}

# writes all data in buf and returns number of bytes written or undef if failed
sub write_all {
    my ($self, $sock, $buf, $timeout) = @_;
    my $off = 0;
    while (my $len = length($buf) - $off) {
        my $ret = $self->write_timeout($sock, $buf, $len, $off, $timeout)
            or return;
        $off += $ret;
    }
    return length $buf;
}

sub sendfile_timeout {
    my ($self, $sock, $fh, $len, $off, $timeout) = @_;
    $self->do_io(2, $sock, $fh, $len, $off, $timeout);
}

sub sendfile_all {
    my ($self, $sock, $fh, $cl, $timeout) = @_;
    my $off = 0;
    while (my $len = $cl - $off) {
        my $ret = $self->sendfile_timeout($sock, $fh, $len, $off, $timeout)
            or return;
        $off += $ret;
        seek($fh, $off, 0) if $cl != $off;
    }
    return $cl;
}


1;
