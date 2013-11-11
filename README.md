# HOT TO RUN

## nginx 

    cd /tmp
    wget ftp://ftp.csx.cam.ac.uk/pub/software/programming/pcre/pcre-8.33.tar.gz
    tar zxf pcre-8.33.tar.gz
    wget http://openresty.org/download/ngx_openresty-1.4.3.3.tar.gz
    tar zxf ngx_openresty-1.4.3.3.tar.gz
    cd ngx_openresty-1.4.3.3
    export PATH=/sbin:$PATH
    ./configure --with-luajit --prefix=/usr/local/openresty --with-http_gzip_static_module --with-pcre=/tmp/pcre-8.33 --with-pcre-jit
    make
    sudo make install
    sudo mkdir -p /var/log/nginx
    sudo chmod 755 /var/log/nginx
    sudo /etc/init.d/httpd stop
    sudo /sbin/chkconfig httpd off

## memcached

    cd /tmp
    wget http://memcached.googlecode.com/files/memcached-1.4.14.tar.gz
    tar zxf memcached-1.4.14.tar.gz
    cd memcached-1.4.14
    ./configure --prefix=/usr/local/memcached
    make
    sudo make install

## carton setup

    cd /home/isucon/webapp/perl/conf
    carton install

## luajit

    cd /home/isucon/webapp/perl/conf
    /usr/local/openresty/luajit/bin/luajit -b memo.lua memo.luac

## supervisord.conf

    cd /home/isucon/webapp/perl/conf
    sudo cp conf/supervisord.conf /etc/supervisord.conf
    sudo /usr/bin/supervisorctl reload

# RESULT

    $ sudo isucon3 benchmark --init /home/isucon/webapp/perl/conf/init.sh --workload 2
    2013/11/11 14:49:42 <<<DEBUG build>>>
    2013/11/11 14:49:42 benchmark mode
    2013/11/11 14:49:42 initialize data...
    2013/11/11 14:49:57 run /home/isucon/webapp/perl/conf/init.sh timeout 60 sec...
    2013/11/11 14:50:32 done
    2013/11/11 14:50:32 sleeping 5 sec...
    2013/11/11 14:50:37 run benchmark workload: 2
    2013/11/11 14:51:38 done benchmark
    Result:   SUCCESS 
    RawScore: 65508.9
    Fails:    0
    Score:    65508.9



